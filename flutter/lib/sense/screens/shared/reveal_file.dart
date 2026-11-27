// Sense Remote (#122, KN5): "Klasörde göster" opens the folder with the
// received file selected, so it is found even among older files (Windows
// `explorer /select,`, macOS `open -R`). The file itself is never opened (O12).
// Kept outside shared/chat: the chat code has no dart:io (S12, "no way to write
// to disk"); this only starts the system file browser.

import 'dart:io' show Platform, Process, ProcessStartMode;

import 'package:url_launcher/url_launcher.dart';

/// The system command that shows [path] selected in its folder; null where
/// there is none (the folder is opened instead).
({String exe, List<String> args})? senseRevealCommand(String path,
    {required bool windows, required bool mac}) {
  if (path.isEmpty) return null;
  if (windows) return (exe: 'explorer.exe', args: ['/select,', path]);
  if (mac) return (exe: 'open', args: ['-R', path]);
  return null;
}

/// Folder of [path] ("C:\\Users\\a\\Downloads\\x.png" → "C:\\Users\\a\\Downloads").
String senseFolderOf(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i <= 0 ? path : path.substring(0, i);
}

/// Shows [path] selected in Explorer / Finder; elsewhere (or when that fails)
/// opens its folder.
Future<void> senseRevealFile(String path) async {
  if (path.isEmpty) return;
  final cmd = senseRevealCommand(path, windows: Platform.isWindows, mac: Platform.isMacOS);
  if (cmd != null) {
    try {
      // explorer.exe answers 1 even when it worked; only a start failure counts.
      await Process.start(cmd.exe, cmd.args, mode: ProcessStartMode.detached);
      return;
    } catch (_) {
      // Fall back to the folder below.
    }
  }
  await launchUrl(Uri.file(senseFolderOf(path)));
}
