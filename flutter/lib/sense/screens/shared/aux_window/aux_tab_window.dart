// Sense Remote: binds the Sense frame (aux_window_frame.dart) to a stock tab window
// (DesktopTabController) — files now, terminal and tunnel next (TT). The stock
// DesktopTab stays underneath without its blue bar: it still owns the pages, keep-alive,
// window listeners and close handling; only the bar is drawn by Sense (ST 15).
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../../../common.dart' show isMacOS;
import '../../../../desktop/widgets/tabbar_widget.dart';
import '../../../../main.dart' show kWindowId;
import '../../../../models/state_model.dart';
import '../../../strings/files.dart';
import 'aux_label.dart';
import 'aux_menu.dart';
import 'aux_window_frame.dart';

class SenseAuxTabWindow extends StatelessWidget {
  const SenseAuxTabWindow({
    super.key,
    required this.controller,
    required this.title,
    required this.onWindowClose,
    this.liveFor,
    this.badgesFor,
    this.onNewTab,
    this.alwaysShowTabs = false,
  });

  final DesktopTabController controller;

  /// "Uzak dosyalar", "Terminal", "TCP tünel".
  final String title;

  /// The stock close logic of the window (confirm several tabs, audit note …);
  /// true = the window may close.
  final Future<bool> Function() onWindowClose;

  /// Live line of the selected tab; read inside Obx, so Rx values update it.
  final SenseAuxLive? Function(String key)? liveFor;
  final List<Widget> Function(String key)? badgesFor;
  final VoidCallback? onNewTab;
  final bool alwaysShowTabs;

  WindowController get _wc => WindowController.fromWindowId(kWindowId!);

  Future<void> _close() async {
    if (await onWindowClose()) {
      Future.delayed(Duration.zero, () => _wc.close());
    }
  }

  void _closeTab(TabInfo tab) {
    if (tab.onTabCloseButton != null) {
      tab.onTabCloseButton!();
    } else {
      controller.closeBy(tab.key);
    }
  }

  List<SenseAuxMenuItem> _tabMenu(int index) {
    final tabs = controller.state.value.tabs;
    if (index >= tabs.length) return const [];
    final tab = tabs[index];
    return [
      SenseAuxMenuItem(label: SenseAuxStrings.closeTab, onTap: tab.closable ? () => _closeTab(tab) : null),
      SenseAuxMenuItem(
        label: SenseAuxStrings.closeOtherTabs,
        onTap: tabs.length > 1
            ? () {
                for (final other in List<TabInfo>.of(tabs)) {
                  if (other.key != tab.key && other.closable) _closeTab(other);
                }
              }
            : null,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final st = controller.state.value;
      final tabs = st.tabs;
      final sel = tabs.isEmpty ? 0 : st.selected.clamp(0, tabs.length - 1);
      final key = tabs.isEmpty ? null : tabs[sel].key;
      final maximized = stateGlobal.isMaximized.value;
      return SenseAuxWindowFrame(
        title: title,
        subject: key == null ? null : senseAuxPeerLabel(key),
        live: key == null ? null : liveFor?.call(key),
        badges: key == null ? const [] : (badgesFor?.call(key) ?? const []),
        tabs: [
          for (final t in tabs) SenseAuxTab(key: t.key, label: senseAuxPeerLabel(t.key), closable: t.closable),
        ],
        selectedTab: sel,
        onSelectTab: (i) => controller.jumpTo(i),
        onCloseTab: (i) {
          if (i < tabs.length) _closeTab(tabs[i]);
        },
        onNewTab: onNewTab,
        tabMenu: _tabMenu,
        alwaysShowTabs: alwaysShowTabs,
        actions: SenseAuxWindowActions(
          leadingInset: isMacOS ? kSenseAuxMacInset : 0,
          onDragStart: () => startDragging(false),
          onToggleMaximize: isMacOS
              ? null
              : () => toggleMaximize(false).then((v) => stateGlobal.setMaximized(v)),
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
