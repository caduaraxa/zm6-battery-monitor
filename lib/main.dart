import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart' show AESEngine;
import 'package:shared_preferences/shared_preferences.dart';

const appName = 'ZM6 Battery Monitor';
const appVersion = '0.3.0'; // keep in sync with pubspec.yaml
const repoUrl = 'https://github.com/caduaraxa/zm6-battery-monitor';

/// Voltage ranges used by the gauge and the chart bands.
class VoltBand {
  final double from, to;
  final Color color, textColor;
  final String label;
  const VoltBand(this.from, this.to, this.color, this.textColor, this.label);
}

const voltBands = [
  VoltBand(0, 12.0, Color(0xFFE53935), Colors.white, 'Discharged / faulty'),
  VoltBand(12.0, 12.2, Color(0xFFFB8C00), Colors.black, 'Low charge'),
  VoltBand(12.2, 12.4, Color(0xFFFDD835), Colors.black, '~50%'),
  VoltBand(12.4, 12.6, Color(0xFF9CCC65), Colors.black, '~75%'),
  VoltBand(12.6, 100, Color(0xFF43A047), Colors.white, 'Full / healthy'),
];

VoltBand? bandFor(double? v) {
  if (v == null) return null;
  for (final b in voltBands) {
    if (v >= b.from && v < b.to) return b;
  }
  return voltBands.last;
}

/// SoC dial color: blue >= 70% (ok), orange 50-69% (medium), red < 50% (weak).
Color? socColor(int? soc) {
  if (soc == null) return null;
  if (soc >= 70) return const Color(0xFF1565C0);
  if (soc >= 50) return const Color(0xFFFB8C00);
  return const Color(0xFFE53935);
}

const chargeStatusLabels = {0: 'Normal', 1: 'Low voltage', 2: 'Charging'};

final darkMode = ValueNotifier<bool>(false);

void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(_app());
}

/// Foreground service task: does nothing, it only keeps the process (and the
/// BLE connection / reconnection loop) alive while the app is in background.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

Widget _app() => ValueListenableBuilder<bool>(
      valueListenable: darkMode,
      builder: (_, dark, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: appName,
        theme: ThemeData(colorSchemeSeed: Colors.blue),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.blue, brightness: Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: const HomePage(),
      ),
    );

class StartInfo {
  final double voltage;
  final DateTime? when;
  const StartInfo(this.voltage, this.when);
}

/// BLE connection and data singleton.
class Bm6 {
  static final Bm6 i = Bm6._();
  Bm6._();

  static final _key = Uint8List.fromList(
      [108, 101, 97, 103, 101, 110, 100, 255, 254, 48, 49, 48, 48, 48, 48, 57]);
  static Uint8List _cmd(int op) =>
      Uint8List.fromList([0xd1, 0x55, op, ...List.filled(13, 0)]);

  final voltage = ValueNotifier<double?>(null);
  final status = ValueNotifier<String>('Disconnected');
  final soc = ValueNotifier<int?>(null);
  final temp = ValueNotifier<int?>(null);
  final chargeStatus = ValueNotifier<int?>(null);
  final rapidAcc = ValueNotifier<int?>(null);
  final rapidDec = ValueNotifier<int?>(null);
  final lastStart = ValueNotifier<StartInfo?>(null);
  final deviceName = ValueNotifier<String?>(null);
  final mac = ValueNotifier<String?>(null);
  final customName = ValueNotifier<String?>(null);
  BluetoothDevice? get device => _dev;
  final points = ValueNotifier<List<FlSpot>>([]);
  final tempPoints = ValueNotifier<List<FlSpot>>([]);
  final log = ValueNotifier<List<String>>([]);

  BluetoothDevice? _dev;
  StreamSubscription? _scanSub, _notifySub, _connSub;
  BluetoothCharacteristic? _write;
  bool _running = false;
  Timer? _retryTimer;
  StreamSubscription? _adapterSub;
  static const retryInterval = Duration(seconds: 15);

  Uint8List _aes(Uint8List data, bool enc) {
    // single block, zero IV: CBC == ECB
    final c = AESEngine()..init(enc, KeyParameter(_key));
    return c.process(data);
  }

