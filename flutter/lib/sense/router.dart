// Sense Remote (A2c): main entry and routing.
//
// - Role → home screen (role from `senseHomeRoleFrom`). The B/C screens are
//   written in parallel; each one is registered in [senseRegisterScreens]
//   with one line (see [SenseEntry] for the expected names). While an entry
//   is missing, the existing screens are used (the RustDesk tab page with the
//   Sense home branches inside it).
// - Opening screen (YH T8): [SenseSplashGate] wraps the main window. It shows
//   [SenseSplash] at start, after an update ("Sürüm N kuruluyor · Sense Remote
//   yeniden açılıyor") and whenever [senseShowSplash] is called (e.g. after a
//   role change, `SenseCommonStrings.splashRoleChange`).
//
// Only dark theme (T1), only Turkish (T2). main.dart is not touched by B or C.
import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/widgets.dart';

import '../models/platform_model.dart';

import 'screens/controller/about/sense_about_page.dart' show senseAboutScreen;
import 'screens/controller/sense_home_strings.dart' show SenseHomeRole;
import 'screens/controller/settings/sense_settings_page.dart' show senseControllerSettingsScreen;
import 'screens/controller/shell/controller_shell.dart' show senseControllerScreen;
import 'screens/host/shell/host_shell.dart' show senseHostScreen;
import 'screens/splash/sense_splash.dart';
import 'strings/common.dart';
import 'tokens/sense_tokens.dart';

/// Entry points the B/C screens provide. Expected functions (by name):
/// - [hostHome]: `Widget senseHostScreen()` — B2, `screens/host/` (H1, H2).
/// - [controllerHome]: `Widget senseControllerScreen()` — B3,
///   `screens/controller/shell/` (C1 sign-in → C2 Bilgisayarlar; Host +
///   Controller opens here too, B2's Host card lives inside it).
/// - [controllerSettings]: `Widget senseControllerSettingsScreen()` — B4,
///   `screens/controller/settings/` (C3; never from a Host).
/// - [about]: `Widget senseAboutScreen()` — B4, `screens/controller/about/`
///   (C4; Host reaches only this, H1 risk).
enum SenseEntry { hostHome, controllerHome, controllerSettings, about }

typedef SenseEntryBuilder = Widget Function();

final Map<SenseEntry, SenseEntryBuilder> _entries = {};

/// Registers (or replaces) the builder of [entry].
void senseRegisterEntry(SenseEntry entry, SenseEntryBuilder builder) =>
    _entries[entry] = builder;

/// Registers the B/C entries; main.dart calls it once before the first frame.
/// B/C add their line here when their screen lands, e.g.
/// `senseRegisterEntry(SenseEntry.hostHome, senseHostScreen);`
void senseRegisterScreens() {
  senseRegisterEntry(SenseEntry.hostHome, senseHostScreen);
  senseRegisterEntry(SenseEntry.controllerHome, senseControllerScreen);
  senseRegisterEntry(SenseEntry.controllerSettings, senseControllerSettingsScreen);
  senseRegisterEntry(SenseEntry.about, senseAboutScreen);
}

/// Removes every registered entry (tests).
@visibleForTesting
void senseClearEntries() => _entries.clear();

/// The registered builder of [entry], or null while it is missing.
SenseEntryBuilder? senseEntry(SenseEntry entry) => _entries[entry];

/// Pure: which entry is the home screen of [role]; null = no Sense home
/// (not installed).
SenseEntry? senseHomeEntryFor(SenseHomeRole role) {
  switch (role) {
    case SenseHomeRole.host:
      return SenseEntry.hostHome;
    case SenseHomeRole.controller:
    case SenseHomeRole.both:
      return SenseEntry.controllerHome;
    case SenseHomeRole.none:
      return null;
  }
}

/// Home screen of [role]: the registered B/C entry, otherwise [fallback]
/// (the existing screens).
Widget senseHomeFor(SenseHomeRole role, {required Widget Function() fallback}) {
  final entry = senseHomeEntryFor(role);
  final builder = entry == null ? null : _entries[entry];
  return builder != null ? builder() : fallback();
}

/// What the opening screen shows.
@immutable
class SenseSplashRequest {
  const SenseSplashRequest({this.updatingToVersion, this.message});
  final int? updatingToVersion;
  final String? message;
}

