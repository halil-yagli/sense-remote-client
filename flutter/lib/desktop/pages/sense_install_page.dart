// Sense Remote: the install page of the setup file (`SenseRemote-Kurulum-<n>.exe`).
// Connects the Sense setup wizard to the native side; the wizard itself is pure UI.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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
    // RustDesk's warning when the chosen folder is not empty (advanced path change).
    final confirmed =
        await confirmInstallDirectory(context, targetPath: request.path);
    if (!confirmed) return 'cancelled';
    return bind.installSenseInstall(
      options: request.options,
      path: request.path,
      role: request.role,
      info: request.infoJson,
    );
  }

  @override
  Future<SenseEnrollResult> enroll(SenseEnrollRequest request) async =>
      SenseEnrollResult.fromJson(
          await bind.installSenseEnroll(request: request.toJson()));

  @override
  void finish(bool openApp) => bind.installSenseFinish(openApp: openApp);
}

class _SenseInstallPageState extends State<SenseInstallPage> {
  late final Map<String, dynamic> _options =
      jsonDecode(bind.installInstallOptions()) as Map<String, dynamic>;
  late final _backend = _RustBackend(context);

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
        onClose: () => windowManager.close(),
        onDragStart: () => windowManager.startDragging(),
      ),
    );
  }
}
