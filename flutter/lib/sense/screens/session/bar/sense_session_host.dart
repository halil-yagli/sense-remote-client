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
import '../sense_remote_window.dart' show SenseRemoteSession;
import 'sense_session_bar.dart';
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
  final Map<String, _SessionPopups> _popups = {};
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
    for (final p in _popups.values) {
      p.dispose();
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
      _popups.remove(gone)?.dispose();
      SenseSessionEvents.remove(gone);
    }
    _applyTabStrip();
    if (mounted) setState(() {});
  }

  /// The selected tab's session, or null while its page is not built yet.
  ({SenseFfiSessionBackend backend, _SessionPopups popups})? _current() {
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
      final popups = _popups.putIfAbsent(tab.key, () => _SessionPopups(SenseRemoteSession.of(page.id)));
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

/// Bilgisayar durumu and Ekran bilgisi over the existing session state (C2 draws them).
/// One at a time (T7); opening one closes the chat panel.
class _SessionPopups extends ChangeNotifier implements SenseBarPopups {
  _SessionPopups(this.session) {
    session.addListener(notifyListeners);
  }

  final SenseRemoteSession session;

  @override
  void dispose() {
    session.removeListener(notifyListeners);
    super.dispose();
  }

  @override
  bool isOpen(SenseBarPopup p) => p == SenseBarPopup.status ? session.statusOpen : session.infoOpen;

  @override
  void toggle(SenseBarPopup p) {
    final opening = !isOpen(p);
    if (opening) {
      session.setChatOpen(false);
      final other = p == SenseBarPopup.status ? SenseBarPopup.info : SenseBarPopup.status;
      if (isOpen(other)) _flip(other);
    }
    _flip(p);
  }

  void _flip(SenseBarPopup p) => p == SenseBarPopup.status ? session.toggleStatus() : session.toggleInfo();

  @override
  void closeAll() {
    if (session.statusOpen) session.toggleStatus();
    if (session.infoOpen) session.toggleInfo();
    session.setChatOpen(false);
  }

  // TODO(C2): worst level of the status / display popups (peer status + health).
  @override
  SenseLevel? level(SenseBarPopup p) => null;
}