/// The splash currently asked for; null = none.
final ValueNotifier<SenseSplashRequest?> senseSplashRequest =
    ValueNotifier<SenseSplashRequest?>(null);

/// Shows the opening screen over the main window (one breath, then fades).
/// [message] e.g. `SenseCommonStrings.splashRoleChange`; [updatingToVersion]
/// shows the update text.
void senseShowSplash({String? message, int? updatingToVersion}) =>
    senseSplashRequest.value = SenseSplashRequest(
        message: message, updatingToVersion: updatingToVersion);

/// Sense Remote (D3b): the service stored the new role. The opening screen
/// covers the window for one breath ("Rol uygulanıyor · Sense Remote yeni
/// rolle açılıyor"), then the app starts again so the new role's shell opens
/// (the home screen is chosen once, at start).
void senseRoleChangeReopen() {
  senseShowSplash(message: SenseCommonStrings.splashRoleChange);
  Timer(SenseMotion.breatheFast.duration, () => senseReopenApp());
}

/// Starts the app again and ends this process; when the helper can not be
/// started the window stays (the role is applied at the next start). Tests
/// replace it.
@visibleForTesting
Future<void> Function() senseReopenApp = _reopenApp;

Future<void> _reopenApp() async {
  final error = await bind.mainSenseRoleReopen();
  if (error.isEmpty) exit(0);
}

/// Pure: the version just installed when the app opens right after an update
/// (`main_sense_update_status` `last_result`: state installed, [atSeconds]
/// within two minutes of [nowSeconds] either way — the updater stamps it when
/// the new version is healthy, about when the window opens); null otherwise.
int? senseJustUpdatedTo(
    {required bool installed,
    required int? to,
    required int? atSeconds,
    required int nowSeconds}) {
  if (!installed || to == null || atSeconds == null) return null;
  return (nowSeconds - atSeconds).abs() <= kSenseJustUpdatedWindowSeconds
      ? to
      : null;
}

/// How long after an update the start counts as "right after" (seconds).
const int kSenseJustUpdatedWindowSeconds = 2 * Duration.secondsPerMinute;

/// Wraps the main window: [SenseSplash] on top while a splash is asked for.
/// It stays one breath ([SenseMotion.breatheFast]) and fades out over
/// [SenseMotion.layerFade].
class SenseSplashGate extends StatefulWidget {
  const SenseSplashGate(
      {super.key,
      required this.child,
      this.showAtStart = true,
      this.updatingToVersion,
      this.animate = true});

  final Widget child;

  /// Opening screen at start (T8).
  final bool showAtStart;

  /// Set when the app opens right after an update.
  final int? updatingToVersion;

  /// False: no breathing/fade (still frames for tests).
  final bool animate;

  @override
  State<SenseSplashGate> createState() => _SenseSplashGateState();
}

class _SenseSplashGateState extends State<SenseSplashGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _out;
  Timer? _hold;
  SenseSplashRequest? _shown;
  int _serial = 0;

  @override
  void initState() {
    super.initState();
    _out = AnimationController(
        vsync: this, duration: SenseMotion.layerFade.duration)
      ..addStatusListener(_onFade);
    senseSplashRequest.addListener(_onRequest);
    if (widget.showAtStart || widget.updatingToVersion != null) {
      _show(SenseSplashRequest(updatingToVersion: widget.updatingToVersion));
    }
  }

  void _onRequest() {
    final r = senseSplashRequest.value;
    if (r != null) _show(r);
  }

  void _show(SenseSplashRequest r) {
    _hold?.cancel();
    _out.value = 0;
    setState(() {
      _serial++;
      _shown = r;
    });
    _hold = Timer(SenseMotion.breatheFast.duration, () {
      if (mounted) _out.forward();
    });
  }

  void _onFade(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    final r = _shown;
    setState(() => _shown = null);
    if (r != null && identical(senseSplashRequest.value, r)) {
      senseSplashRequest.value = null;
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    senseSplashRequest.removeListener(_onRequest);
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (shown != null)
          FadeTransition(
            key: const Key('sense-splash-gate'),
            opacity: ReverseAnimation(_out),
            // The window under it is not usable while the splash is up.
            child: AbsorbPointer(
                child: SenseSplash(
              key: ValueKey(_serial),
              updatingToVersion: shown.updatingToVersion,
              message: shown.message,
              animate: widget.animate,
            )),
          ),
      ],
    );
  }
}
