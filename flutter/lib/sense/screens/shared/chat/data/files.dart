// Sense Remote: file transfers of the chat (YH O12, S5). The chat only talks to
// [SenseChatFiles]; the Controller session uses [SenseSessionChatFiles], the
// Host card (C5) gives its own (main_sense_host_file_jobs / _offer_files, D3d2).

import 'dart:convert';

import 'package:url_launcher/url_launcher.dart';

import '../../../../../common.dart' show SessionID;
import '../../../../../models/platform_model.dart';
import '../chat_entry.dart';

/// What the chat needs from the file side.
abstract class SenseChatFiles {
  /// Starts sending [paths] (any size, any kind). Returns the new job ids.
  Future<List<String>> send(List<String> paths);

  /// All transfers of this connection, both directions.
  Future<List<SenseFileJob>> jobs();

  /// Opens the folder that holds [path] (never the file itself: O12 "dosya
  /// kendiliğinden açılmaz").
  Future<void> reveal(String path);
}

/// Parses the `session_sense_file_jobs` JSON (§2.6). Broken input gives an
/// empty list, never an exception.
List<SenseFileJob> senseParseFileJobs(String raw) {
  try {
    final data = jsonDecode(raw);
    if (data is! List) return const [];
    return [for (final j in data) SenseFileJob.fromJson(j)].whereType<SenseFileJob>().toList();
  } catch (_) {
    return const [];
  }
}

/// Parses the ids `session_sense_send_files` returns (a JSON list of strings).
List<String> senseParseJobIds(String raw) {
  try {
    final data = jsonDecode(raw);
    if (data is! List) return const [];
    return [for (final v in data) '$v'].where((s) => s.isNotEmpty).toList();
  } catch (_) {
    return const [];
  }
}

/// Folder of [path] ("C:\\Users\\a\\Downloads\\x.png" → "C:\\Users\\a\\Downloads").
String senseParentFolder(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i <= 0 ? path : path.substring(0, i);
}

/// Controller side of one connection.
class SenseSessionChatFiles implements SenseChatFiles {
  SenseSessionChatFiles({required this.sessionId});

  /// The RustDesk session id (FFI.sessionId).
  final SessionID sessionId;

  @override
  Future<List<String>> send(List<String> paths) async {
    if (paths.isEmpty) return const [];
    // Goes over the open remote connection; the Host writes it into its
    // incoming folder under a free name (D3d1).
    return senseParseJobIds(
        await bind.sessionSenseSendFiles(sessionId: sessionId, paths: paths));
  }

  @override
  Future<List<SenseFileJob>> jobs() async =>
      senseParseFileJobs(await bind.sessionSenseFileJobs(sessionId: sessionId));

  @override
  Future<void> reveal(String path) async {
    if (path.isEmpty) return;
    await launchUrl(Uri.file(senseParentFolder(path)));
  }
}
