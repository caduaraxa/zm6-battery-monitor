import 'package:flutter_test/flutter_test.dart';
import 'package:zm6_monitor/trips.dart';

String rec(double v, int soc, int t, int flags) =>
    (v * 100).round().toRadixString(16).padLeft(3, '0') +
    soc.toRadixString(16).padLeft(2, '0') +
    t.toRadixString(16).padLeft(2, '0') +
    flags.toRadixString(16);

void main() {
  test('decodes a start/stop trip, newest record first', () {
    final base = DateTime(2026, 10, 30, 13, 51);
    // newest -> oldest: idle, stop(+acc/dec), driving, driving, start, idle
    final hex = rec(13.9, 80, 34, 0) +
        rec(14.0, 81, 34, 4) +
        '0003' '0002' +
        rec(14.1, 79, 33, 0) +
        rec(13.8, 78, 31, 0) +
        rec(10.2, 70, 20, 2) +
        rec(12.6, 70, 20, 0);
    final s = parseHistory(hex, base);
    expect(s.length, 6);
    expect(s.first.volt, 12.6);
    final p = buildTrips(s);
    expect(p.trips.length, 1);
    final t = p.trips.single;
    expect(t.start, base.subtract(const Duration(minutes: 8)));
    expect(t.stop, base.subtract(const Duration(minutes: 2)));
    expect(t.acc, 3);
    expect(t.dec, 2);
    expect(t.vMin, 10.2);
    expect(t.vMax, 14.1);
    expect(t.duration, const Duration(minutes: 6));
  });
}
