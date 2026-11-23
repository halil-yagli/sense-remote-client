// Sense Remote: the Host window (YH H1, #36; prototype `.awin`, `.arail`, image a09).
// Same window and scale as the Controller: left menu (212 px; "Bu bilgisayar ·
// Host", Bu bilgisayar, Hakkında; at the bottom "Panelden yönetilir" + Sürüm)
// and the page. There is no way from here to the settings tab page (TK9 Risk
// H1): Hakkında and the version open the Sense About inside this window.
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/host.dart';
import '../../controller/sense_update_view.dart' show SenseUpdateWatch;
import '../../controller/sense_home_strings.dart' show SenseHomeRole;
import '../this_computer/this_computer_page.dart';
import '../../../../desktop/pages/desktop_tab_page.dart' show DesktopTabPage;
import 'host_about.dart';

enum SenseHostNav { thisComputer, about }

// Prototype `.arail` padding 14/10/12, gap 2; `.anv` 9×10, corner 9; `.arole b`
// 2×7, corner 6; `.ame` 10/8/2; `.amain` 18/22/24.
const double _kRailTop = 14, _kRailSide = 10, _kRailBottom = 12, _kNavGap = 2;
const double _kNavPadV = 9, _kNavPadH = 10, _kChipPadV = 2, _kChipPadH = 7, _kChipRadius = 6;
const double _kMeTop = 10, _kMeSide = 8, _kMeBottom = 2;
const double _kMainTop = 18, _kMainSide = 22, _kMainBottom = 24, _kDot = 7;

/// Binds the shell: navigation, update strip and the role-change splash.
class SenseHostShell extends StatefulWidget {
  const SenseHostShell({super.key, this.page, this.about});

  /// Test hooks; the app uses the real page and About.
  final Widget? page;
  final Widget? about;

  @override
  State<SenseHostShell> createState() => _SenseHostShellState();
}

class _SenseHostShellState extends State<SenseHostShell> {
  SenseHostNav _nav = SenseHostNav.thisComputer;
  bool _splash = false;

  @override
  Widget build(BuildContext context) => SenseUpdateWatch(
        builder: (context, strip) => SenseHostShellView(
          nav: _nav,
          version: senseAppVersion(),
          onNav: (n) => setState(() => _nav = n),
          splash: _splash,
          strip: strip,
          child: _nav == SenseHostNav.about
              ? (widget.about ?? const SenseHostAbout())
              : (widget.page ??
                  SenseThisComputerPage(
                    role: SenseHomeRole.host,
                    onRoleRestart: () => setState(() => _splash = true),
                  )),
        ),
      );
}

/// Pure view of the window (goldens and tests).
class SenseHostShellView extends StatelessWidget {
  const SenseHostShellView({
    super.key,
    required this.nav,
    required this.onNav,
    required this.child,
    this.version,
    this.navLevel,
    this.strip,
    this.splash = false,
  });

  final SenseHostNav nav;
  final ValueChanged<SenseHostNav> onNav;
  final Widget child;

  /// Null = the build has no number: no chip (nothing made up).
  final int? version;

  /// Dot next to "Bu bilgisayar" when the state is not fine.
  final SenseLevel? navLevel;

  /// Update strip above the page (update plan §6).
  final Widget? strip;

