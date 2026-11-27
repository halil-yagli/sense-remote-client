// Sense Remote: the one "still screen" rule (Sürüm 10, #118; denetim K44).
//
// RustDesk sends a frame only when the picture changed, so a low frame rate on a screen
// that is not changing is normal, not a problem. The frame-rate warning is meant for a
// changing screen whose frames do not get through. Every place that judges the frame rate
// (Ekran bilgisi, the "Bağlantı zayıf" layer, the link card's frame tile) asks this one
// function, so the same values always lead to the same verdict. Pure Dart.
import '../../../tokens/sense_tokens.dart';

/// Session latency colours (karar #135: 150 ms orange, 300 ms red everywhere). The one
/// source is the tokens' `latency` limit (YH T6); this name stays for the places that
/// read it (Ekran bilgisi, the still-screen rule).
const SenseThreshold kSenseSessionLatency = SenseThresholds.latency;

/// Under this much picture data (Mbit/s) the screen is hardly changing.
const double kSenseStillMaxMbit = 1.0;

/// Last frame older than this (ms): the picture did not change since.
const int kSenseStillFrameAgeMs = 1000;

/// A loss estimate at or above this (percent) is a real link problem, never "still".
const double kSenseStillMaxLossPct = 2.0;

/// The screen counts as still when the rate is under the warning line, the link itself is
/// fine (latency under the O9 orange line, loss estimate under [kSenseStillMaxLossPct]) and
/// either hardly any picture data comes (under [kSenseStillMaxMbit]) or the last frame is
/// older than [kSenseStillFrameAgeMs]. Without data evidence (no speed, no frame age) the
/// screen is not still: the low rate then stays a warning (karar #94 limits unchanged).
bool senseStillScreen({
  double? fps,
  double? rttMs,
  double? lossPct,
  double? mbit,
  int? frameAgeMs,
}) {
  if (fps == null || SenseThresholds.frameRate.levelOf(fps) == SenseLevel.ok) return false;
  if (rttMs != null && kSenseSessionLatency.levelOf(rttMs) != SenseLevel.ok) return false;
  if (lossPct != null && lossPct >= kSenseStillMaxLossPct) return false;
  return (mbit != null && mbit < kSenseStillMaxMbit) ||
      (frameAgeMs != null && frameAgeMs >= kSenseStillFrameAgeMs);
}

/// "123.45kB/s" (RustDesk: kB = 1024 bytes) → megabit per second.
double? senseParseSpeedMbit(String? speed) {
  if (speed == null) return null;
  final m = RegExp(r'^\s*([0-9]+(?:\.[0-9]+)?)\s*([kKmM]?)B/s\s*$').firstMatch(speed);
  if (m == null) return null;
  final v = double.tryParse(m.group(1)!);
  if (v == null) return null;
  final unit = m.group(2)!.toLowerCase();
  final bytes = unit == 'k' ? v * 1024 : (unit == 'm' ? v * 1024 * 1024 : v);
  return bytes * 8 / 1e6;
}
