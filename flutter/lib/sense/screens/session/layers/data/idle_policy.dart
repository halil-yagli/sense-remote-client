// Sense Remote: the idle limit of the computer this window is connected to (YH O15).
// The value is the panel's "Hareketsiz bağlantıyı kes" permission of that computer,
// read from peer-status `idle_disconnect_min` (minutes; null or missing = off).
// Sürüm 12 (U167): when the panel cannot be read, the Host's own value is used — the Host
// sends it after login (`sense.idle`, read with `session_sense_idle_policy`).
import 'dart:convert';

import '../../data/sense_peer_status.dart';
import '../layer_controller.dart';

/// The Host's idle value: [known] false while the Host sent none (an older Host).
typedef SenseHostIdle = ({bool known, int? min});

abstract final class SenseIdlePolicy {
  /// Minutes from the panel to a limit; null, zero or negative = never cut.
  static Duration? limitFromMinutes(int? minutes) =>
      minutes == null || minutes <= 0 ? null : Duration(minutes: minutes);

  /// Sürüm 11 (O5): a failed read is tried again this often, at most [retries] times (the
  /// Host cuts with its own limit; without it the strip would never warn).
  static const Duration retryEvery = Duration(seconds: 30);
  static const int retries = 5;

  static const SenseHostIdle unknownHost = (known: false, min: null);

  /// Sürüm 12 (U167): `session_sense_idle_policy` → `{"min": n | null}`; anything else
  /// (`{"error":"unsupported"}`, empty, broken) = not known.
  static SenseHostIdle parseHost(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map || !v.containsKey('min')) return unknownHost;
      final m = v['min'];
      if (m == null) return (known: true, min: null);
      if (m is num) return (known: true, min: m.toInt());
      return unknownHost;
    } catch (_) {
      return unknownHost;
    }
  }

  /// Reads peer-status and gives the controller the limit. Until it answers (and when the
  /// panel has nothing) the computer is never cut for being idle. A read that fails is tried
  /// again ([retryEvery], [retries]); meanwhile, and when the panel cannot have anything, the
  /// Host's own value ([hostIdle]) is used when it is known. The controller's
  /// [SenseLayerController.onReconnected] reads it again after a reconnect.
  static Future<void> load(
    String peerId,
    SenseLayerController controller, {
    Future<SensePeerStatusResult> Function(String id)? fetch,
    Future<void> Function(Duration)? wait,
    bool Function()? alive,
    SenseHostIdle Function()? hostIdle,
  }) async {
    final get = fetch ?? SensePeerStatusClient().fetch;
    final pause = wait ?? (d) => Future<void>.delayed(d);
    var panelGone = false;
    for (var i = 0; i <= retries; i++) {
      if (i > 0) {
        await pause(retryEvery);
        if (alive != null && !alive()) return;
      }
      if (!panelGone) {
        final r = await get(peerId);
        final status = r.status;
        if (status != null) {
          controller.idleLimit = limitFromMinutes(status.idleDisconnectMin);
          return;
        }
        // The panel cannot have anything for this computer: asking again does not help.
        panelGone = r.noPanelInfo;
      }
      final host = hostIdle?.call() ?? unknownHost;
      if (host.known) {
        controller.idleLimit = limitFromMinutes(host.min);
        if (panelGone) return;
      } else if (panelGone && hostIdle == null) {
        return;
      }
    }
  }
}
