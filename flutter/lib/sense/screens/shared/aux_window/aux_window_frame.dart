// Sense Remote: the shared Sense frame of the secondary windows — remote files,
// terminal, TCP tunnel (ST 15, 16; plan S12 §2.5 "UD"). Prototype: `.fmt` title bar
// (44 px, logo, "Başlık · bilgisayar", live line, window buttons) and `.axtabs`
// tabs (30 px, surface / raised when selected). Colours only from the tokens.
//
// The frame is a plain widget: window actions (drag, minimise, maximise, close)
// come in as callbacks, so goldens and tests draw it without a window. The
// DesktopTabController adapter is aux_tab_window.dart.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/files.dart';
import 'aux_menu.dart';

/// Title bar height (`.fmt`).
const double kSenseAuxBarHeight = 44;

/// Tab row: tab height and the row's top gap (`.axtabs`, `.axtab`).
const double kSenseAuxTabHeight = 30;
const double _kTabsTopPad = 8;

/// Space macOS keeps for its own traffic-light buttons.
const double kSenseAuxMacInset = 78;

/// The live line of the title bar: dot + "Doğrudan · 18 ms · ekran açılmadı".
class SenseAuxLive {
  const SenseAuxLive(this.label, this.level);

  final String label;

  /// ok = green dot, warn = orange (no connection), unknown = grey (connecting).
  final SenseLevel level;
}

/// One tab of the frame.
class SenseAuxTab {
  const SenseAuxTab({required this.key, required this.label, this.closable = true});

  final String key;
  final String label;
  final bool closable;
}

/// What the window buttons do. Null = button not shown.
class SenseAuxWindowActions {
  const SenseAuxWindowActions({
    this.onDragStart,
    this.onToggleMaximize,
    this.onMinimize,
    this.onClose,
    this.maximized,
    this.leadingInset = 0,
  });

  final VoidCallback? onDragStart;
  final VoidCallback? onToggleMaximize;
  final VoidCallback? onMinimize;
  final VoidCallback? onClose;

  /// Drives the maximise / restore icon. Null = always "Büyüt".
  final ValueListenable<bool>? maximized;

  /// Left gap before the logo (macOS traffic lights: [kSenseAuxMacInset]).
  final double leadingInset;
}

class SenseAuxWindowFrame extends StatelessWidget {
  const SenseAuxWindowFrame({
    super.key,
    required this.title,
    required this.child,
    this.subject,
    this.live,
    this.badges = const [],
    this.tabs = const [],
    this.selectedTab = 0,
    this.onSelectTab,
    this.onCloseTab,
    this.onNewTab,
    this.tabMenu,
    this.alwaysShowTabs = false,
    this.actions = const SenseAuxWindowActions(),
  });

  /// "Uzak dosyalar", "Terminal", "TCP tünel".
  final String title;

  /// The computer's name, drawn muted after " · ". Never its ID (ST 16).
  final String? subject;
  final SenseAuxLive? live;

  /// Small chips after the live line ("Yönetici").
  final List<Widget> badges;

  final List<SenseAuxTab> tabs;
  final int selectedTab;
  final ValueChanged<int>? onSelectTab;
  final ValueChanged<int>? onCloseTab;

  /// "+" after the tabs; null = no button.
  final VoidCallback? onNewTab;

  /// Right-click menu of a tab.
  final List<SenseAuxMenuItem> Function(int index)? tabMenu;

  /// Show the tab row with a single tab (terminal); otherwise only with two or more.
  final bool alwaysShowTabs;

  final SenseAuxWindowActions actions;
  final Widget child;

  bool get _showTabs => tabs.length > 1 || (alwaysShowTabs && tabs.isNotEmpty) || onNewTab != null;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: SenseColors.bg,
      child: DefaultTextStyle(
        style: SenseTextStyles.body,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TitleBar(frame: this),
            if (_showTabs) _TabRow(frame: this),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.frame});

  final SenseAuxWindowFrame frame;

  @override
  Widget build(BuildContext context) {
    final a = frame.actions;
    final live = frame.live;
    final drag = GestureDetector(
      key: const Key('sense-aux-drag'),
      behavior: HitTestBehavior.opaque,
      onPanStart: a.onDragStart == null ? null : (_) => a.onDragStart!(),
      onDoubleTap: a.onToggleMaximize,
      child: Padding(
        padding: EdgeInsets.only(left: 14 + a.leadingInset),
        child: Row(children: [
          const SenseMark(width: 18, height: 18),
          const SizedBox(width: 10),
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: frame.title),
                if (frame.subject != null && frame.subject!.isNotEmpty)
                  TextSpan(
                    text: ' · ${frame.subject}',
                    style: SenseTextStyles.of(
                        size: SenseFontSize.categoryTitle,
                        weight: SenseFontWeight.medium,
                        color: SenseColors.textMuted),
                  ),
              ]),
              key: const Key('sense-aux-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.categoryTitle,
            ),
          ),
          if (live != null) ...[
            const SizedBox(width: 10),
            _LiveLine(live: live),
          ],
          for (final b in frame.badges) ...[const SizedBox(width: 8), b],
          const Spacer(),
        ]),
      ),
    );
    return Container(
      height: kSenseAuxBarHeight,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: SenseColors.line))),
      padding: const EdgeInsets.only(right: 8),
      child: Row(children: [
        Expanded(child: drag),
        if (a.onMinimize != null)
          _WindowButton(
            key: const Key('sense-aux-minimize'),
            icon: Icons.remove_rounded,
            tooltip: SenseAuxStrings.minimize,
            onTap: a.onMinimize!,
          ),
        if (a.onToggleMaximize != null)
          _MaximizeButton(actions: a),
        if (a.onClose != null)
          _WindowButton(
            key: const Key('sense-aux-close'),
            icon: Icons.close_rounded,
            tooltip: SenseAuxStrings.close,
            onTap: a.onClose!,
          ),
      ]),
    );
  }
}

