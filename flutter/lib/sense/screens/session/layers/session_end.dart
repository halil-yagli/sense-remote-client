// Sense Remote: why a connection ended and what it left behind (YH O14, #54). Pure Dart.
import 'layer_strings.dart';

enum SenseEndReason {
  /// The person at the Host pressed "Bağlantıyı bitir".
  hostEnded,

  /// No input for the panel's idle time (O15 count reached zero, or the Host cut it).
  idle,

  /// The Host shut down or left the network (link stalled 30 s, or a connection error).
  peerGone,

  /// Sürüm 11 (O7): someone else is connected to the computer (S8 `sense_busy`).
  busy,

  /// Sürüm 12 (FO-A11): this side pressed "Bağlantıyı bitir" (`SenseLayerController.endByUser`).
  self,
}

/// What a session-ending message from RustDesk means for Sense.
enum SenseMessageKind { hostEnded, idle, peerGone, busy, endedHere }

/// Reads a RustDesk message box (`msgbox` event: type, title, text) that arrives
/// while the session is up. Null = not an ending Sense shows its own card for.
/// Texts: `connection.rs` `send_close_reason_no_retry` / `set_close_reason`,
/// `io_loop.rs` timeouts, D1 `sense_busy` login error.
SenseMessageKind? senseClassifyMessage(String type, String title, String text) {
  final t = text.toLowerCase();
  // Sürüm 11 (O2): the user ended this connection in another of its windows.
  if (t.contains('sense_ended_here')) return SenseMessageKind.endedHere;
  if (t.contains('sense_busy')) return SenseMessageKind.busy;
  if (t.contains('closed manually by the peer')) return SenseMessageKind.hostEnded;
  if (t.contains('inactivity')) return SenseMessageKind.idle;
  if (title == 'Connection Error' || type == 'error') {
    const gone = [
      'reset by the peer',
      'connection reset',
      'timeout',
      'timed out',
      'remote desktop is offline',
      'connection aborted',
      'broken pipe',
    ];
    if (gone.any(t.contains)) return SenseMessageKind.peerGone;
  }
  return null;
}

SenseEndReason? senseEndReasonOf(SenseMessageKind kind) {
  switch (kind) {
    case SenseMessageKind.hostEnded:
      return SenseEndReason.hostEnded;
    case SenseMessageKind.idle:
      return SenseEndReason.idle;
    case SenseMessageKind.peerGone:
      return SenseEndReason.peerGone;
    case SenseMessageKind.busy:
      return SenseEndReason.busy;
    case SenseMessageKind.endedHere:
      return null;
  }
}

/// The ended card's facts.
class SenseSessionSummary {
  const SenseSessionSummary({
    required this.reason,
    required this.duration,
    required this.messages,
    required this.files,
    required this.idleLimit,
  });

  final SenseEndReason reason;
  final Duration duration;
  final int messages;
  final int files;

  /// For the idle reason text ("30 dk hareketsiz…").
  final Duration idleLimit;

  String get reasonText {
    switch (reason) {
      case SenseEndReason.hostEnded:
        return SenseLayerStrings.reasonHost;
      case SenseEndReason.idle:
        return SenseLayerStrings.reasonIdle(idleLimit.inMinutes);
      case SenseEndReason.peerGone:
        return SenseLayerStrings.reasonGone;
      case SenseEndReason.busy:
        return SenseLayerStrings.reasonBusy;
      case SenseEndReason.self:
        return SenseLayerStrings.reasonSelf;
    }
  }
}
