// Sense Remote: turns the session's quality values into a [SenseLinkSample] (YH O13; TK7).
// Pure Dart: the bridge reads `QualityMonitorData` (models/model.dart, fed by the
// `update_quality_status` event: `delay`, `fps`, D1's `last_frame_ms` and `loss_est`)
// and passes the raw fields here. Ages are counted up to *now*, so a frozen link —
// which sends no event — still ages every tick.
import '../../data/screen_still.dart' show senseParseSpeedMbit;
import '../link_machine.dart';

/// "22" / "22ms" → 22.
double? senseParseNumber(String? v) {
  if (v == null) return null;
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(v);
  return m == null ? null : double.tryParse(m.group(0)!);
}

/// "60" or, for all displays, "60 0 12" → the best display (60).
double? senseParseFps(String? v) {
  if (v == null) return null;
  double? best;
  for (final m in RegExp(r'\d+(\.\d+)?').allMatches(v)) {
    final n = double.parse(m.group(0)!);
    if (best == null || n > best) best = n;
  }
  return best;
}

SenseLinkSample senseLinkSample({
  required DateTime now,
  String? delay,
  String? fps,
  double? lossEst,
  int? lastFrameMs,
  DateTime? lastFrameAt,
  DateTime? probeAt,
  DateTime? watchingSince,
  String? speed,
}) {
  // Nothing older than the start of watching (connect / reconnect) counts.
  if (watchingSince != null) {
    if (lastFrameAt != null && lastFrameAt.isBefore(watchingSince)) {
      lastFrameMs = 0;
      lastFrameAt = watchingSince;
    }
    if (probeAt == null || probeAt.isBefore(watchingSince)) probeAt = watchingSince;
  }
  Duration? frameAge;
  if (lastFrameMs != null && lastFrameAt != null) {
    frameAge = Duration(milliseconds: lastFrameMs) + _since(now, lastFrameAt);
  }
  return SenseLinkSample(
    rttMs: senseParseNumber(delay),
    lossPct: lossEst,
    fps: senseParseFps(fps),
    frameAge: frameAge,
    probeAge: probeAt == null ? null : _since(now, probeAt),
    bandwidthMbit: senseParseSpeedMbit(speed),
  );
}

Duration _since(DateTime now, DateTime at) {
  final d = now.difference(at);
  return d.isNegative ? Duration.zero : d;
}
