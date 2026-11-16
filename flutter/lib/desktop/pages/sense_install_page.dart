// Sense Remote: the install page of the setup file (`SenseRemote-Kurulum-<n>.exe`).
// Connects the Sense setup wizard to the native side; the wizard itself is pure UI.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/sense_install_wizard.dart';
import 'package:flutter_hbb/desktop/widgets/install_directory_confirmation.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

class SenseInstallPage extends StatefulWidget {
  const SenseInstallPage({super.key});

  @override
  State<SenseInstallPage> createState() => _SenseInstallPageState();
}

class _SenseInstallPageState extends State<SenseInstallPage> {
  late final Map<String, dynamic> _options =
      jsonDecode(bind.installInstallOptions()) as Map<String, dynamic>;

  Future<String> _install(SenseInstallRequest request) async {
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
        onInstall: _install,
        onFinish: (openApp) => bind.installSenseFinish(openApp: openApp),
        onPickPath: _pickPath,
        onClose: () => windowManager.close(),
        onDragStart: () => windowManager.startDragging(),
      ),
    );
  }
}
