/// Start/trip history decoded from the BM6 on-device log.
///
/// The sensor stores one 4-byte record every 2 minutes (newest first):
/// 3 hex = voltage*100, 2 hex = SoC, 2 hex = temperature, 1 hex = flags
/// (bit 3 = negative temperature, bits 2..0 = event: 010 start, 100 stop).
/// A stop record is followed by one extra 4-byte record with the rapid
/// acceleration / deceleration counters (it does not take a time slot).
library;

import 'dart:math' as math;

const historySlot = Duration(minutes: 2);

class HistSample {
  final DateTime time;
  final double volt;
  final int soc, temp;

  /// 0 = none, 1 = engine start, 2 = engine stop.
  final int event;
  final int acc, dec;
  const HistSample(this.time, this.volt, this.soc, this.temp, this.event,
      [this.acc = 0, this.dec = 0]);
}

/// Decodes the concatenated hex payload of a history reply. [base] is the
/// time of the newest slot. Returns the samples oldest first.
List<HistSample> parseHistory(String hex, DateTime base) {
  hex = hex.toUpperCase();
  // the sensor pads with empty records; the original app skips them
  // without consuming a time slot
  var i = 0;
  while (hex.startsWith('00000000', i)) {
    i += 8;
  }
  final out = <HistSample>[];
  var slot = 0;
  while (i + 8 <= hex.length) {
    final volt = int.parse(hex.substring(i, i + 3), radix: 16) / 100;
    final soc = int.parse(hex.substring(i + 3, i + 5), radix: 16);
    var temp = int.parse(hex.substring(i + 5, i + 7), radix: 16);
    final flags = int.parse(hex[i + 7], radix: 16);
    if (flags & 8 != 0) temp = -temp;
    final ev = flags & 7;
    var event = 0, acc = 0, dec = 0;
    var next = i + 8;
    if (ev == 2) {
      event = 1;
    } else if (ev == 4) {
      event = 2;
      if (i + 16 <= hex.length) {
        acc = int.parse(hex.substring(i + 8, i + 12), radix: 16);
        dec = int.parse(hex.substring(i + 12, i + 16), radix: 16);
      }
      next = i + 16;
    }
    if (volt != 0 || event != 0) {
      out.add(HistSample(
          base.subtract(historySlot * slot), volt, soc, temp, event, acc, dec));
    }
    slot++;
    i = next;
  }
  return out.reversed.toList();
}

class Trip {
  DateTime start;

  /// null while the engine is running (or the stop record was not seen).
  DateTime? stop;
  double vStart, vMin, vMax;
  int tStart, socStart;
  int? socEnd;
  int acc, dec;
  Trip({
    required this.start,
    this.stop,
    required this.vStart,
    required this.vMin,
    required this.vMax,
    required this.tStart,
    required this.socStart,
    this.socEnd,
    this.acc = 0,
    this.dec = 0,
  });

  Duration? get duration => stop?.difference(start);

  Map<String, dynamic> toJson() => {
        's': start.millisecondsSinceEpoch,
        if (stop != null) 'e': stop!.millisecondsSinceEpoch,
        'v': vStart,
        'vmin': vMin,
        'vmax': vMax,
        't': tStart,
        'soc': socStart,
        if (socEnd != null) 'soce': socEnd,
        'acc': acc,
        'dec': dec,
      };

  factory Trip.fromJson(Map<String, dynamic> j) => Trip(
        start: DateTime.fromMillisecondsSinceEpoch(j['s'] as int),
        stop: j['e'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(j['e'] as int),
        vStart: (j['v'] as num).toDouble(),
        vMin: (j['vmin'] as num).toDouble(),
        vMax: (j['vmax'] as num).toDouble(),
        tStart: j['t'] as int,
        socStart: j['soc'] as int,
        socEnd: j['soce'] as int?,
        acc: j['acc'] as int? ?? 0,
        dec: j['dec'] as int? ?? 0,
      );
}

class TripParse {
  final List<Trip> trips;

  /// A stop whose start is older than the requested window.
  final HistSample? orphanStop;
  const TripParse(this.trips, this.orphanStop);
}

/// Groups chronological [samples] into trips (start event .. stop event).
TripParse buildTrips(List<HistSample> samples) {
  final trips = <Trip>[];
  HistSample? orphan;
  List<HistSample>? cur;

  void close(HistSample? stop) {
    final c = cur!;
    final volts = c.map((s) => s.volt).where((v) => v > 0).toList();
    final v0 = volts.isEmpty ? 0.0 : volts.first;
    trips.add(Trip(
      start: c.first.time,
      stop: stop?.time,
      vStart: v0,
      vMin: volts.isEmpty ? 0 : volts.reduce(math.min),
      vMax: volts.isEmpty ? 0 : volts.reduce(math.max),
      tStart: c.first.temp,
      socStart: c.first.soc,
      socEnd: stop?.soc,
      acc: stop?.acc ?? 0,
      dec: stop?.dec ?? 0,
    ));
    cur = null;
  }

  for (final s in samples) {
    if (s.event == 1) {
      if (cur != null) close(null);
      cur = [s];
    } else if (cur != null) {
      cur!.add(s);
      if (s.event == 2) close(s);
    } else if (s.event == 2) {
      orphan = s;
    }
  }
  if (cur != null) close(null);
  return TripParse(trips, orphan);
}

/// Merges freshly decoded trips into the stored list (newest data wins).
/// Starts closer than [tolerance] are the same trip, because the slot grid
/// can shift by a slot between two syncs.
List<Trip> mergeTrips(List<Trip> stored, TripParse p,
    {Duration tolerance = const Duration(minutes: 4)}) {
  final out = [...stored];
  final o = p.orphanStop;
  if (o != null) {
    for (var i = out.length - 1; i >= 0; i--) {
      final t = out[i];
      if (t.stop == null && t.start.isBefore(o.time)) {
        t.stop = o.time;
        t.socEnd = o.soc;
        t.acc = o.acc;
        t.dec = o.dec;
        break;
      }
    }
  }
  for (final n in p.trips) {
    final i = out.indexWhere(
        (t) => t.start.difference(n.start).abs() <= tolerance);
    if (i >= 0) {
      final old = out[i];
      // a partial re-read (window began mid-trip) must not shrink the range
      n.vMin = math.min(n.vMin, old.vMin);
      n.vMax = math.max(n.vMax, old.vMax);
      out[i] = n;
    } else {
      out.add(n);
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out.length > 500 ? out.sublist(out.length - 500) : out;
}

/// Cranking (engine start) test the sensor keeps for the last start only.
class CrankTest {
  final DateTime time;
  final double volt;
  final int durationMs;
  const CrankTest(this.time, this.volt, this.durationMs);

  Map<String, dynamic> toJson() =>
      {'t': time.millisecondsSinceEpoch, 'v': volt, 'd': durationMs};

  factory CrankTest.fromJson(Map<String, dynamic> j) => CrankTest(
        DateTime.fromMillisecondsSinceEpoch(j['t'] as int),
        (j['v'] as num).toDouble(),
        j['d'] as int,
      );
}

/// The crank test recorded for [t], if any (times are 2-minute accurate).
CrankTest? crankFor(Trip t, List<CrankTest> cranks) {
  CrankTest? best;
  var bestD = const Duration(minutes: 6);
  for (final c in cranks) {
    final d = c.time.difference(t.start).abs();
    if (d <= bestD) {
      best = c;
      bestD = d;
    }
  }
  return best;
}
