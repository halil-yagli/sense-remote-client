// Sense Remote: one place for the short time format of the Host side (Sürüm 11, TS-10):
// "14 dk", "1 sa", "1 sa 5 dk" (no zero padding). The Host home screen and the Host card
// used two spellings of the same time ("1 sa 5 dk" / "1 sa 05 dk").

/// Minutes from [minutes] (at least "1 dk" for a connection that just opened).
String senseShortDuration(int minutes) {
  final total = minutes < 1 ? 1 : minutes;
  if (total < 60) return '$total dk';
  final h = total ~/ 60, r = total % 60;
  return r == 0 ? '$h sa' : '$h sa $r dk';
}