  void _log(String s) {
    final t = DateTime.now().toIso8601String().substring(11, 23);
    final l = [...log.value, '$t  $s'];
    if (l.length > 300) l.removeRange(0, l.length - 300);
    log.value = l;
  }

  String _hex(List<int> b) =>
      b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

  // --- history: every sample is appended to a CSV file per device ---
  IOSink? _sink;
  int _pending = 0;

  Future<File> _fileFor(String address) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/history_${address.replaceAll(':', '')}.csv');
  }

  /// Opens the device history, preloads the latest samples into the chart
  /// and starts appending new ones.
  Future<void> _openHistory(String address) async {
    try {
      await _closeHistory();
      final f = await _fileFor(address);
      if (await f.exists()) {
        final raf = await f.open();
        final len = await raf.length();
        final from = len > 16384 ? len - 16384 : 0;
        await raf.setPosition(from);
        final bytes = await raf.read(len - from);
        await raf.close();
        var lines = const LineSplitter()
            .convert(utf8.decode(bytes, allowMalformed: true));
        if (from > 0 && lines.isNotEmpty) lines = lines.sublist(1);
        final v = <FlSpot>[], t = <FlSpot>[];
        final nowS = DateTime.now().millisecondsSinceEpoch / 1000;
        for (final l in lines) {
          final p = l.split(',');
          if (p.length < 3) continue;
          final ms = int.tryParse(p[0]);
          final volt = double.tryParse(p[1]);
          final temp = int.tryParse(p[2]);
          if (ms == null || volt == null || temp == null) continue;
          final x = ms / 1000;
          v.add(FlSpot(x, volt));
          if (nowS - x <= 60) t.add(FlSpot(x, temp.toDouble()));
        }
        points.value = v.takeLast(120);
        tempPoints.value = t;
      }
      _sink = f.openWrite(mode: FileMode.append);
    } catch (e) {
      _log('history error: $e');
    }
  }

  Future<void> _closeHistory() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
  }

  /// Deletes the stored history of the current device and clears the charts.
  Future<void> clearHistory() async {
    final m = mac.value;
    await _closeHistory();
    try {
      if (m != null) {
        final f = await _fileFor(m);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
    points.value = [];
    tempPoints.value = [];
    _log('history cleared');
  }

  // --- custom device name (stored per MAC) ---
  Future<void> _loadName(String address) async {
    try {
      final p = await SharedPreferences.getInstance();
      customName.value = p.getString('name_$address');
    } catch (_) {}
  }

  Future<void> rename(String newName) async {
    final m = mac.value;
    if (m == null) return;
    final n = newName.trim();
    customName.value = n.isEmpty ? null : n;
    try {
      final p = await SharedPreferences.getInstance();
      if (n.isEmpty) {
        await p.remove('name_$m');
      } else {
        await p.setString('name_$m', n);
      }
    } catch (_) {}
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      await _startForegroundService();
      _watchAdapter();
      if (!await _bluetoothOn()) {
        status.value = 'Bluetooth is off';
        _notify('Bluetooth is off');
        _log('bluetooth is off, not scanning');
        _running = false;
        return;
      }
      status.value = 'Scanning for BM6...';
      _log('scan started');
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          if (r.advertisementData.advName == 'BM6' && _dev == null) {
            _dev = r.device;
            FlutterBluePlus.stopScan();
            _connect(r.device);
          }
        }
      });
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
      await Future.delayed(const Duration(seconds: 1));
      if (_dev == null) {
        status.value = 'BM6 not found, retrying in 15 s';
        _log('no BM6 found');
        _running = false;
        _scheduleRetry();
      }
    } catch (e) {
      status.value = 'Error: $e';
      _log('error: $e');
      _running = false;
      _scheduleRetry();
    }
  }

  Future<void> _connect(BluetoothDevice d) async {
    try {
      status.value = 'Connecting to ${d.remoteId}...';
      _log('connecting to ${d.remoteId}');
      mac.value = d.remoteId.str;
      _loadName(d.remoteId.str);
      await _openHistory(d.remoteId.str);
      await d.connect(
          license: License.free, timeout: const Duration(seconds: 30));
      _connSub = d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _log('disconnected');
          final btOn =
              FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
          status.value =
              btOn ? 'Disconnected, retrying in 15 s' : 'Bluetooth is off';
          _notify(btOn
              ? 'Disconnected, searching for the sensor...'
              : 'Bluetooth is off');
          _cleanup().then((_) => _scheduleRetry());
        }
      });
      final services = await d.discoverServices();
      BluetoothCharacteristic? notify;
      for (final s in services) {
        for (final c in s.characteristics) {
          final u = c.uuid.str.toLowerCase();
          if (u.contains('fff3')) _write = c;
          if (u.contains('fff4')) notify = c;
        }
      }
      if (_write == null || notify == null) {
        throw 'FFF3/FFF4 characteristics not found';
      }
      await notify.setNotifyValue(true);
      _notifySub = notify.onValueReceived.listen(_onData);
      await _send(0x03); // last start data
      await Future.delayed(const Duration(milliseconds: 600));
      await _send(0x07); // real-time stream
      deviceName.value = d.platformName.isNotEmpty ? d.platformName : 'BM6';
      status.value = 'Connected';
      _notify('Connected to ${d.platformName.isNotEmpty ? d.platformName : 'BM6'}');
      _log('connected, notifications enabled');
    } catch (e) {
      status.value = 'Error: $e';
      _log('error: $e');
      await _cleanup();
      _scheduleRetry();
    }
  }

  Future<void> _send(int op) async {
    try {
      final c = _cmd(op);
      await _write?.write(_aes(c, true), withoutResponse: false);
      _log('TX ${_hex(c)}');
    } catch (e) {
      _log('TX error: $e');
    }
  }

  void _onData(List<int> raw) {
    if (raw.length != 16) {
      _log('RX (len ${raw.length}) ${_hex(raw)}');
      return;
    }
    final dec = _aes(Uint8List.fromList(raw), false);
    _log('RX ${_hex(raw)}\n    DEC ${_hex(dec)}');
    if (dec[0] != 0xd1 || dec[1] != 0x55) return;

    if (dec[2] == 0x03) {
      // last start (crank) data: byte3 = 0xff means "no data"
      if (dec[3] == 0xff) {
        _log('    no start data');
        return;
      }
      final v = ((dec[4] << 8) | dec[5]) / 100;
      final ago = (dec[8] << 8) | dec[9]; // units of 2 minutes
      final when = DateTime.now().subtract(Duration(minutes: ago * 2));
      _log('    start voltage=$v V');
      lastStart.value = StartInfo(v, when);
      return;
    }

    if (dec[2] == 0x07) {
      // 0xff in byte3 is the acknowledge of the start command
      if (dec[3] == 0xff) {
        _log('    ack (ignored)');
        return;
      }
      final t = dec[3] == 1 ? -dec[4] : dec[4];
      final st = dec[5];
      final soc = dec[6];
      final v = ((dec[7] << 8) | dec[8]) / 100;
      final acc = (dec[9] << 8) | dec[10];
      final dcc = (dec[11] << 8) | dec[12];
      if (v == 0) {
        _log('    ignored empty frame');
        return;
      }
      _log('    V=$v T=$t SoC=$soc% status=$st acc=$acc dec=$dcc');
      _publish(v, t, soc, st, acc, dcc);
    }
  }

  void _publish(double v, int t, int soc, int st, int acc, int dcc) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final now = nowMs / 1000;
    voltage.value = v;
    this.soc.value = soc;
    temp.value = t;
    chargeStatus.value = st;
    rapidAcc.value = acc;
    rapidDec.value = dcc;
    points.value = [...points.value, FlSpot(now, v)].takeLast(120);
    if (!simulating.value && _sink != null) {
      _sink!.writeln('$nowMs,$v,$t,$soc,$st,$acc,$dcc');
      if (++_pending >= 10) {
        _pending = 0;
        _sink!.flush();
      }
    }
    tempPoints.value = [
      ...tempPoints.value.where((p) => now - p.x <= 60),
      FlSpot(now, t.toDouble()),
    ];
  }

  // --- UI simulation (no sensor needed) ---
  final simulating = ValueNotifier<bool>(false);
  Timer? _simTimer;

  void toggleSim() {
    if (simulating.value) {
      _simTimer?.cancel();
      simulating.value = false;
      status.value = 'Disconnected';
      deviceName.value = null;
      mac.value = null;
      customName.value = null;
      return;
    }
    simulating.value = true;
    status.value = 'Simulation';
    deviceName.value = 'BM6 (sim)';
    mac.value = '50:54:7B:00:00:00';
    _loadName('50:54:7B:00:00:00');
    lastStart.value = StartInfo(
        9.87, DateTime.now().subtract(const Duration(minutes: 42)));
    points.value = [];
    tempPoints.value = [];
    final rnd = math.Random();
    var n = 0;
    var acc = 0, dcc = 0;
    _simTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      n++;
      final v = 12.9 + 1.4 * math.sin(n / 14) + (rnd.nextDouble() - 0.5) * 0.1;
      final t = 27 + (4 * math.sin(n / 9)).round();
      final soc = (65 + 20 * math.sin(n / 40)).round();
      final st = v > 13.2 ? 2 : 0;
      if (rnd.nextInt(25) == 0) acc++;
      if (rnd.nextInt(30) == 0) dcc++;
      _publish(v, t, soc, st, acc, dcc);
    });
  }

  /// Retries scanning/connecting every 15 s while disconnected.
  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off) return;
    _retryTimer = Timer(retryInterval, () {
      if (_dev == null && !_running && !simulating.value) start();
    });
  }

  /// Current adapter state, waiting briefly for the first real value.
  Future<bool> _bluetoothOn() async {
    try {
      final st = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 5));
      return st == BluetoothAdapterState.on;
    } catch (_) {
      return FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;
    }
  }

  /// Stops retrying while Bluetooth is off and resumes when it is turned on.
  void _watchAdapter() {
    _adapterSub ??= FlutterBluePlus.adapterState.listen((st) {
      if (st == BluetoothAdapterState.on) {
        if (_dev == null && !_running && !simulating.value) start();
      } else if (st == BluetoothAdapterState.off) {
        _retryTimer?.cancel();
        if (!simulating.value) {
          status.value = 'Bluetooth is off';
          _notify('Bluetooth is off');
        }
      }
    });
  }

  Future<void> _startForegroundService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.requestNotificationPermission();
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'zm6_connection',
          channelName: 'ZM6 connection',
          channelDescription: 'Keeps the sensor connection alive.',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          playSound: false,
          enableVibration: false,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          allowWakeLock: true,
        ),
      );
      await FlutterForegroundTask.startService(
        serviceId: 601,
        serviceTypes: [ForegroundServiceTypes.connectedDevice],
        notificationTitle: appName,
        notificationText: 'Searching for the sensor...',
        callback: startCallback,
      );
    } catch (e) {
      _log('foreground service error: $e');
    }
  }

  Future<void> _notify(String text) async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationText: text);
      }
    } catch (_) {}
  }

  Future<void> _cleanup() async {
    await _closeHistory();
    await _notifySub?.cancel();
    await _connSub?.cancel();
    _write = null;
    _dev = null;
    deviceName.value = null;
    _running = false;
  }

  Future<void> stop() async {
    _retryTimer?.cancel();
    final d = _dev;
    await _cleanup();
    try {
      await d?.disconnect();
    } catch (_) {}
    status.value = 'Disconnected';
  }
}

