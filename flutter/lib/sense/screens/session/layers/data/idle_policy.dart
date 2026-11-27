// Sense Remote: the idle limit of the computer this window is connected to (YH O15).
// The value is the panel's "Hareketsiz bağlantıyı kes" permission of that computer,
// read from peer-status `idle_disconnect_min` (minutes; null or missing = off).
import '../../data/sense_peer_status.dart';
import '../layer_controller.dart';

abstract final class SenseIdlePolicy {
  /// Minutes from the panel to a limit; null, zero or negative = never cut.
  static Duration? limitFromMinutes(int? minutes) =>
      minutes == null || minutes <= 0 ? null : Duration(minutes: minutes);

  /// Sürüm 11 (O5): a failed read is tried again this often, at most [retries] times (the
  /// Host cuts with its own limit; without it the strip would never warn).
  static const Duration retryEvery = Duration(seconds: 30);
  static const int retries = 5;

  /// Reads peer-status and gives the controller the limit. Until it answers (and when the
  /// panel has nothing) the computer is never cut for being idle. A read that fails is tried
  /// again ([retryEvery], [retries]); the controller's [SenseLayerController.onReconnected]
  /// reads it again after a reconnect.
  static Future<void> load(
    String peerId,
    SenseLayerController controller, {
    Future<SensePeerStatusResult> Function(String id)? fetch,
    Future<void> Function(Duration)? wait,
    bool Function()? alive,
  }) async {
    final get = fetch ?? SensePeerStatusClient().fetch;
    final pause = wait ?? (d) => Future<void>.delayed(d);
    for (var i = 0; i <= retries; i++) {
      if (i > 0) {
        await pause(retryEvery);
        if (alive != null && !alive()) return;
      }
      final r = await get(peerId);
      final status = r.status;
      if (status != null) {
        controller.idleLimit = limitFromMinutes(status.idleDisconnectMin);
        return;
      }
      // The panel cannot have anything for this computer: asking again does not help.
      if (r.noPanelInfo) return;
    }
  }
}
