// Sense Remote (#101, YH H4): when every connection to this Host has ended, the
// card says "Bağlantı sona erdi" for a moment and the window closes by itself;
// nothing on the Host keeps looking "still connected". Pure rules only (tests).
//
// RustDesk marks a peer that went away as `disconnected` and keeps it in the
// list until someone closes its tab; its connection manager window stays open
// for that. In Sense icon mode there is no tab to close, so without this the
// empty card stayed on screen for good (Slayer, 2026-11-25).

/// How long the "Bağlantı sona erdi" card stays before the window closes.
const Duration kSenseCmEndedLinger = Duration(seconds: 5);

/// True when there are connections and every one of them has ended.
bool senseCmAllEnded(Iterable<bool> disconnected) =>
    disconnected.isNotEmpty && disconnected.every((d) => d);

/// Whole seconds left until the window closes (never below 0); the card shows
/// "N sn sonra kapanıyor". Rounded up, so it counts 5, 4, 3, 2, 1.
int senseCmEndedSecondsLeft(DateTime endedAt, DateTime now,
    [Duration linger = kSenseCmEndedLinger]) {
  final left = linger - now.difference(endedAt);
  if (left <= Duration.zero) return 0;
  return (left.inMilliseconds + 999) ~/ 1000;
}