  /// Role change: the app reopens with the new role (T8).
  final bool splash;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.maybeSizeOf(context)?.width ?? SenseSizes.windowWidth;
    final page = ScrollConfiguration(
      behavior: const SenseScrollBehavior(),
      child: SingleChildScrollView(
        key: const Key('sense-host-main'),
        padding: const EdgeInsets.fromLTRB(_kMainSide, _kMainTop, _kMainSide, _kMainBottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (strip != null) ...[strip!, const SizedBox(height: _kMainTop / 2 + 1)],
            child,
          ],
        ),
      ),
    );
    return SenseToastHost(
      child: Stack(children: [
        Positioned.fill(
          child: ColoredBox(
            color: SenseColors.bg,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: SenseLayout.sideMenu(width), child: _rail()),
              const SizedBox(width: 1, child: ColoredBox(color: SenseColors.line)),
              Expanded(child: page),
            ]),
          ),
        ),
        if (splash) const Positioned.fill(child: SenseSplash(key: Key('sense-host-splash'))),
      ]),
    );
  }

  Widget _rail() => Padding(
        padding: const EdgeInsets.fromLTRB(_kRailSide, _kRailTop, _kRailSide, _kRailBottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(SenseUi.iconGap, 0, SenseUi.iconGap, _kRailBottom),
              child: Row(children: [
                Expanded(
                  child: Text(SenseHostStrings.thisComputer,
                      style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
                ),
                Container(
                  key: const Key('sense-host-role-chip'),
                  padding: const EdgeInsets.symmetric(vertical: _kChipPadV, horizontal: _kChipPadH),
                  decoration: BoxDecoration(
                    color: SenseColors.raised,
                    border: Border.all(color: SenseColors.line),
                    borderRadius: BorderRadius.circular(_kChipRadius),
                  ),
                  child: Text(SenseHostStrings.roleHost,
                      style: SenseTextStyles.of(size: SenseFontSize.caps, weight: SenseFontWeight.bold)),
                ),
              ]),
            ),
            _NavItem(
              key: const Key('sense-host-nav-this'),
              label: SenseHostStrings.thisComputer,
              selected: nav == SenseHostNav.thisComputer,
              level: navLevel,
              onTap: () => onNav(SenseHostNav.thisComputer),
            ),
            const SizedBox(height: _kNavGap),
            _NavItem(
              key: const Key('sense-host-nav-about'),
              label: SenseHostStrings.about,
              selected: nav == SenseHostNav.about,
              onTap: () => onNav(SenseHostNav.about),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.fromLTRB(_kMeSide, _kMeTop, _kMeSide, _kMeBottom),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: SenseColors.line))),
              child: Row(children: [
                Expanded(
                  child: Text(SenseHostStrings.managedByPanel,
                      style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
                ),
                if (version != null)
                  SenseInteractive(
                    key: const Key('sense-host-version'),
                    onTap: () => onNav(SenseHostNav.about),
                    builder: (_, s) => SenseFocusRing(
                      visible: s.focused,
                      radius: _kChipRadius,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: _kChipPadV, horizontal: SenseUi.iconGap),
                        decoration: BoxDecoration(
                          color: s.hovered ? SenseColors.hover : null,
                          border: Border.all(color: SenseColors.line),
                          borderRadius: BorderRadius.circular(_kChipRadius),
                        ),
                        child: Text(SenseHostStrings.version(version!),
                            style: SenseTextStyles.of(
                                size: SenseFontSize.capsSmall,
                                color: s.hovered ? SenseColors.text : SenseColors.textMuted)),
                      ),
                    ),
                  ),
              ]),
            ),
          ],
        ),
      );
}

/// Left menu item (`.anv`).
class _NavItem extends StatelessWidget {
  const _NavItem({super.key, required this.label, required this.selected, required this.onTap, this.level});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final SenseLevel? level;

  @override
  Widget build(BuildContext context) => SenseInteractive(
        onTap: onTap,
        selected: selected,
        semanticLabel: label,
        builder: (_, s) => SenseFocusRing(
          visible: s.focused,
          radius: SenseRadii.category,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: _kNavPadV, horizontal: _kNavPadH),
            decoration: BoxDecoration(
              color: selected ? SenseColors.surface : (s.hovered ? SenseColors.hover : null),
              border: Border.all(color: selected ? SenseColors.line : SenseColors.bg.withOpacity(0)),
              borderRadius: BorderRadius.circular(SenseRadii.category),
            ),
            child: Row(children: [
              Expanded(
                child: Text(label,
                    style: SenseTextStyles.of(
                        weight: selected ? SenseFontWeight.bold : SenseFontWeight.regular,
                        color: selected || s.hovered ? SenseColors.text : SenseColors.textSecondary)),
              ),
              if (level != null && level != SenseLevel.ok && level != SenseLevel.unknown)
                SenseStatusDot(color: level!.color, size: _kDot, glow: level == SenseLevel.hot),
            ]),
          ),
        ),
      );
}

/// Router entry (A2c `SenseEntry.hostHome`, H1). The Host window lives in the
/// stock window frame (title bar, window buttons, remote-input block, service
/// status) whose home tab shows [SenseHostShell]; returning the shell alone
/// would drop the window buttons.
Widget senseHostScreen() => const DesktopTabPage();
