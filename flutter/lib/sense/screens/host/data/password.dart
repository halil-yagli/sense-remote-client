// Sense Remote: bridge of the permanent password (plan B2, `screens/host/data/`).
// Moved here from sense_password_page.dart (which re-exports it). The bridge
// functions exist (`main_sense_password_*`); the state machine stays in
// sense_password_model.dart (kept).
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../../models/platform_model.dart';
import '../sense_password_model.dart';

class SensePasswordBridge implements SensePasswordBackend {
  const SensePasswordBridge();

  @override
  Future<String> status() => bind.mainSensePasswordStatus();
  @override
  Future<String> begin() => bind.mainSensePasswordBegin();
  @override
  Future<String> loginStatus() => bind.mainSensePasswordLoginStatus();
  @override
  Future<String> unlock() => bind.mainSensePasswordUnlock();
  @override
  Future<String> check(String password) => bind.mainSensePasswordCheck(password: password);
  @override
  Future<String> set(String password) => bind.mainSensePasswordSet(password: password);
  @override
  Future<void> cancel() => bind.mainSensePasswordCancel();
  @override
  void openUrl(String url) => launchUrlString(url);
  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));
}
