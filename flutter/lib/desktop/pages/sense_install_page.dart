// Sense Remote: the install page of the setup file (`SenseRemote-Kurulum-<n>.exe`).
// Connects the Sense setup wizard to the native side; the wizard itself is pure UI.

import 'dart:convert';
import 'dart:io' show exit;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show isMacOS; // Sense Remote (Mac M3)
import 'package:flutter_hbb/desktop/pages/sense_home_about.dart' show kSenseVersionOption; // Sense Remote
import 'package:flutter_hbb/desktop/pages/sense_home_strings.dart' show senseVersionFrom, kSenseVersionDefine; // Sense Remote
import 'package:flutter_hbb/desktop/pages/sense_install_wizard.dart';
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

  // The existing checks, without a system prompt (the same ones the heartbeat reports).
  @override
  Future<SenseMacPermissions> macPermissions() async => SenseMacPermissions(
        screenRecording: bind.mainIsCanScreenRecording(prompt: false),
        accessibility: bind.mainIsProcessTrusted(prompt: false),
        inputMonitoring: bind.mainIsCanInputMonitoring(prompt: false),
      );

  @override
  Future<void> openMacPermission(SenseMacPermission permission) async {
    // The request puts Sense Remote into the list of that pane; macOS shows its own prompt
    // only once per app, so the pane is opened as well (later presses would do nothing).
    switch (permission) {
      case SenseMacPermission.screenRecording:
        bind.mainIsCanScreenRecording(prompt: true);
        break;
      case SenseMacPermission.accessibility:
        bind.mainIsProcessTrusted(prompt: true);
        break;
      case SenseMacPermission.inputMonitoring:
        bind.mainIsCanInputMonitoring(prompt: true);
        break;
    }
    await openUrl(permission.settingsUrl);
  }

  @override
  Future<String> restartAgent() => bind.installSenseRestartAgent();
}

class _SenseInstallPageState extends State<SenseInstallPage>
    with WindowListener {
  late final Map<String, dynamic> _options =
      jsonDecode(bind.installInstallOptions()) as Map<String, dynamic>;
  late final _backend = _RustBackend(context);

  // Sense Remote (Mac M3): on macOS the window keeps its native close button and closing
  // the last window does not end the app (AppDelegate). So the close is handled here: after
  // installing it leaves through `finish` like the wizard's own buttons (a Host drops the
  // sign-in, K-KAYIT-b); before installing the app quits; never in the middle of installing.
  @override
  void initState() {
    super.initState();
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

  Future<String?> _pickPath(String current) async {
    final dir =
        await FilePicker.platform.getDirectoryPath(initialDirectory: current);
    if (dir == null) return null;
    return p.join(dir, await bind.mainGetAppName());
  }

  @override
  Widget build(BuildContext context) {
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
