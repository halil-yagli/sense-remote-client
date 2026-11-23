// Sense Remote: the install page of the setup file (`SenseRemote-Kurulum-<n>.exe`, YH K1–K7).
// Connects the Sense setup wizard to the native side (data/install_bridge.dart); the wizard
// itself is pure UI. No dialogs: the only windows are the UAC prompt / macOS password.

import 'dart:async' show TimeoutException, unawaited;
import 'dart:convert';
import 'dart:io' show exit, Process;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show isMacOS; // Sense Remote (Mac M3)
import 'package:flutter_hbb/common/sense_theme.dart' show senseRoleInstalled; // Sense Remote (U7)
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart' show senseVersionFrom, kSenseVersionDefine, kSenseVersionOption; // Sense Remote
import 'package:flutter_hbb/sense/screens/install/data/install_bridge.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_wizard.dart';
import 'package:flutter_hbb/sense/sense.dart' show SenseColors, senseTheme;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

class SenseInstallPage extends StatefulWidget {
  const SenseInstallPage({super.key});

  @override
  State<SenseInstallPage> createState() => _SenseInstallPageState();
}

class _SenseInstallPageState extends State<SenseInstallPage>
    with WindowListener {
  late final Map<String, dynamic> _options =
      jsonDecode(bind.installInstallOptions()) as Map<String, dynamic>;
  final _backend = SenseInstallBridge(isMac: isMacOS);

  // Sense Remote (update plan §8, U7): read once before the wizard is shown; `null` = the
  // normal wizard.
  bool _upgradeRead = false;
  SenseUpgrade? _upgrade;

  // Sense Remote (Mac M3): on macOS the window keeps its native close button and closing
  // the last window does not end the app (AppDelegate). So the close is handled here: after
  // installing it leaves through `finish` like the wizard's own buttons (a Host drops the
  // sign-in, K-KAYIT-b); before installing the app quits; never in the middle of installing.
  @override
  void initState() {
    super.initState();
    unawaited(_readUpgrade());
    // Sense Remote (YH K1): the wizard window is 860 × 620, at least 760 × 540.
    unawaited(windowManager.setMinimumSize(kSenseInstallMinSize));
    unawaited(windowManager.setSize(kSenseInstallSize).then((_) => windowManager.center()));
    if (isMacOS) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    if (isMacOS) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    if (!isMacOS || _backend.working) return;
    if (_backend.installed) {
      _backend.finish(false);
    } else {
      exit(0);
    }
  }

  /// Sense Remote (U7): a computer with a Sense role gets the upgrade screen (or the "already
  /// installed" note) instead of the sign-in and registration of a new installation.
  Future<void> _readUpgrade() async {
    // Sense Remote: never longer than kSenseUpgradeReadTimeout; a read that hangs or fails
    // opens the wizard instead of leaving the black frame for ever.
    final upgrade = await senseReadUpgradeOrNull(() => senseUpgradeOf(
          roleInstalled: senseRoleInstalled(),
          current: int.tryParse(_senseVersion()) ?? 0,
          host: !bind.isOutgoingOnly(),
          controller: !bind.isIncomingOnly(),
          run: () => _backend.busy(() => bind.installSenseUpgradeInPlace()),
        ));
    if (!mounted) return;
    setState(() {
      _upgrade = upgrade;
      _upgradeRead = true;
    });
  }

  Future<String?> _pickPath(String current) async {
    final dir =
        await FilePicker.platform.getDirectoryPath(initialDirectory: current);
    if (dir == null) return null;
    return p.join(dir, await bind.mainGetAppName());
  }

  @override
  Widget build(BuildContext context) {
    // Sense Remote (U7): a short black frame until the installed version was read.
    if (!_upgradeRead) {
      return const ColoredBox(color: SenseColors.bg, child: SizedBox.expand());
    }
    return Theme(
      data: senseTheme(),
      child: Scaffold(
        backgroundColor: SenseColors.bg,
        body: SenseInstallWizard(
          initialPath: bind.installInstallPath(),
          initialStartMenu: _options['STARTMENUSHORTCUTS'] != '0',
          initialDesktopIcon: _options['DESKTOPSHORTCUTS'] != '0',
          initialPrinter: _options['PRINTER'] == '1',
          backend: _backend,
          onPickPath: _pickPath,
          // Sense Remote (Mac M3): with the close prevented this arrives in `onWindowClose`.
          onClose: () => windowManager.close(),
          mac: isMacOS,
          onDragStart: () => windowManager.startDragging(),
          // Sense Remote: version number of this setup file (#19 built-in option, T3-11).
          version: _senseVersion(),
          upgrade: _upgrade, // Sense Remote (U7)
        ),
      ),
    );
  }
}

