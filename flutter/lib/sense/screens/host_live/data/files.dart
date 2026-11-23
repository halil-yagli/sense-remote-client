// Sense Remote: files of the Host card's chat (YH H4 = O12 on the Host side).
// The Host sends a file to the Controller and lists both directions through
// `main_sense_host_offer_files(conn_id, paths)` and `main_sense_host_file_jobs()`
// (plan §2.6, D3d2). Until the bridge has them the list stays empty and the
// ataç is not offered (see [SenseHostChatFiles.available]).

import 'package:url_launcher/url_launcher.dart';

import '../../shared/chat/chat_entry.dart';
import '../../shared/chat/data/files.dart';

class SenseHostChatFiles implements SenseChatFiles {
  SenseHostChatFiles({required this.connId});

  /// The CM connection id (Client.id).
  final int connId;

  /// The bridge can send files from the Host. False until D3d2.
  static const bool available = false;

  @override
  Future<List<String>> send(List<String> paths) async {
    if (paths.isEmpty) return const [];
    // TODO(D3d2): main_sense_host_offer_files(conn_id, paths) — Host →
    // Controller file offer. When it lands:
    //   return senseParseJobIds(await bind.mainSenseHostOfferFiles(
    //       connId: connId, paths: paths));
    return const [];
  }

  @override
  Future<List<SenseFileJob>> jobs() async {
    // TODO(D3d2): main_sense_host_file_jobs() — both directions, same JSON as
    // session_sense_file_jobs. When it lands:
    //   return senseParseFileJobs(await bind.mainSenseHostFileJobs());
    return const [];
  }

  @override
  Future<void> reveal(String path) async {
    if (path.isEmpty) return;
    await launchUrl(Uri.file(senseParentFolder(path)));
  }
}
