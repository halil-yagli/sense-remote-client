// Sense Remote (#101, YH H4): when every connection to this Host has ended, the
// card says "Bağlantı sona erdi" for a moment and the window closes by itself;
// nothing on the Host keeps looking "still connected". Pure rules only (tests).
//
// RustDesk marks a peer that went away as `disconnected` and keeps it in the
// list until someone closes its tab; its connection manager window stays open
// for that. In Sense icon mode there is no tab to close, so without this the
// empty card stayed on screen for good (Slayer, 2026-11-25).

import 'dart:async';

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

/// True when at least one connection is still live (not ended).
bool senseCmHasLive(Iterable<bool> disconnected) =>
    disconnected.any((d) => !d);

/// #107: the close countdown after every connection ended.
///
/// Slayer v9: the window did not close 5 s after the end. ServerModel's
/// periodic check (every 0.5 s while the list is not empty, ended connections
/// included) calls showCmWindow, and that cancelled the countdown each time;
/// only the card's "Kapat" closed the window, 24 s later. Now only a live
/// connection stops it: re-showing the window, opening or minimizing the card
/// and the edge tab neither cancel nor restart the countdown.
class SenseCmEndedCloser {
  SenseCmEndedCloser({this.linger = kSenseCmEndedLinger});

  final Duration linger;
  Timer? _timer;

  /// A countdown is running.
  bool get pending => _timer != null;

  /// Starts the countdown; [onClose] runs once after [linger]. A countdown
  /// already running is kept as it is (returns false).
  bool start(void Function() onClose) {
    if (_timer != null) return false;
    _timer = Timer(linger, () {
      _timer = null;
      onClose();
    });
    return true;
  }

  /// The connection list as seen now (true = ended). Only a live connection
  /// stops the countdown; returns whether it was stopped.
  bool onClients(Iterable<bool> disconnected) {
    if (_timer == null || !senseCmHasLive(disconnected)) return false;
    cancel();
    return true;
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
