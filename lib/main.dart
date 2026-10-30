import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart' show AESEngine;
import 'package:shared_preferences/shared_preferences.dart';

import 'trips.dart';

const appName = 'ZM6 Battery Monitor';
const appVersion = '0.4.2'; // keep in sync with pubspec.yaml
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
  final trips = ValueNotifier<List<Trip>>([]);
  final cranks = ValueNotifier<List<CrankTest>>([]);

  /// 0..1 while the on-device history is downloading, null otherwise.
  final syncProgress = ValueNotifier<double?>(null);

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
  static const _maxGapS = 300; // gap (s) that breaks the chart line

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
          if (v.isNotEmpty && x - v.last.x > _maxGapS) v.clear();
          v.add(FlSpot(x, volt));
          if (nowS - x <= 60) t.add(FlSpot(x, temp.toDouble()));
        }
        // Drop history older than the gap limit relative to now, so the
        // first live sample doesn't connect to yesterday's data.
        if (v.isNotEmpty && nowS - v.last.x > _maxGapS) v.clear();
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
    trips.value = [];
    cranks.value = [];
    try {
      if (m != null) {
        for (final f in [await _tripsFile(m), await _cranksFile(m)]) {
          if (await f.exists()) await f.delete();
        }
        final p = await SharedPreferences.getInstance();
        await p.remove('hsync_$m');
      }
    } catch (_) {}
    _log('history cleared');
  }

  // --- start (trip) history: read from the sensor, cached per device ---
  Future<File> _tripsFile(String address) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/trips_${address.replaceAll(':', '')}.json');
  }

  Future<File> _cranksFile(String address) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/cranks_${address.replaceAll(':', '')}.json');
  }

  Future<void> _loadTrips(String address) async {
    try {
      final f = await _tripsFile(address);
      if (await f.exists()) {
        trips.value = [
          for (final j in jsonDecode(await f.readAsString()) as List)
            Trip.fromJson(j as Map<String, dynamic>)
        ];
      }
      final c = await _cranksFile(address);
      if (await c.exists()) {
        cranks.value = [
          for (final j in jsonDecode(await c.readAsString()) as List)
            CrankTest.fromJson(j as Map<String, dynamic>)
        ];
      }
    } catch (e) {
      _log('trips load error: $e');
    }
  }

  Future<void> _saveTrips() async {
    final m = mac.value;
    if (m == null || simulating.value) return;
    try {
      await (await _tripsFile(m)).writeAsString(
          jsonEncode([for (final t in trips.value) t.toJson()]));
      await (await _cranksFile(m)).writeAsString(
          jsonEncode([for (final c in cranks.value) c.toJson()]));
    } catch (e) {
      _log('trips save error: $e');
    }
  }

  void _addCrank(CrankTest c) {
    final l = [...cranks.value];
    final i = l.indexWhere(
        (x) => x.time.difference(c.time).abs() <= const Duration(minutes: 4));
    if (i >= 0) {
      l[i] = c;
    } else {
      l.add(c);
    }
    l.sort((a, b) => a.time.compareTo(b.time));
    cranks.value = l.length > 500 ? l.sublist(l.length - 500) : l;
    _saveTrips();
  }

  // On-device history download (command 0x05).
  static const _maxSlots = 22320; // 31 days, the size the original app asks
  StringBuffer? _hist;
  int _histCount = -1;
  DateTime? _histBase;
  Timer? _histTimeout;
  String _histTail = ''; // last chars, to find a marker split across blocks
  DateTime? _lastSyncTry;

  /// Asks the sensor for its stored history (only what is newer than the
  /// last sync) and merges the decoded starts into [trips].
  Future<void> syncHistory() async {
    if (_write == null || simulating.value || _hist != null) return;
    final m = mac.value;
    if (m == null) return;
    // protect the sensor from repeated requests (e.g. reconnect loops)
    final lt = _lastSyncTry;
    if (lt != null && DateTime.now().difference(lt) < const Duration(seconds: 30)) {
      return;
    }
    _lastSyncTry = DateTime.now();
    var base = DateTime.now();
    base = DateTime(base.year, base.month, base.day, base.hour, base.minute);
    if (base.minute % 2 == 0) base = base.subtract(const Duration(minutes: 1));
    var n = _maxSlots;
    try {
      final p = await SharedPreferences.getInstance();
      final last = p.getInt('hsync_$m');
      // a trip still open must be re-read from its start
      DateTime? from =
          last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
      for (final t in trips.value) {
        if (t.stop == null && from != null && t.start.isBefore(from)) {
          from = t.start;
        }
      }
      if (from != null) {
        n = base.difference(from).inMinutes ~/ 2 + 10;
      }
    } catch (_) {}
    // same bounds the original app uses: never 0/negative, never above 31 days
    n = n.clamp(10, _maxSlots);
    _hist = StringBuffer();
    _histTail = '';
    _histCount = -1;
    _histBase = base;
    syncProgress.value = 0;
    _histTimeout?.cancel();
    _histTimeout = Timer(const Duration(seconds: 90), () {
      _log('history sync timed out, asking the sensor to stop');
      _endSync();
      _send(0x06); // stop reading history
    });
    final c = Uint8List(16)
      ..[0] = 0xd1
      ..[1] = 0x55
      ..[2] = 0x05
      ..[6] = (n >> 16) & 0xff
      ..[7] = (n >> 8) & 0xff
      ..[8] = n & 0xff;
    _log('history sync: $n slots');
    try {
      await _write?.write(_aes(c, true), withoutResponse: false);
      _log('TX ${_hex(c)}');
    } catch (e) {
      _log('TX error: $e');
      _endSync();
    }
  }

  void _endSync() {
    _histTimeout?.cancel();
    _hist = null;
    _histCount = -1;
    syncProgress.value = null;
  }

  Future<void> _finishSync(String hex) async {
    final base = _histBase!;
    _endSync();
    try {
      final samples = parseHistory(hex, base);
      final p = buildTrips(samples);
      trips.value = mergeTrips(trips.value, p);
      _log('history: ${samples.length} samples, ${p.trips.length} starts');
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('hsync_${mac.value}', base.millisecondsSinceEpoch);
      await _saveTrips();
    } catch (e) {
      _log('history parse error: $e');
    }
  }

  /// Handles a decrypted block while a history download is running.
  /// Returns true when the block was consumed.
  bool _histBlock(Uint8List dec) {
    final h = _hist;
    if (h == null) return false;
    final real = dec[0] == 0xd1 && dec[1] == 0x55 && dec[2] == 0x07;
    if (real) return false; // live data keeps flowing
    if (_histCount < 0) {
      if (dec[0] == 0xd1 && dec[1] == 0x55 && dec[2] == 0x05) {
        _histCount = (dec[3] << 8) | dec[4];
        _log('history: $_histCount records announced');
        if (_histCount <= 0) _endSync();
        return true;
      }
      return false;
    }
    final hex = _hex(dec).toUpperCase();
    if (hex.contains('FEFEFE')) return true; // empty marker
    final at = (_histTail + hex).indexOf('FFFEFE');
    if (at >= 0) {
      final end = h.length - _histTail.length + at;
      h.write(hex);
      _finishSync(h.toString().substring(0, end));
    } else {
      h.write(hex);
      final all = _histTail + hex;
      _histTail = all.substring(all.length - 5);
      syncProgress.value =
          math.min(h.length / (_histCount * 8), 0.99).toDouble();
    }
    return true;
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
      await _loadTrips(d.remoteId.str);
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
      await Future.delayed(const Duration(seconds: 2));
      await syncHistory();
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
    // a notification may carry several 16-byte blocks
    if (raw.isEmpty || raw.length % 16 != 0) {
      _log('RX (len ${raw.length}) ${_hex(raw)}');
      return;
    }
    for (var o = 0; o < raw.length; o += 16) {
      _onBlock(Uint8List.fromList(raw.sublist(o, o + 16)));
    }
  }

  void _onBlock(Uint8List block) {
    final dec = _aes(block, false);
    if (_histBlock(dec)) return;
    _log('RX ${_hex(block)}\n    DEC ${_hex(dec)}');
    if (dec[0] != 0xd1 || dec[1] != 0x55) return;

    if (dec[2] == 0x03) {
      // last start (crank) data: byte3 = 0xff means "no data"
      if (dec[3] == 0xff) {
        _log('    no start data');
        return;
      }
      final v = ((dec[4] << 8) | dec[5]) / 100;
      final ms = (dec[6] << 8) | dec[7];
      final ago = (dec[8] << 8) | dec[9]; // units of 2 minutes
      final when = DateTime.now().subtract(Duration(minutes: ago * 2));
      _log('    start voltage=$v V');
      lastStart.value = StartInfo(v, when);
      _addCrank(CrankTest(when, v, ms));
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
    final prev = points.value;
    // A long silence (e.g. sensor reconnected next day) must not be drawn as
    // a line across the gap: start the chart fresh.
    final base =
        prev.isNotEmpty && now - prev.last.x > _maxGapS ? <FlSpot>[] : prev;
    points.value = [...base, FlSpot(now, v)].takeLast(120);
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
      trips.value = [];
      cranks.value = [];
      return;
    }
    simulating.value = true;
    final now = DateTime.now();
    final r = math.Random(7);
    trips.value = [
      for (var k = 9; k >= 0; k--)
        () {
          final s = now.subtract(Duration(hours: 5 + k * 9, minutes: k * 7));
          final len = 8 + r.nextInt(70);
          return Trip(
            start: s,
            stop: s.add(Duration(minutes: len)),
            vStart: 12.2 + r.nextDouble() * 0.5,
            vMin: 11.8 + r.nextDouble() * 0.4,
            vMax: 14.0 + r.nextDouble() * 0.4,
            tStart: 15 + r.nextInt(15),
            socStart: 55 + r.nextInt(30),
            socEnd: 70 + r.nextInt(25),
            acc: r.nextInt(6),
            dec: r.nextInt(6),
          );
        }()
    ];
    cranks.value = [
      for (final t in trips.value)
        CrankTest(t.start, 9 + r.nextDouble() * 2, 300 + r.nextInt(500)),
    ];
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
    _endSync();
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
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
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
        centerTitle: landscape,
        title: landscape
            ? _landscapeTitle(date, time)
            : ValueListenableBuilder<String?>(
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
          child: landscape ? _buildLandscape() : _buildPortrait(date, time),
        ),
      ),
    );
  }

  Widget _buildPortrait(String date, String time) {
    return Column(children: [
      _DeviceLine(bm: bm),
      const SizedBox(height: 2),
      Text('$date  $time', style: Theme.of(context).textTheme.titleMedium),
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
      _buildBottomRow(),
    ]);
  }

  /// Two 50% columns: gauges on the left, chart and buttons on the right.
  Widget _buildLandscape() {
    return Row(children: [
      Expanded(
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(width: 420, child: _buildDashboard()),
          ),
        ),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(children: [
          _buildStartLabel(),
          const SizedBox(height: 4),
          Expanded(child: _buildChart()),
          const SizedBox(height: 8),
          _buildBottomRow(),
        ]),
      ),
    ]);
  }

  /// Centered app bar content for landscape: device, clock and status.
  Widget _landscapeTitle(String date, String time) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _DeviceLine(bm: bm),
      ValueListenableBuilder<String>(
        valueListenable: bm.status,
        builder: (_, s, _) => Text('$date  $time  ·  $s', style: small),
      ),
    ]);
  }

  Widget _buildBottomRow() {
    return Row(
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
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
          InkWell(
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const StartsPage())),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Text('[history]',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      decoration: TextDecoration.underline)),
            ),
          ),
        ]);
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
    showDialog(context: context, builder: (_) => const _AboutDialog());
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

