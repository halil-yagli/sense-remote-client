// Sense Remote: the setup wizard's platform calls (src/sense/enroll.rs, install_*). The panel
// token stays in Rust; Dart sees the sign-in state, the approval URL and the pairing code.

import 'dart:io' show Directory, FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../../../models/platform_model.dart';
import '../sense_install_model.dart';

class SenseInstallBridge implements SenseInstallBackend {
  SenseInstallBridge({required this.isMac});

  final bool isMac;

  /// What the macOS window close button may do (see the page).
  bool installed = false;
  int _working = 0;
  bool get working => _working > 0;

  /// Runs [job] counted as work in progress (the macOS close button waits for it).
  Future<T> busy<T>(Future<T> Function() job) async {
    _working++;
    try {
      return await job();
    } finally {
      _working--;
    }
  }

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
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));

  /// `main_sense_install_options()`: the projects of the employee WITH their panel locations
  /// (`GET /api/device-group/accessible` `sense.locations`).
  @override
  Future<SenseInstallOptions> installOptions() async =>
      SenseInstallOptions.fromJson(await bind.mainSenseInstallOptions());

  @override
  Future<bool> folderNotEmpty(String path) async {
    // This app's own install folder is fine (a reinstall writes over it).
    if (bind.mainIsInstalled() && p.equals(path, bind.installInstallPath())) {
      return false;
    }
    try {
      final dir = Directory(path);
      return await dir.exists() && !await dir.list(followLinks: false).isEmpty;
    } on FileSystemException catch (e) {
      debugPrint('Sense Remote: install folder check failed: $e');
      return true;
    }
  }

  @override
  Future<String> install(SenseInstallRequest request) => busy(() async {
        final result = await bind.installSenseInstall(
          options: request.options,
          path: request.path,
          role: request.role,
          info: request.infoJson,
        );
        if (result.isEmpty) installed = true;
        return result;
      });

  @override
  Future<SenseEnrollResult> enroll(SenseEnrollRequest request) => busy(() async =>
      SenseEnrollResult.fromJson(await bind.installSenseEnroll(request: request.toJson())));

  @override
  void finish(bool openApp) => bind.installSenseFinish(openApp: openApp);

  // ---- macOS ----

  @override
  Future<bool> inApplications() async => bind.mainIsInstalled();

  static const _mac = SenseMacPermissionBind();

  @override
  Future<SenseMacPermissions> macPermissions() async => _mac.read();

  @override
  Future<void> openMacPermission(SenseMacPermission permission) => _mac.open(permission);

  @override
  Future<String> restartAgent() => _mac.restartAgent();
}