extension on List<FlSpot> {
  List<FlSpot> takeLast(int n) => length <= n ? this : sublist(length - n);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final bm = Bm6.i;
  DateTime _now = DateTime.now();
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    bm.start();
    _clock = Timer.periodic(const Duration(seconds: 1),
        (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final date = '${_now.year}-${_two(_now.month)}-${_two(_now.day)}';
    final time = '${_two(_now.hour)}:${_two(_now.minute)}:${_two(_now.second)}';
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      // distinct background while the simulation is running
      backgroundColor: bm.simulating.value
          ? (dark ? const Color(0xFF3B2A12) : const Color(0xFFFFF3E0))
          : null,
      appBar: AppBar(
        backgroundColor: bm.simulating.value
            ? (dark ? const Color(0xFF3B2A12) : const Color(0xFFFFF3E0))
            : null,
        leading: Padding(
          padding: const EdgeInsets.all(10),
          child: Image.asset('assets/icon/icon.png'),
        ),
        title: ValueListenableBuilder<String?>(
          valueListenable: bm.deviceName,
          builder: (_, name, _) => ValueListenableBuilder<String?>(
            valueListenable: bm.customName,
            builder: (_, custom, _) => Text(
              name == null ? 'ZM6' : (custom ?? name),
              style: TextStyle(
                  color: name != null ? Colors.blue : null,
                  fontWeight: FontWeight.bold),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Connection info',
            icon: const Icon(Icons.bluetooth),
            onPressed: () => _showInfo(context),
          ),
          IconButton(
            tooltip: 'Dark mode',
            icon: Icon(darkMode.value ? Icons.light_mode : Icons.dark_mode),
            onPressed: () => setState(() => darkMode.value = !darkMode.value),
          ),
          IconButton(
            tooltip: 'Reconnect',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await bm.stop();
              bm.start();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(children: [
            _DeviceLine(bm: bm),
            const SizedBox(height: 2),
            Text('$date  $time',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 2),
            ValueListenableBuilder<String>(
              valueListenable: bm.status,
              builder: (_, s, _) =>
                  Text(s, style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(height: 8),
            _buildDashboard(),
            const SizedBox(height: 8),
            _buildStartLabel(),
            const SizedBox(height: 4),
            Expanded(child: _buildChart()),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 72,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: bm.simulating,
                    builder: (_, sim, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: sim ? 'Stop simulation' : 'Simulate data',
                          icon: Icon(sim ? Icons.stop : Icons.play_arrow),
                          visualDensity: VisualDensity.compact,
                          onPressed: bm.toggleSim,
                        ),
                        const Text('SIMULATE',
                            style: TextStyle(fontSize: 9, color: Colors.grey)),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.bug_report),
                      label: const Text('Raw data'),
                      onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const DebugPage())),
                    ),
                    const SizedBox(height: 4),
                    Text('v$appVersion',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                  ]),
                ),
                SizedBox(
                  width: 72,
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: IconButton(
                      tooltip: 'About',
                      icon: const Icon(Icons.info_outline),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _showAbout(context),
                    ),
                  ),
                ),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildDashboard() {
    return ValueListenableBuilder<double?>(
      valueListenable: bm.voltage,
      builder: (_, v, _) => Column(children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: _TempKpi(bm: bm)),
            Expanded(flex: 5, child: _Gauge(voltage: v)),
            Expanded(
              flex: 3,
              child: ValueListenableBuilder<int?>(
                valueListenable: bm.soc,
                builder: (_, soc, _) => _SocDial(soc: soc),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ValueListenableBuilder<int?>(
          valueListenable: bm.chargeStatus,
          builder: (_, st, _) => Text(
            st == null ? 'Status: --' : 'Status: ${chargeStatusLabels[st] ?? 'Unknown ($st)'}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 2),
        ValueListenableBuilder<int?>(
          valueListenable: bm.rapidAcc,
          builder: (_, a, _) => ValueListenableBuilder<int?>(
            valueListenable: bm.rapidDec,
            builder: (_, d, _) => Text(
              'Rapid accel: ${a ?? '--'}   Rapid decel: ${d ?? '--'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildStartLabel() {
    return ValueListenableBuilder<StartInfo?>(
      valueListenable: bm.lastStart,
      builder: (_, s, _) {
        var text = 'Last start voltage: --';
        if (s != null) {
          text = 'Last start voltage: ${s.voltage.toStringAsFixed(2)} V';
          final w = s.when;
          if (w != null) {
            text += '  (${_two(w.day)}/${_two(w.month)} ${_two(w.hour)}:${_two(w.minute)})';
          }
        }
        return Text(text, style: const TextStyle(fontWeight: FontWeight.w600));
      },
    );
  }

  Widget _buildChart() {
    return ValueListenableBuilder<List<FlSpot>>(
      valueListenable: bm.points,
      builder: (_, pts, _) {
        if (pts.length < 2) {
          return const Center(child: Text('Waiting for data...'));
        }
        final ys = pts.map((e) => e.y);
        final minY = ys.reduce(math.min) - 0.2;
        final maxY = ys.reduce(math.max) + 0.2;
        final bands = <HorizontalRangeAnnotation>[];
        for (final b in voltBands) {
          final y1 = math.max(b.from, minY);
          final y2 = math.min(b.to, maxY);
          if (y1 < y2) {
            bands.add(HorizontalRangeAnnotation(
                y1: y1, y2: y2, color: b.color.withValues(alpha: 0.28)));
          }
        }
        return LineChart(
          duration: Duration.zero,
          LineChartData(
            minY: minY,
            maxY: maxY,
            minX: pts.first.x,
            maxX: pts.last.x,
            backgroundColor:
                Theme.of(context).brightness == Brightness.light
                    ? Colors.white
                    : null,
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => spots.map((s) {
                  final d = DateTime.fromMillisecondsSinceEpoch(
                      (s.x * 1000).round());
                  final hms =
                      '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
                  return LineTooltipItem(
                    '${s.y.toStringAsFixed(2)} V\n$hms',
                    const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  );
                }).toList(),
              ),
            ),
            rangeAnnotations:
                RangeAnnotations(horizontalRangeAnnotations: bands),
            gridData: const FlGridData(show: true, drawVerticalLine: true),
            borderData: FlBorderData(show: true),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 24,
                  interval:
                      math.max(1, (pts.last.x - pts.first.x) / 3).roundToDouble(),
                  getTitlesWidget: (value, meta) {
                    final d = DateTime.fromMillisecondsSinceEpoch(
                        (value * 1000).round());
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}',
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
              leftTitles: AxisTitles(
                axisNameWidget:
                    const Text('Volts', style: TextStyle(fontSize: 12)),
                axisNameSize: 20,
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  interval: ((maxY - minY) / 5).clamp(0.1, 5.0),
                  getTitlesWidget: (value, meta) => Text(
                    value.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: pts,
                isCurved: true,
                color: Theme.of(context).brightness == Brightness.light
                    ? Theme.of(context).colorScheme.primary
                    : null,
                barWidth: 2.5,
                dotData: const FlDotData(show: false),
              ),
            ],
          ),
        );
      },
    );
  }

  void _confirmClear(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear history'),
        content: const Text(
            'This deletes the stored history of this device. It cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await bm.clearHistory();
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showInfo(BuildContext context) {
    final d = bm.device;
    final connected = bm.status.value == 'Connected';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Bluetooth connection'),
        content: Text([
          'Status: ${bm.status.value}',
          'Connected: ${connected ? 'yes' : 'no'}',
          'Device: ${d?.platformName ?? '-'}',
          'Address: ${d?.remoteId.str ?? '-'}',
        ].join('\n')),
        actions: [
          TextButton(
              onPressed: () {
                Navigator.pop(context);
                _confirmClear(context);
              },
              child: const Text('Clear history')),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'))
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(appName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Version $appVersion'),
            const SizedBox(height: 8),
            const SelectableText(repoUrl,
                style: TextStyle(color: Colors.blue)),
            const SizedBox(height: 16),
            const Text('By Cadu Rolim',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'))
        ],
      ),
    );
  }
}

/// Device name and MAC line with an edit (rename) button.
class _DeviceLine extends StatelessWidget {
  final Bm6 bm;
  const _DeviceLine({required this.bm});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String?>(
      valueListenable: bm.mac,
      builder: (_, mac, _) => ValueListenableBuilder<String?>(
        valueListenable: bm.customName,
        builder: (_, custom, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                mac == null ? 'No device' : '${custom ?? 'BM6'}  ·  $mac',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (mac != null)
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => _rename(context, custom),
              ),
          ],
        ),
      ),
    );
  }

  void _rename(BuildContext context, String? current) {
    final ctrl = TextEditingController(text: current ?? '');
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(hintText: 'Device name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              bm.rename(ctrl.text);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// Temperature KPI with a 1-minute sparkline below the value.
class _TempKpi extends StatelessWidget {
  final Bm6 bm;
  const _TempKpi({required this.bm});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 8),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const FittedBox(
            child: Text('Temperature', style: TextStyle(fontSize: 11)),
          ),
          const SizedBox(height: 4),
          ValueListenableBuilder<int?>(
            valueListenable: bm.temp,
            builder: (_, t, _) => FittedBox(
              child: Text(t == null ? '--' : '$t °C',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: ValueListenableBuilder<List<FlSpot>>(
              valueListenable: bm.tempPoints,
              builder: (_, pts, _) {
                if (pts.length < 2) return const SizedBox.shrink();
                final ys = pts.map((e) => e.y);
                var minY = ys.reduce(math.min);
                var maxY = ys.reduce(math.max);
                if (maxY - minY < 2) {
                  minY -= 1;
                  maxY += 1;
                }
                return LineChart(
                  duration: Duration.zero,
                  LineChartData(
                    minX: pts.last.x - 60,
                    maxX: pts.last.x,
                    minY: minY,
                    maxY: maxY,
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    lineTouchData: const LineTouchData(enabled: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: pts,
                        isCurved: true,
                        color: Theme.of(context).brightness == Brightness.light
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        barWidth: 2,
                        dotData: const FlDotData(show: false),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

/// Circular digital dial for state of charge.
class _SocDial extends StatelessWidget {
  final int? soc;
  const _SocDial({required this.soc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('SoC', style: TextStyle(fontSize: 11)),
        const SizedBox(height: 6),
        SizedBox(
          width: 70,
          height: 70,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: (soc ?? 0) / 100,
                color: socColor(soc),
                strokeWidth: 7,
                backgroundColor: Colors.grey.withValues(alpha: 0.25),
              ),
            ),
            Text(soc == null ? '--' : '$soc%',
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold)),
          ]),
        ),
      ]),
    );
  }
}

/// Analog gauge with colored status bands, a needle and a blue digital
/// readout (white text) in the middle.
class _Gauge extends StatelessWidget {
  final double? voltage;
  const _Gauge({required this.voltage});

  static const minV = 10.0, maxV = 15.0;

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).colorScheme.onSurface;
    final band = bandFor(voltage);
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _GaugePainter(voltage, fg),
        child: Align(
          alignment: const Alignment(0, 0.92),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: band?.color ?? Colors.blueGrey,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              voltage == null ? '-- V' : '${voltage!.toStringAsFixed(2)} V',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: band?.textColor ?? Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double? v;
  final Color fg;
  _GaugePainter(this.v, this.fg);

  static const start = 3 * math.pi / 4; // 135 deg
  static const sweep = 3 * math.pi / 2; // 270 deg

  double _frac(double volts) =>
      ((volts - _Gauge.minV) / (_Gauge.maxV - _Gauge.minV)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: c, radius: r);

    // colored status bands
    final band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.butt;
    for (final b in voltBands) {
      final f1 = _frac(b.from), f2 = _frac(b.to);
      if (f2 <= f1) continue;
      canvas.drawArc(rect, start + sweep * f1, sweep * (f2 - f1), false,
          band..color = b.color);
    }

    // ticks every 0.5 V
    final tick = Paint()
      ..color = fg.withValues(alpha: 0.7)
      ..strokeWidth = 1.5;
    final n = ((_Gauge.maxV - _Gauge.minV) / 0.5).round();
    for (var i = 0; i <= n; i++) {
      final a = start + sweep * i / n;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * (r - 16), c + d * (r - 7), tick);
    }

    // needle
    final angle = start + sweep * (v == null ? 0 : _frac(v!));
    final tip = c + Offset(math.cos(angle), math.sin(angle)) * (r - 6);
    canvas.drawLine(
        c,
        tip,
        Paint()
          ..color = fg
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(c, 5, Paint()..color = fg);
  }

  @override
  bool shouldRepaint(_GaugePainter o) => o.v != v || o.fg != fg;
}

class DebugPage extends StatelessWidget {
  const DebugPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Raw data')),
      body: SafeArea(
        child: ValueListenableBuilder<List<String>>(
          valueListenable: Bm6.i.log,
          builder: (_, l, _) => ListView.builder(
            reverse: true,
            padding: const EdgeInsets.all(8),
            itemCount: l.length,
            itemBuilder: (_, i) => Text(
              l[l.length - 1 - i],
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}
