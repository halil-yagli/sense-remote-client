// Sense Remote: the idle limit of the computer this window is connected to (YH O15).
// The value is the panel's "Hareketsiz bağlantıyı kes" permission of that computer,
// read from peer-status `idle_disconnect_min` (minutes; null or missing = off).
import '../../data/sense_peer_status.dart';
import '../layer_controller.dart';

abstract final class SenseIdlePolicy {
  /// Minutes from the panel to a limit; null, zero or negative = never cut.
  static Duration? limitFromMinutes(int? minutes) =>
      minutes == null || minutes <= 0 ? null : Duration(minutes: minutes);

  /// Reads peer-status once and gives the controller the limit. Until it answers (and
  /// when the panel has nothing) the computer is never cut for being idle.
  static Future<void> load(
    String peerId,
    SenseLayerController controller, {
    Future<SensePeerStatusResult> Function(String id)? fetch,
  }) async {
    final r = await (fetch ?? SensePeerStatusClient().fetch)(peerId);
    final status = r.status;
    if (status == null) return;
    controller.idleLimit = limitFromMinutes(status.idleDisconnectMin);
  }
}
