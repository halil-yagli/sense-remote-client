// Sense Remote (Sürüm 12, ST 4, 15, 16): the Sense frame of the terminal window on its stock
// DesktopTabController. Like aux_tab_window.dart (files, tunnel) but the tabs are
// "Terminal 1", "Terminal 2" (one computer per window; its name is in the title) and the
// tab menu keeps the stock items: Yeni sekme, Bağlantı kesilince oturumları koru.
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../../common.dart' show isMacOS;
import '../../../desktop/widgets/tabbar_widget.dart';
import '../../../main.dart' show kWindowId;
import '../../../models/state_model.dart';
import '../../strings/files.dart';
import '../../strings/terminal.dart';
import '../shared/aux_window/aux_label.dart';
import '../shared/aux_window/aux_menu.dart';
import '../shared/aux_window/aux_window_frame.dart';
import 'terminal_keys.dart';

export 'terminal_keys.dart';


class SenseTerminalTabWindow extends StatelessWidget {
  const SenseTerminalTabWindow({
    super.key,
    required this.controller,
    required this.onWindowClose,
    required this.onCloseTab,
    required this.onNewTab,
    this.liveFor,
    this.badgesFor,
    this.keepSessions,
    this.onToggleKeepSessions,
    this.refresh,
  });

  final DesktopTabController controller;
  final Future<bool> Function() onWindowClose;

  /// The page's own close (audit note, session cleanup).
  final void Function(String key) onCloseTab;

  /// New terminal for the computer of [key].
  final void Function(String key) onNewTab;
  final SenseAuxLive? Function(String key)? liveFor;
  final List<Widget> Function(String key)? badgesFor;

  /// Stock "Keep terminal sessions on disconnect" of the computer of [key]; null = hidden.
  final bool Function(String key)? keepSessions;
  final void Function(String key)? onToggleKeepSessions;

  /// Rebuilds the bar when something outside the tab state changes (admin chip).
  final Listenable? refresh;

  WindowController get _wc => WindowController.fromWindowId(kWindowId!);

  Future<void> _close() async {
    if (await onWindowClose()) {
      Future.delayed(Duration.zero, () => _wc.close());
    }
  }

  List<SenseAuxMenuItem> _tabMenu(int index) {
    final tabs = controller.state.value.tabs;
    if (index >= tabs.length) return const [];
    final tab = tabs[index];
    final keep = keepSessions?.call(tab.key);
    return [
      SenseAuxMenuItem(label: SenseTerminalStrings.newTab, onTap: () => onNewTab(tab.key)),
      SenseAuxMenuItem(label: SenseAuxStrings.closeTab, onTap: tab.closable ? () => onCloseTab(tab.key) : null),
      SenseAuxMenuItem(
        label: SenseAuxStrings.closeOtherTabs,
        onTap: tabs.length > 1
            ? () {
                for (final other in List<TabInfo>.of(tabs)) {
                  if (other.key != tab.key && other.closable) onCloseTab(other.key);
                }
              }
            : null,
      ),
      if (keep != null && onToggleKeepSessions != null)
        SenseAuxMenuItem(
          key: const Key('sense-term-keep'),
          label: keep ? SenseTerminalStrings.keepSessionsOff : SenseTerminalStrings.keepSessionsOn,
          onTap: () => onToggleKeepSessions!(tab.key),
        ),
    ];
  }

  static String _label(String key) {
    final p = senseTerminalTabKey(key);
    return p == null ? SenseTerminalStrings.title : SenseTerminalStrings.tabLabel(p.$2);
  }

  @override
  Widget build(BuildContext context) {
    final r = refresh;
    if (r == null) return _frame();
    return ListenableBuilder(listenable: r, builder: (context, _) => _frame());
  }

  Widget _frame() {
    return Obx(() {
      final st = controller.state.value;
      final tabs = st.tabs;
      final sel = tabs.isEmpty ? 0 : st.selected.clamp(0, tabs.length - 1);
      final key = tabs.isEmpty ? null : tabs[sel].key;
      final peer = key == null ? null : (senseTerminalTabKey(key)?.$1 ?? key);
      final maximized = stateGlobal.isMaximized.value;
      return SenseAuxWindowFrame(
        title: SenseTerminalStrings.title,
        subject: peer == null ? null : senseAuxPeerLabel(peer),
        live: key == null ? null : liveFor?.call(key),
        badges: key == null ? const [] : (badgesFor?.call(key) ?? const []),
        tabs: [for (final t in tabs) SenseAuxTab(key: t.key, label: _label(t.key), closable: t.closable)],
        selectedTab: sel,
        onSelectTab: (i) => controller.jumpTo(i),
        onCloseTab: (i) {
          if (i < tabs.length) onCloseTab(tabs[i].key);
        },
        onNewTab: key == null ? null : () => onNewTab(key),
        tabMenu: _tabMenu,
        alwaysShowTabs: true,
        actions: SenseAuxWindowActions(
          leadingInset: isMacOS ? kSenseAuxMacInset : 0,
          onDragStart: () => startDragging(false),
          onToggleMaximize: isMacOS ? null : () => toggleMaximize(false).then((v) => stateGlobal.setMaximized(v)),
          onMinimize: isMacOS ? null : () => _wc.minimize(),
          onClose: isMacOS ? null : _close,
          maximized: ValueNotifier(maximized),
        ),
        child: DesktopTab(
          controller: controller,
          showTabBar: false,
          onWindowCloseButton: onWindowClose,
          labelGetter: DesktopTab.tablabelGetter,
        ),
      );
    });
  }
}