/// Sense Remote: the Sense version of this build (`sense-version` built-in option, then the
/// `SENSE_VERSION` define); empty when the build has none.
String _senseVersion() {
  final n = senseVersionFrom(
          bind.mainGetBuildinOption(key: kSenseVersionOption)) ??
      senseVersionFrom(kSenseVersionDefine);
  return n == null ? '' : '$n';
}

/// Sense Remote: how long the setup page waits for the upgrade check before it shows the wizard.
const Duration kSenseUpgradeReadTimeout = Duration(seconds: 10);

/// Sense Remote: [read] with a time limit; `null` (the normal wizard) when it fails or takes
/// longer than [timeout], so the setup window never stays on its black frame.
Future<SenseUpgrade?> senseReadUpgradeOrNull(Future<SenseUpgrade?> Function() read,
    {Duration timeout = kSenseUpgradeReadTimeout}) async {
  try {
    return await read().timeout(timeout);
  } on TimeoutException {
    debugPrint('Sense Remote: upgrade check timed out, wizard shown');
    return null;
  } catch (_) {
    return null;
  }
}

/// Sense Remote (update plan §8, U7): the upgrade for a computer that already has a role.
/// Windows compares the installed version (HKLM `Version`) with this setup file; macOS offers
/// the move when the app bundle is not root's (it was just dragged over the old one).
Future<SenseUpgrade?> senseUpgradeOf({
  required bool roleInstalled,
  required int current,
  required bool host,
  required bool controller,
  required Future<String> Function() run,
}) async {
  if (!roleInstalled) return null;
  if (isMacOS) {
    if (current <= 0 || !await senseMacNeedsMove()) return null;
    return SenseUpgrade(
        mode: SenseUpgradeMode.upgrade,
        installed: 0,
        current: current,
        host: host,
        controller: controller,
        run: run);
  }
  final installed = await bind.mainSenseInstalledVersion();
  final mode = senseUpgradeMode(
      roleInstalled: roleInstalled, installed: installed, current: current);
  if (mode == SenseUpgradeMode.none) return null;
  return SenseUpgrade(
      mode: mode,
      installed: installed,
      current: current,
      host: host,
      controller: controller,
      run: run);
}

/// Sense Remote (Mac M3, U7): macOS start-up entry of the install flow. `true` when the setup
/// page opens instead of the main window: no installed role (root-owned state file; Windows gets
/// there with `--install` from the setup exe), or the new app was dragged over version 2 and the
/// setup page shows "Geçişi tamamla" (bundle to root, service restarted, permissions).
Future<bool> senseInstallBoot() async =>
    senseMacNeedsSetup(isMac: true, roleInstalled: senseRoleInstalled()) ||
    (senseRoleInstalled() && await senseMacNeedsMove());

/// Sense Remote (U7, macOS): the paths root executes are not all root's and write-protected,
/// so the new app was copied over the old one and the move is not finished yet. Same paths as
/// `root_executed_paths` (src/sense/identity/mac_script.rs). Any failure: `false`.
Future<bool> senseMacNeedsMove() async {
  try {
    final name = await bind.mainGetAppName();
    final app = '/Applications/$name.app';
    final paths = [
      app,
      '$app/Contents',
      '$app/Contents/MacOS',
      '$app/Contents/MacOS/service',
      '$app/Contents/MacOS/$name',
    ];
    final result =
        await Process.run('/usr/bin/stat', ['-f', '%u %Lp', ...paths]);
    if (result.exitCode != 0) return false;
    return !senseMacBundleTrusted('${result.stdout}', paths.length);
  } catch (_) {
    return false;
  }
}
