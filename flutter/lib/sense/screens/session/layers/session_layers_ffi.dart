// Sense Remote: the connection layers of a RustDesk connection window. remote_page.dart
// places [SenseConnectionLayers] last in its stack (over the top bar and the popups)
// and calls [SenseConnectionLayers.remove] when the page closes.
import 'package:flutter/widgets.dart';

import '../../../../models/model.dart';
import '../../../../models/platform_model.dart';
import '../popups/note/note_state.dart' show SenseSessionNotes;
import 'data/idle_policy.dart';
import 'data/session_bridge.dart';
import 'layer_controller.dart';
import 'session_layers.dart';

class SenseConnectionLayers extends StatelessWidget {
  const SenseConnectionLayers({super.key, required this.id, required this.ffi});

  final String id;
  final FFI ffi;

  static final Map<String, SenseLayerController> _byId = {};

  /// One controller per connection tab; it lives as long as the page (a rebuild or a
  /// reconnect keeps the timers and the ended card).
  static SenseLayerController controllerFor(String id, FFI ffi) => _byId.putIfAbsent(id, () {
        final c = SenseLayerController(host: SenseFfiLayerHost(id, ffi));
        // Sürüm 12 (U167): the Host's own idle value when the panel cannot be read.
        SenseHostIdle hostIdle() =>
            SenseIdlePolicy.parseHost(bind.sessionSenseIdlePolicy(sessionId: ffi.sessionId));
        SenseIdlePolicy.load(id, c, hostIdle: hostIdle);
        // Sürüm 11 (O5): the limit may have changed in the panel while the link was down.
        c.onReconnected = () => SenseIdlePolicy.load(id, c, hostIdle: hostIdle);
        // Sürüm 12 (FO-A4): the session note goes out the stock way (`session_send_note`).
        SenseSessionNotes.setSender(id, (note) => bind.sessionSendNote(sessionId: ffi.sessionId, note: note));
        return c;
      });

  static void remove(String id) {
    _byId.remove(id)?.dispose();
    SenseSessionNotes.forget(id);
  }

  @override
  Widget build(BuildContext context) =>
      SenseSessionLayers(id: id, controller: controllerFor(id, ffi));
}
