import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart' show AESEngine;

final darkMode = ValueNotifier<bool>(false);

void main() => runApp(ValueListenableBuilder<bool>(
      valueListenable: darkMode,
      builder: (_, dark, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.blue),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.blue, brightness: Brightness.dark),
        themeMode: dark ? ThemeMode.dark : ThemeMode.light,
        home: const HomePage(),
      ),
    ));

/// BLE connection and data singleton.
class Bm6 {
  static final Bm6 i = Bm6._();
  Bm6._();

  static final _key = Uint8List.fromList(
      [108, 101, 97, 103, 101, 110, 100, 255, 254, 48, 49, 48, 48, 48, 48, 57]);
  static final _cmd = Uint8List.fromList(
      [0xd1, 0x55, 0x07, ...List.filled(13, 0)]);

  final voltage = ValueNotifier<double?>(null);
  final status = ValueNotifier<String>('Disconnected');
  final soc = ValueNotifier<int?>(null);
  final temp = ValueNotifier<int?>(null);
  final deviceName = ValueNotifier<String?>(null);
  BluetoothDevice? get device => _dev;
  final points = ValueNotifier<List<FlSpot>>([]);
  final log = ValueNotifier<List<String>>([]);

  final _sw = Stopwatch()..start();
  BluetoothDevice? _dev;
  StreamSubscription? _scanSub, _notifySub, _connSub;
  Timer? _poll;
  BluetoothCharacteristic? _write;
  bool _running = false;

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

  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
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
        status.value = 'BM6 not found';
        _log('no BM6 found');
        _running = false;
      }
    } catch (e) {
      status.value = 'Error: $e';
      _log('error: $e');
      _running = false;
    }
  }

  Future<void> _connect(BluetoothDevice d) async {
    try {
      status.value = 'Connecting to ${d.remoteId}...';
      _log('connecting to ${d.remoteId}');
      await d.connect(license: License.free, timeout: const Duration(seconds: 30));
      _connSub = d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _log('disconnected');
          status.value = 'Disconnected';
          _cleanup();
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
      await _sendCmd();
      deviceName.value =
          d.platformName.isNotEmpty ? d.platformName : 'BM6';
      status.value = 'Connected';
      _log('connected, notifications enabled');
    } catch (e) {
      status.value = 'Error: $e';
      _log('error: $e');
      await _cleanup();
    }
  }

  Future<void> _sendCmd() async {
    try {
      await _write?.write(_aes(_cmd, true), withoutResponse: false);
      _log('TX ${_hex(_cmd)}');
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
    final h = _hex(dec);
    _log('RX ${_hex(raw)}\n    DEC $h');
    if (dec[0] == 0xd1 && dec[1] == 0x55 && dec[2] == 0x07) {
      final v = (((dec[7] & 0x0f) << 8) | dec[8]) / 100;
      final t = dec[3] == 1 ? -dec[4] : dec[4];
      final soc = dec[6];
      // d15507ff00.. is an empty frame the sensor sends periodically
      // (all zeros); the original Python also waits for a non-zero reading.
      if (dec[3] == 0xff || v == 0) {
        _log('    ignored empty frame');
        return;
      }
      _log('    V=$v  T=$t C  SoC=$soc%');
      _publish(v, t, soc);
    }
  }

  void _publish(double v, int t, int soc) {
    voltage.value = v;
    this.soc.value = soc;
    temp.value = t;
    points.value = [
      ...points.value,
      FlSpot(_sw.elapsedMilliseconds / 1000, v),
    ].takeLast(120);
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
      return;
    }
    simulating.value = true;
    status.value = 'Simulation';
    deviceName.value = 'BM6 (sim)';
    points.value = [];
    final rnd = math.Random();
    var n = 0;
    _simTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      n++;
      final v = 13.2 + 0.9 * math.sin(n / 12) + (rnd.nextDouble() - 0.5) * 0.1;
      final t = 27 + (3 * math.sin(n / 30)).round();
      final soc = (65 + 20 * math.sin(n / 40)).round();
      _publish(v, t, soc);
    });
  }

  Future<void> _cleanup() async {
    _poll?.cancel();
    await _notifySub?.cancel();
    await _connSub?.cancel();
    _write = null;
    _dev = null;
    deviceName.value = null;
    _running = false;
  }

  Future<void> stop() async {
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
    return Scaffold(
      appBar: AppBar(
        leading: ValueListenableBuilder<bool>(
          valueListenable: bm.simulating,
          builder: (_, sim, _) => IconButton(
            tooltip: sim ? 'Stop simulation' : 'Simulate data',
            icon: Icon(sim ? Icons.stop : Icons.play_arrow),
            onPressed: bm.toggleSim,
          ),
        ),
        title: ValueListenableBuilder<String?>(
          valueListenable: bm.deviceName,
          builder: (_, name, _) => Text(
            name ?? 'ZM6',
            style: TextStyle(
                color: name != null ? Colors.blue : null,
                fontWeight: FontWeight.bold),
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
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Text('$date  $time',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            ValueListenableBuilder<String>(
              valueListenable: bm.status,
              builder: (_, s, _) =>
                  Text(s, style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<double?>(
              valueListenable: bm.voltage,
              builder: (_, v, _) => ValueListenableBuilder<int?>(
                valueListenable: bm.soc,
                builder: (_, soc, _) => ValueListenableBuilder<int?>(
                  valueListenable: bm.temp,
                  builder: (_, t, _) => Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: _Kpi(
                          label: 'Temperature',
                          value: t == null ? '--' : '$t °C',
                        ),
                      ),
                      Expanded(flex: 2, child: _Gauge(voltage: v)),
                      Expanded(child: _SocDial(soc: soc)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ValueListenableBuilder<List<FlSpot>>(
                valueListenable: bm.points,
                builder: (_, pts, _) {
                  if (pts.length < 2) {
                    return const Center(child: Text('Waiting for data...'));
                  }
                  final ys = pts.map((e) => e.y);
                  final minY = ys.reduce((a, b) => a < b ? a : b) - 0.1;
                  final maxY = ys.reduce((a, b) => a > b ? a : b) + 0.1;
                  return LineChart(
                    duration: Duration.zero,
                    LineChartData(
                      minY: minY,
                      maxY: maxY,
                      minX: pts.first.x,
                      maxX: pts.last.x,
                      gridData: const FlGridData(
                        show: true,
                        drawVerticalLine: true,
                      ),
                      borderData: FlBorderData(show: true),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                        bottomTitles: const AxisTitles(),
                        leftTitles: AxisTitles(
                          axisNameWidget: const Text('V'),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
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
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.bug_report),
              label: const Text('Raw data'),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DebugPage())),
            ),
          ]),
        ),
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
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'))
        ],
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
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text('SoC', style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 6),
      SizedBox(
        width: 72,
        height: 72,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: (soc ?? 0) / 100,
              strokeWidth: 7,
              backgroundColor: Colors.grey.withValues(alpha: 0.25),
            ),
          ),
          Text(soc == null ? '--' : '$soc%',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ]),
      ),
    ]);
  }
}

class _Kpi extends StatelessWidget {
  final String label, value;
  const _Kpi({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 6),
          FittedBox(
            child: Text(value,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          ),
        ]),
      ),
    );
  }
}