enum _UpdateState { checking, upToDate, available, downloading, error }

/// About dialog that checks GitHub for a newer release and installs it.
class _AboutDialog extends StatefulWidget {
  const _AboutDialog();

  @override
  State<_AboutDialog> createState() => _AboutDialogState();
}

class _AboutDialogState extends State<_AboutDialog> {
  static const _channel = MethodChannel('zm6/updater');
  static const _apiUrl =
      'https://api.github.com/repos/caduaraxa/zm6-battery-monitor/releases/latest';

  _UpdateState _state = _UpdateState.checking;
  String? _latest, _apkUrl, _message;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _check();
  }

  /// True if [a] is a newer version than [b] (both "x.y.z").
  static bool _newer(String a, String b) {
    List<int> parse(String v) => v
        .replaceFirst(RegExp(r'^v'), '')
        .split('+')
        .first
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final x = parse(a), y = parse(b);
    for (var i = 0; i < math.max(x.length, y.length); i++) {
      final xi = i < x.length ? x[i] : 0, yi = i < y.length ? y[i] : 0;
      if (xi != yi) return xi > yi;
    }
    return false;
  }

  Future<void> _check() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final is64 = await _channel.invokeMethod<bool>('is64bit') ?? true;
      final req = await client.getUrl(Uri.parse(_apiUrl));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'zm6-monitor');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw 'GitHub returned ${res.statusCode}';
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = json['tag_name'] as String;
      String? url;
      for (final asset in (json['assets'] as List? ?? [])) {
        final name = asset['name'] as String;
        if (!name.endsWith('.apk')) continue;
        if (name.contains('32bits') != is64) {
          url = asset['browser_download_url'] as String;
        }
      }
      if (!mounted) return;
      setState(() {
        _latest = tag.replaceFirst(RegExp(r'^v'), '');
        if (_newer(tag, appVersion) && url != null) {
          _apkUrl = url;
          _state = _UpdateState.available;
        } else {
          _state = _UpdateState.upToDate;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _UpdateState.error;
        _message = 'Could not check for updates.';
      });
    } finally {
      client.close();
    }
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _state = _UpdateState.downloading;
      _progress = null;
      _message = null;
    });
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/zm6-update.apk');
      final req = await client.getUrl(Uri.parse(_apkUrl!));
      req.headers.set('User-Agent', 'zm6-monitor');
      final res = await req.close();
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      final total = res.contentLength;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (mounted && total > 0) setState(() => _progress = got / total);
      }
      await sink.close();
      final r = await _channel
          .invokeMethod<String>('installApk', {'path': file.path});
      if (!mounted) return;
      setState(() {
        _state = _UpdateState.available;
        if (r == 'permission') {
          _message = 'Allow installing from this app, then tap again.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _UpdateState.error;
        _message = 'Download failed.';
      });
    } finally {
      client.close();
    }
  }

  Widget _updateSection() {
    switch (_state) {
      case _UpdateState.checking:
        return const Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Checking for updates...'),
        ]);
      case _UpdateState.upToDate:
        return const Text('You have the latest version.');
      case _UpdateState.available:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New version available: $_latest'),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_message!,
                    style: const TextStyle(fontSize: 12, color: Colors.orange)),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _downloadAndInstall,
              icon: const Icon(Icons.system_update),
              label: const Text('Download and install update'),
            ),
          ],
        );
      case _UpdateState.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_progress == null
                ? 'Downloading update...'
                : 'Downloading update... ${(_progress! * 100).round()}%'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress),
          ],
        );
      case _UpdateState.error:
        return Row(children: [
          Expanded(
              child: Text(_message ?? 'Error',
                  style: const TextStyle(color: Colors.redAccent))),
          TextButton(
              onPressed: () {
                setState(() => _state = _UpdateState.checking);
                _check();
              },
              child: const Text('Retry')),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(appName),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Version $appVersion'),
          const SizedBox(height: 8),
          const SelectableText(repoUrl, style: TextStyle(color: Colors.blue)),
          const SizedBox(height: 16),
          _updateSection(),
          const SizedBox(height: 16),
          const Text('By Cadu Rolim',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: _state == _UpdateState.downloading
                ? null
                : () => Navigator.pop(context),
            child: const Text('Close'))
      ],
    );
  }
}

