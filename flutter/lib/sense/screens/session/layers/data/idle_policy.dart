// Sense Remote: the idle limit of the computer this window is connected to (YH O15).
// The value is the panel's "Hareketsiz bağlantıyı kes" permission of that computer.
import '../layer_spec.dart';

abstract final class SenseIdlePolicy {
  // TODO(D3a): read the computer's "Hareketsiz bağlantıyı kes" value from the panel
  // (grants / peers list, per peer id). Until it reaches the Controller the YH O14
  // default (30 dk) is used.
  static Duration? limitFor(String peerId) => SenseIdleTiming.defaultLimit;
}