/// Analog gauge (8-16 V) with needle and the digital value in the middle.
class _Gauge extends StatelessWidget {
  final double? voltage;
  const _Gauge({required this.voltage});

  static const minV = 8.0, maxV = 16.0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _GaugePainter(voltage, cs.onSurface, cs.primary),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 56),
            child: Text(
              voltage == null ? '-- V' : '${voltage!.toStringAsFixed(1)} V',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double? v;
  final Color fg, accent;
  _GaugePainter(this.v, this.fg, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    const start = 3 * math.pi / 4; // 135 deg
    const sweep = 3 * math.pi / 2; // 270 deg
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 8;
    final rect = Rect.fromCircle(center: c, radius: r);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..color = fg.withValues(alpha: 0.2);
    canvas.drawArc(rect, start, sweep, false, arc);

    final frac = v == null
        ? 0.0
        : ((v! - _Gauge.minV) / (_Gauge.maxV - _Gauge.minV)).clamp(0.0, 1.0);
    canvas.drawArc(rect, start, sweep * frac, false, arc..color = accent);

    final tick = Paint()
      ..color = fg.withValues(alpha: 0.6)
      ..strokeWidth = 1.5;
    for (var i = 0; i <= 8; i++) {
      final a = start + sweep * i / 8;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * (r - 14), c + d * (r - 6), tick);
    }

    final angle = start + sweep * frac;
    final tip = c + Offset(math.cos(angle), math.sin(angle)) * (r - 18);
    canvas.drawLine(
        c,
        tip,
        Paint()
          ..color = Colors.red
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    canvas.drawCircle(c, 5, Paint()..color = Colors.red);
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
      body: SafeArea(child: ValueListenableBuilder<List<String>>(
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
      )),
    );
  }
}

