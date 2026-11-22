// Sense Remote: the install page of the setup file (`SenseRemote-Kurulum-<n>.exe`).
// Connects the Sense setup wizard to the native side; the wizard itself is pure UI.

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io' show exit, Process;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show isMacOS; // Sense Remote (Mac M3)
import 'package:flutter_hbb/common/sense_theme.dart' show senseRoleInstalled; // Sense Remote (U7)
import 'package:flutter_hbb/sense/screens/controller/sense_home_about.dart' show kSenseVersionOption; // Sense Remote
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart' show senseVersionFrom, kSenseVersionDefine; // Sense Remote
import 'package:flutter_hbb/sense/screens/install/sense_install_wizard.dart';
import 'package:flutter_hbb/desktop/widgets/install_directory_confirmation.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

class SenseInstallPage extends StatefulWidget {
  const SenseInstallPage({super.key});

  @override
  State<SenseInstallPage> createState() => _SenseInstallPageState();
}

/// Sense Remote (wave 3 I6): the wizard's platform calls (src/sense/enroll.rs). The panel
/// token stays in Rust; Dart sees the sign-in state, the approval URL and the pairing code.
class _RustBackend implements SenseInstallBackend {
  _RustBackend(this.context);

  final BuildContext context;

  // Sense Remote (Mac M3): what the macOS window close button may do (see the page state).
  bool installed = false;
  int _working = 0;
  bool get working => _working > 0;

  @override
  Future<void> loginStart() => bind.installSenseLoginStart();

  @override
  Future<SenseLoginStatus> loginStatus() async =>
      SenseLoginStatus.fromJson(await bind.installSenseLoginStatus());

  @override
  Future<void> loginCancel() => bind.installSenseLoginCancel();

  @override
  Future<void> openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      debugPrint('Sense Remote: failed to open the approval page');
    }
  }

  @override
  Future<SenseProjectList> projects() async =>
      SenseProjectList.fromJson(await bind.installSenseProjects());

  @override
  Future<String> install(SenseInstallRequest request) async {
    // Sense Remote (Mac M3): macOS has no install folder to choose (the app is installed
    // where it runs, /Applications).
    if (!isMacOS) {
      // RustDesk's warning when the chosen folder is not empty (advanced path change).
      final confirmed =
          await confirmInstallDirectory(context, targetPath: request.path);
      if (!confirmed) return 'cancelled';
    }
    _working++;
    try {
      final result = await bind.installSenseInstall(
        options: request.options,
        path: request.path,
        role: request.role,
        info: request.infoJson,
      );
      if (result.isEmpty) installed = true;
      return result;
    } finally {
      _working--;
    }
  }

  @override
  Future<SenseEnrollResult> enroll(SenseEnrollRequest request) async {
    _working++;
    try {
      return SenseEnrollResult.fromJson(
          await bind.installSenseEnroll(request: request.toJson()));
    } finally {
      _working--;
    }
  }

  @override
  void finish(bool openApp) => bind.installSenseFinish(openApp: openApp);

  // ---- Sense Remote (Mac M3): macOS steps ----

  @override
  Future<bool> inApplications() async => bind.mainIsInstalled();

  // Sense Remote (code review K4-5): the one binding shared with the home screens.
  static const _mac = SenseMacPermissionBind();

  @override
  Future<SenseMacPermissions> macPermissions() async => _mac.read();

  @override
  Future<void> openMacPermission(SenseMacPermission permission) =>
      _mac.open(permission);

  @override
  Future<String> restartAgent() => _mac.restartAgent();
}

class _SenseInstallPageState extends State<SenseInstallPage>
    with WindowListener {
  late final Map<String, dynamic> _options =
      jsonDecode(bind.installInstallOptions()) as Map<String, dynamic>;
  late final _backend = _RustBackend(context);

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
    SenseUpgrade? upgrade;
    try {
      upgrade = await senseUpgradeOf(
        roleInstalled: senseRoleInstalled(),
        current: int.tryParse(_senseVersion()) ?? 0,
        host: !bind.isOutgoingOnly(),
        controller: !bind.isIncomingOnly(),
        run: () async {
          _backend._working++;
          try {
            return await bind.installSenseUpgradeInPlace();
          } finally {
            _backend._working--;
          }
        },
      );
    } catch (_) {
      upgrade = null;
    }
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
      return const Scaffold(backgroundColor: SenseTokens.black);
    }
    return Scaffold(
      backgroundColor: SenseTokens.black,
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