/// Engine starts read from the sensor's on-device log.
class StartsPage extends StatelessWidget {
  const StartsPage({super.key});

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime d) =>
      '${_two(d.day)}/${_two(d.month)}/${d.year} ${_two(d.hour)}:${_two(d.minute)}';

  static String _dur(Duration d) {
    if (d.inHours > 0) return '${d.inHours} h ${d.inMinutes % 60} min';
    return '${d.inMinutes} min';
  }

  @override
  Widget build(BuildContext context) {
    final bm = Bm6.i;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Start history'),
        actions: [
          ValueListenableBuilder<double?>(
            valueListenable: bm.syncProgress,
            builder: (_, p, _) => p != null
                ? Padding(
                    padding: const EdgeInsets.all(14),
                    child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            value: p > 0 ? p : null, strokeWidth: 3)))
                : IconButton(
                    tooltip: 'Read from sensor',
                    icon: const Icon(Icons.sync),
                    onPressed: bm.syncHistory,
                  ),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<Trip>>(
        valueListenable: bm.trips,
        builder: (_, trips, _) => ValueListenableBuilder<List<CrankTest>>(
          valueListenable: bm.cranks,
          builder: (_, cranks, _) {
            if (trips.isEmpty) {
              return const Center(
                  child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No starts yet. Connect to the sensor and tap the sync '
                    'button to read its stored history.',
                    textAlign: TextAlign.center),
              ));
            }
            final list = trips.reversed.toList();
            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: list.length,
              itemBuilder: (_, i) => _card(context, list[i], cranks),
            );
          },
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Trip t, List<CrankTest> cranks) {
    final c = crankFor(t, cranks);
    final style = Theme.of(context).textTheme.bodyMedium;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Expanded(child: Text(k, style: style)),
            Text(v, style: style?.copyWith(fontWeight: FontWeight.w600)),
          ]),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_fmt(t.start),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          if (c != null) ...[
            row('Cranking voltage', '${c.volt.toStringAsFixed(2)} V'),
            row('Cranking time', '${c.durationMs} ms'),
          ],
          row('Voltage at start', '${t.vStart.toStringAsFixed(2)} V'),
          row('Voltage min / max',
              '${t.vMin.toStringAsFixed(2)} / ${t.vMax.toStringAsFixed(2)} V'),
          row('Engine on',
              t.duration == null ? 'running / unknown' : _dur(t.duration!)),
          if (t.stop != null) row('Stopped at', _fmt(t.stop!)),
          row('SoC', '${t.socStart}% → ${t.socEnd != null ? '${t.socEnd}%' : '--'}'),
          row('Temperature at start', '${t.tStart} °C'),
          row('Rapid accel / decel', '${t.acc} / ${t.dec}'),
        ]),
      ),
    );
  }
}
