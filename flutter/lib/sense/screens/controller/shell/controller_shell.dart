// Sense Remote: the Controller window (YH C1, C2; prototype `.awin`, `.arail`,
// images a01, a05, a06). Left menu (212 px): "Bu bilgisayar · Controller",
// Bilgisayarlar (count), Bu bilgisayar (only Host + Controller), Ayarlar,
// Hakkında; at the bottom the person's name + "Sürüm N". Not signed in: only
// the role chip and the "Sense hesabınla gir" page (the stock connection page
// is gone).
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../common.dart' show connect, gFFI, isMacOS;
import '../../../components/sense_version_chip.dart' show senseAppVersion;
import '../../../sense.dart';
import '../../../strings/controller.dart';
import '../../host/sense_home_mac.dart' show SenseMacPermissionCard;
import '../../host/this_computer/this_computer_page.dart';
import '../about/sense_about_page.dart';
import '../computers/computers_page.dart';
import '../data/grants.dart';
import '../login/login_controller.dart';
import '../login/login_page.dart';
import '../sense_home_strings.dart' show SenseHomeRole, senseRoleLabel;
import '../settings/sense_settings_page.dart';
import '../update/sense_update_view.dart' show SenseUpdateWatch;
import 'account_box.dart';
import '../../../../desktop/pages/desktop_tab_page.dart' show DesktopTabPage;
import '../../../router.dart' show senseAboutRequest, senseRoleChangeReopen;

enum SenseControllerNav { computers, thisComputer, settings, about }

// Prototype `.arail` 14/10/12, gap 2; `.arole` 0 6 12, chip 2×7 corner 6;
// `.anv` 9×10 corner 9, count 10.5; `.ame` 10/8/2; `.amain` 18/22/24.
const double _kRailTop = 14, _kRailSide = 10, _kRailBottom = 12, _kNavGap = 2;
const double _kNavPadV = 9, _kNavPadH = 10, _kChipPadV = 2, _kChipPadH = 7, _kChipRadius = 6;

const double _kMainTop = 18, _kMainSide = 22, _kMainBottom = 24;

/// Name shown at the bottom: the panel's display name, else the part of the
/// e-mail before "@".
String senseAccountName(String displayName, String email) {
  final d = displayName.trim();
  if (d.isNotEmpty) return d;
  final at = email.indexOf('@');
  return at > 0 ? email.substring(0, at) : email;
}

/// Binds the window: sign-in state, menu, grants, update strip, splash.
class SenseControllerShell extends StatefulWidget {
  const SenseControllerShell({
    super.key,
    required this.role,
    this.grantsBackend = const SenseGrantsBridge(),
    this.loginBackend = const SenseLoginBridge(),
    this.accountBackend = const SenseAccountBridge(),
  });

  /// [SenseHomeRole.controller] or [SenseHomeRole.both].
  final SenseHomeRole role;
  final SenseGrantsBackend grantsBackend;
  final SenseLoginBackend loginBackend;
  final SenseAccountBackend accountBackend;

  @override
  State<SenseControllerShell> createState() => _SenseControllerShellState();
}

class _SenseControllerShellState extends State<SenseControllerShell> with WidgetsBindingObserver {
  late final SenseGrantsWatch _grants = SenseGrantsWatch(widget.grantsBackend);
  late final SenseLoginController _login = SenseLoginController(widget.loginBackend);
  SenseControllerNav _nav = SenseControllerNav.computers;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _grants.start();
    senseAboutRequest.addListener(_showAbout); // Sense Remote (D3f): macOS app menu
  }

  // Signed out the sign-in page stays (About is in the menu after sign-in).
  void _showAbout() => setState(() => _nav = SenseControllerNav.about);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Plan §2.3: grants are asked again when the window gets focus.
    if (state == AppLifecycleState.resumed) _grants.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    senseAboutRequest.removeListener(_showAbout);
    _grants.dispose();
    _login.dispose();
    super.dispose();
  }

  Widget _scroll(Widget child) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(_kMainSide, _kMainTop, _kMainSide, _kMainBottom),
        child: child,
      );

  Widget _page(String email) {
    switch (_nav) {
      case SenseControllerNav.computers:
        return _scroll(SenseComputersPage(key: ValueKey('sense-computers-$email'), account: email, grants: _grants));
      case SenseControllerNav.thisComputer:
        return _scroll(SenseThisComputerPage(
          role: SenseHomeRole.both,
          // T8: the opening screen with "yeni rolle açılıyor" (A2c router).
          // Sense Remote (D3b): splash, then the app reopens with the new role.
          onRoleRestart: senseRoleChangeReopen,
          onOpenSettingsPassword: () => setState(() => _nav = SenseControllerNav.settings),
        ));
      case SenseControllerNav.settings:
        return const SenseSettingsPage();
      case SenseControllerNav.about:
        return const SenseAboutPage();
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
        final user = gFFI.userModel;
        final email = user.userName.value;
        final signedIn = email.isNotEmpty;
        final count = gFFI.groupModel.peers.map((p) => p.id).toSet().length;
        if (!signedIn && _nav != SenseControllerNav.computers) _nav = SenseControllerNav.computers;
        return SenseUpdateWatch(
          builder: (context, strip) => SenseControllerShellView(
            role: widget.role,
            nav: _nav,
            onNav: (n) => setState(() => _nav = n),
            signedIn: signedIn,
            name: senseAccountName(user.displayName.value, email),
            email: email,
            computerCount: count,
            version: senseAppVersion(),
            // macOS: a permission the role needs and is missing (Mac M7).
            strip: !signedIn
                ? null
                : (isMacOS
                    ? Column(mainAxisSize: MainAxisSize.min, children: [
                        SenseMacPermissionCard(role: widget.role),
                        if (strip != null) strip,
                      ])
                    : strip),

            onSignOut: () => widget.accountBackend.signOut(),
            openConnections: widget.accountBackend.openConnections,
            child: signedIn
                ? _page(email)
                : _scroll(SenseLoginPage(
                    controller: _login,
                    onConnect: (id) => connect(context, id),
                  )),
          ),
        );
      });
}

