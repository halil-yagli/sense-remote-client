// Sense Remote: the connection layers of a RustDesk connection window. remote_page.dart
// places [SenseConnectionLayers] last in its stack (over the top bar and the popups)
// and calls [SenseConnectionLayers.remove] when the page closes.
import 'package:flutter/widgets.dart';

import '../../../../models/model.dart';
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
        SenseIdlePolicy.load(id, c);
        // Sürüm 11 (O5): the limit may have changed in the panel while the link was down.
        c.onReconnected = () => SenseIdlePolicy.load(id, c);
        return c;
      });

  static void remove(String id) => _byId.remove(id)?.dispose();

  @override
  Widget build(BuildContext context) =>
      SenseSessionLayers(id: id, controller: controllerFor(id, ffi));
}