class _LiveLine extends StatelessWidget {
  const _LiveLine({required this.live});

  final SenseAuxLive live;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: live.level.color, shape: BoxShape.circle),
      ),
      const SizedBox(width: SenseUi.iconGap),
      Text(
        live.label,
        key: const Key('sense-aux-live'),
        maxLines: 1,
        style: SenseTextStyles.hint,
      ),
    ]);
  }
}

class _MaximizeButton extends StatelessWidget {
  const _MaximizeButton({required this.actions});

  final SenseAuxWindowActions actions;

  @override
  Widget build(BuildContext context) {
    Widget button(bool max) => _WindowButton(
          key: const Key('sense-aux-maximize'),
          icon: max ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          iconSize: max ? 13 : 15,
          tooltip: max ? SenseAuxStrings.restore : SenseAuxStrings.maximize,
          onTap: actions.onToggleMaximize!,
        );
    final m = actions.maximized;
    if (m == null) return button(false);
    return ValueListenableBuilder<bool>(valueListenable: m, builder: (_, v, __) => button(v));
  }
}

/// 30 × 30, 8 px corners, muted; hover = hover surface + white (`.fmt .x`).
class _WindowButton extends StatelessWidget {
  const _WindowButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.iconSize = 17});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return SenseInteractive(
      onTap: onTap,
      tooltip: tooltip,
      semanticLabel: tooltip,
      builder: (context, s) => Container(
        width: 30,
        height: 30,
        margin: const EdgeInsets.only(left: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: s.hovered || s.pressed ? SenseColors.hover : null,
          borderRadius: BorderRadius.circular(SenseRadii.button),
        ),
        child: Icon(icon, size: iconSize, color: s.hovered ? SenseColors.text : SenseColors.textMuted),
      ),
    );
  }
}

class _TabRow extends StatelessWidget {
  const _TabRow({required this.frame});

  final SenseAuxWindowFrame frame;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: kSenseAuxTabHeight + _kTabsTopPad,
      padding: const EdgeInsets.only(left: 12, right: 12, top: _kTabsTopPad),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: SenseColors.line))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < frame.tabs.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                _Tab(frame: frame, index: i),
              ],
            ]),
          ),
        ),
        if (frame.onNewTab != null) ...[
          const SizedBox(width: 4),
          SenseInteractive(
            key: const Key('sense-aux-new-tab'),
            onTap: frame.onNewTab,
            tooltip: SenseAuxStrings.newTab,
            semanticLabel: SenseAuxStrings.newTab,
            builder: (context, s) => Container(
              width: kSenseAuxTabHeight,
              height: kSenseAuxTabHeight - 4,
              margin: const EdgeInsets.only(bottom: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: s.hovered ? SenseColors.hover : null,
                borderRadius: BorderRadius.circular(SenseRadii.button),
              ),
              child: Icon(Icons.add_rounded, size: 16, color: s.hovered ? SenseColors.text : SenseColors.textMuted),
            ),
          ),
        ],
      ]),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.frame, required this.index});

  final SenseAuxWindowFrame frame;
  final int index;

  @override
  Widget build(BuildContext context) {
    final tab = frame.tabs[index];
    final on = index == frame.selectedTab;
    final menu = frame.tabMenu;
    return GestureDetector(
      onSecondaryTapUp: menu == null ? null : (d) => senseAuxMenuShow(context, d.globalPosition, menu(index)),
      onTertiaryTapUp: tab.closable && frame.onCloseTab != null ? (_) => frame.onCloseTab!(index) : null,
      child: SenseInteractive(
        key: Key('sense-aux-tab-${tab.key}'),
        onTap: frame.onSelectTab == null ? null : () => frame.onSelectTab!(index),
        selected: on,
        semanticLabel: tab.label,
        mouseCursor: SystemMouseCursors.click,
        builder: (context, s) => Container(
          height: kSenseAuxTabHeight,
          padding: const EdgeInsets.only(left: 10, right: 8),
          decoration: BoxDecoration(
            color: on ? SenseColors.raised : (s.hovered ? SenseColors.hover : SenseColors.surface),
            border: const Border(
              top: BorderSide(color: SenseColors.line),
              left: BorderSide(color: SenseColors.line),
              right: BorderSide(color: SenseColors.line),
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(SenseRadii.button)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SenseTextStyles.of(
                    size: SenseFontSize.hintLarge, color: on ? SenseColors.text : SenseColors.textMuted),
              ),
            ),
            if (tab.closable && frame.onCloseTab != null) ...[
              const SizedBox(width: 8),
              SenseInteractive(
                key: Key('sense-aux-tab-close-${tab.key}'),
                onTap: () => frame.onCloseTab!(index),
                tooltip: SenseAuxStrings.closeTab,
                semanticLabel: SenseAuxStrings.closeTab,
                builder: (context, cs) => Icon(Icons.close_rounded,
                    size: SenseFontSize.categoryTitle, color: cs.hovered ? SenseColors.text : SenseColors.textDim),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