/// Pure view of the window (goldens and tests).
class SenseControllerShellView extends StatelessWidget {
  const SenseControllerShellView({
    super.key,
    required this.role,
    required this.nav,
    required this.onNav,
    required this.signedIn,
    required this.child,
    this.name = '',
    this.email = '',
    this.computerCount,
    this.version,
    this.strip,
    this.splash = false,
    this.onSignOut,
    this.openConnections,
    this.accountOpen = false,
  });

  final SenseHomeRole role;
  final SenseControllerNav nav;
  final ValueChanged<SenseControllerNav> onNav;
  final bool signedIn;

  /// The page (it scrolls itself).
  final Widget child;
  final String name;
  final String email;
  final int? computerCount;

  /// Null = the build has no number: no chip (nothing made up).
  final int? version;
  final Widget? strip;
  final bool splash;
  final VoidCallback? onSignOut;
  final Future<int> Function()? openConnections;

  /// Goldens: the account box shown open.
  final bool accountOpen;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.maybeSizeOf(context)?.width ?? SenseSizes.windowWidth;
    final page = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (strip != null)
        Padding(padding: const EdgeInsets.fromLTRB(_kMainSide, _kMainTop, _kMainSide, 0), child: strip!),
      Expanded(child: ScrollConfiguration(behavior: const SenseScrollBehavior(), child: child)),
    ]);
    return SenseToastHost(
      child: Stack(children: [
        Positioned.fill(
          child: ColoredBox(
            color: SenseColors.bg,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: SenseLayout.sideMenu(width), child: _rail()),
              const SizedBox(width: 1, child: ColoredBox(color: SenseColors.line)),
              Expanded(child: KeyedSubtree(key: Key('sense-controller-main-${nav.name}'), child: page)),
            ]),
          ),
        ),
        if (splash) const Positioned.fill(child: SenseSplash(key: Key('sense-controller-splash'))),
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
              // Wrap: "Bu bilgisayar" never breaks; a long badge ("Host + Controller") drops below it.
              child: Wrap(
                  spacing: SenseUi.iconGap,
                  runSpacing: SenseUi.iconGap,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                Text(SenseControllerStrings.thisComputer,
                    key: const Key('sense-controller-rail-title'),
                    maxLines: 1,
                    softWrap: false,
                    style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
                Container(
                  key: const Key('sense-controller-role-chip'),
                  padding: const EdgeInsets.symmetric(vertical: _kChipPadV, horizontal: _kChipPadH),
                  decoration: BoxDecoration(
                    color: SenseColors.raised,
                    border: Border.all(color: SenseColors.line),
                    borderRadius: BorderRadius.circular(_kChipRadius),
                  ),
                  child: Text(senseRoleLabel(role),
                      style: SenseTextStyles.of(size: SenseFontSize.caps, weight: SenseFontWeight.bold)),
                ),
              ]),
            ),
            if (signedIn) ...[
              _item(SenseControllerNav.computers, SenseControllerStrings.computers, count: computerCount),
              if (role == SenseHomeRole.both) ...[
                const SizedBox(height: _kNavGap),
                _item(SenseControllerNav.thisComputer, SenseControllerStrings.thisComputer),
              ],
              const SizedBox(height: _kNavGap),
              _item(SenseControllerNav.settings, SenseControllerStrings.settings),
              const SizedBox(height: _kNavGap),
              _item(SenseControllerNav.about, SenseControllerStrings.about),
            ],
            const Spacer(),
            if (signedIn) _footer(),
          ],
        ),
      );

  Widget _item(SenseControllerNav n, String label, {int? count}) => _NavItem(
        key: Key('sense-controller-nav-${n.name}'),
        label: label,
        count: count,
        selected: nav == n,
        onTap: () => onNav(n),
      );

  Widget _footer() => SenseAccountBox(
        name: name,
        email: email,
        onSignOut: onSignOut ?? () {},
        openConnections: openConnections,
        initiallyOpen: accountOpen,
        trailing: version == null
            ? null
            : SenseInteractive(
                key: const Key('sense-controller-version'),
                onTap: () => onNav(SenseControllerNav.about),
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
                    child: Text(SenseControllerStrings.version(version!),
                        style: SenseTextStyles.of(
                            size: SenseFontSize.capsSmall,
                            color: s.hovered ? SenseColors.text : SenseColors.textMuted)),
                  ),
                ),
              ),
      );
}

/// Left menu item (`.anv`), with the computer count on the right.
class _NavItem extends StatelessWidget {
  const _NavItem({super.key, required this.label, required this.selected, required this.onTap, this.count});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

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
              if (count != null && count! > 0)
                Text('$count', style: SenseTextStyles.of(size: SenseFontSize.caps, color: SenseColors.textMuted)),
            ]),
          ),
        ),
      );
}

/// Router entry (A2c `SenseEntry.controllerHome`, C1 → C2; Host + Controller
/// opens here too). Like the Host, the window keeps the stock frame (title bar,
/// window buttons, remote-input block, service status); its home tab shows
/// [SenseControllerShell] for both Controller roles (desktop_home_page.dart).
Widget senseControllerScreen() => const DesktopTabPage();
