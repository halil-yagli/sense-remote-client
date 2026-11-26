// Sense Remote: puts the Sense camera bar above the camera tabs of a camera window
// (`view_camera_tab_page.dart` → `pageViewBuilder`; YH O6 "Kamerayı görüntüle"). RustDesk's
// floating toolbar is not drawn in Sense windows (kSenseRemoteWindow), so this bar is the
// camera window's only control: camera choice and Bitir. The RustDesk tab strip stays (window
// buttons); the canvas is told the bar's height so the camera image fits under it.
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common.dart' show closeConnection, openMonitorInTheSameTab;
import '../../../common/shared_state.dart' show ConnectionType, ConnectionTypeState;
import '../../../desktop/pages/view_camera_page.dart' show ViewCameraPage;
import '../../../desktop/widgets/tabbar_widget.dart' show DesktopTabController, startDragging, toggleMaximize;
import '../../../models/model.dart' show FFI;
import '../../../models/platform_model.dart' show bind;
import '../../../models/state_model.dart' show stateGlobal;
import '../../tokens/sense_tokens.dart';
import 'sense_camera_bar.dart';

class SenseCameraTabFrame extends StatefulWidget {
  const SenseCameraTabFrame({super.key, required this.controller, required this.child});

  final DesktopTabController controller;

  /// RustDesk's page view of the camera tabs.
  final Widget child;

  @override
  State<SenseCameraTabFrame> createState() => _SenseCameraTabFrameState();
}

class _SenseCameraTabFrameState extends State<SenseCameraTabFrame> {
  FFI? _ffi;
  bool _retryScheduled = false;

  @override
  void initState() {
    super.initState();
    // The canvas starts under the tab strip and this bar (state_model `tabBarHeight`).
    stateGlobal.senseBarHeight.value = SenseSizes.sessionToolbarHeight;
  }

  @override
  void dispose() {
    _ffi?.ffiModel.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The selected tab's session, or null while its page is not built yet.
  FFI? _current() {
    final state = widget.controller.state.value;
    if (state.tabs.isEmpty) return null;
    final page = state.tabs[state.selected.clamp(0, state.tabs.length - 1)].page;
    if (page is! ViewCameraPage) return null;
    try {
      final ffi = page.ffi;
      if (!identical(ffi, _ffi)) {
        _ffi?.ffiModel.removeListener(_changed);
        ffi.ffiModel.addListener(_changed);
        _ffi = ffi;
      }
      return ffi;
    } catch (_) {
      // The page state is created in this frame; look again after it.
      if (!_retryScheduled) {
        _retryScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _retryScheduled = false;
          if (mounted) setState(() {});
        });
      }
      return null;
    }
  }

  static T _try<T>(T Function() f, T fallback) {
    try {
      return f();
    } catch (_) {
      return fallback;
    }
  }

  SenseCameraBarState _state(FFI? ffi) {
    if (ffi == null) return const SenseCameraBarState(name: '');
    final pi = ffi.ffiModel.pi;
    final alias = _try(() => bind.mainGetPeerOptionSync(id: ffi.id, key: 'alias'), '');
    final name = alias.isNotEmpty ? alias : (pi.hostname.isNotEmpty ? pi.hostname : ffi.id);
    final ct = _try<ConnectionTypeState?>(() => ConnectionTypeState.find(ffi.id), null);
    final bool? relay = ct == null || !ct.isValid() ? null : ct.direct.value != ConnectionType.strDirect;
    return SenseCameraBarState(
      name: name,
      ready: pi.isSet.isTrue,
      cameras: pi.displays.length,
      current: pi.currentDisplay < 0 ? 0 : pi.currentDisplay,
      relay: relay,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Rebuild on tab changes and selection.
      widget.controller.state.value.selected;
      final ffi = _current();
      final state = _state(ffi);
      return Column(children: [
        SenseCameraBar(
          state: state,
          onPick: ffi == null
              ? null
              : (i) {
                  final pi = ffi.ffiModel.pi;
                  if (pi.currentDisplay != i) openMonitorInTheSameTab(i, ffi, pi);
                },
          onEnd: () => closeConnection(id: ffi?.id),
          onDragStart: () => startDragging(false),
          onDoubleTap: () => toggleMaximize(false).then((v) => stateGlobal.setMaximized(v)),
        ),
        Expanded(child: widget.child),
      ]);
    });
  }
}
