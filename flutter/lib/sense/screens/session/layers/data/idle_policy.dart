// Sense Remote: the idle limit of the computer this window is connected to (YH O15).
// The value is the panel's "Hareketsiz bağlantıyı kes" permission of that computer.
import '../layer_spec.dart';

abstract final class SenseIdlePolicy {
  // TODO(panel): the computer's "Hareketsiz bağlantıyı kes" value (device policy
  // `auto_disconnect_minutes`) does not reach the Controller yet: the grants envelope
  // is per person (no device policy in it), and neither `/api/peers` nor
  // `/api/sense/peer-status` sends it; RustDesk's own connection does not carry the
  // Host's timeout either. Needs a panel field (e.g. peers `sense.idle_minutes`).
  // Until then the YH O14 default (30 dk) is used; the Host still enforces its own.
  static Duration? limitFor(String peerId) => SenseIdleTiming.defaultLimit;
}
