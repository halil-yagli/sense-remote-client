// Sense Remote: puts the Sense session frame around the remote tabs of a connection window
// (`remote_tab_page.dart` → `pageViewBuilder`). It follows the selected tab, keeps one
// session backend per tab, and applies decision 3 (TK9): with one session the RustDesk tab
// strip is hidden; with several it stays as the thin 28 px strip above the bar.
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../desktop/pages/remote_page.dart';
import '../../../../models/state_model.dart' show stateGlobal;
import '../../../../desktop/widgets/tabbar_widget.dart'
    show DesktopTabController, startDragging, toggleMaximize;
import '../../../tokens/sense_tokens.dart';
import '../data/session_state.dart';
import '../lists/ffi_backend.dart';
import 'session_popups.dart';
import 'sense_session_frame.dart';

/// Decision 3: the tab strip shows only with more than one session, never in full screen.
bool senseShowTabStrip({required int tabs, required bool fullscreen}) => tabs > 1 && !fullscreen;

class SenseSessionTabFrame extends StatefulWidget {
  const SenseSessionTabFrame({super.key, required this.controller, required this.child});

  final DesktopTabController controller;

  /// RustDesk's page view of the tabs.
  final Widget child;

  @override
  State<SenseSessionTabFrame> createState() => _SenseSessionTabFrameState();
}

class _SenseSessionTabFrameState extends State<SenseSessionTabFrame> {
  final Map<String, SenseFfiSessionBackend> _backends = {};
  final List<Worker> _workers = [];
  bool _retryScheduled = false;

  @override
  void initState() {
    super.initState();
    _workers.add(ever(widget.controller.state, (_) => _onTabs()));
    _workers.add(ever(stateGlobal.showTabBar, (_) => _applyTabStrip()));
    _workers.add(ever(stateGlobal.fullscreen, (_) => _applyTabStrip()));
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyTabStrip());
  }

  @override
  void dispose() {
    for (final w in _workers) {
      w.dispose();
    }
    for (final b in _backends.values) {
      b.dispose();
    }
    super.dispose();
  }

  void _applyTabStrip() {
    final want = senseShowTabStrip(
      tabs: widget.controller.state.value.tabs.length,
      fullscreen: stateGlobal.fullscreen.isTrue,
    );
    if (stateGlobal.showTabBar.value != want) stateGlobal.showTabBar.value = want;
  }

  void _onTabs() {
    final keys = {for (final t in widget.controller.state.value.tabs) t.key};
    for (final gone in _backends.keys.where((k) => !keys.contains(k)).toList()) {
      _backends.remove(gone)?.dispose();
      SenseSessionPopups.remove(gone);
      SenseSessionEvents.remove(gone);
    }
    _applyTabStrip();
    if (mounted) setState(() {});
  }

  /// The selected tab's session, or null while its page is not built yet.
  ({SenseFfiSessionBackend backend, SenseSessionPopups popups})? _current() {
    final state = widget.controller.state.value;
    if (state.tabs.isEmpty) return null;
    final index = state.selected.clamp(0, state.tabs.length - 1);
    final tab = state.tabs[index];
    final page = tab.page;
    if (page is! RemotePage) return null;
    try {
      final ffi = page.ffi;
      final backend = _backends.putIfAbsent(
        tab.key,
        () => SenseFfiSessionBackend(ffi: ffi, toolbarState: page.toolbarState, contextOf: () => context),
      );
      final popups = SenseSessionPopups.of(tab.key, ffi);
      return (backend: backend, popups: popups);
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

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // Rebuild on tab changes and selection.
      widget.controller.state.value.selected;
      final cur = _current();
      if (cur == null) {
        return Column(children: [
          const SizedBox(height: SenseSizes.sessionToolbarHeight, child: ColoredBox(color: SenseColors.bg)),
          Expanded(child: widget.child),
        ]);
      }
      return SenseSessionFrame(
        key: ValueKey('sense-frame-${cur.backend.peerId}'),
        backend: cur.backend,
        popups: cur.popups,
        onDragStart: () => startDragging(false),
        onDoubleTap: () => toggleMaximize(false).then((v) => stateGlobal.setMaximized(v)),
        child: widget.child,
      );
    });
  }
}
