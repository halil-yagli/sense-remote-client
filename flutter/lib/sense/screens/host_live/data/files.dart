// Sense Remote: files of the Host card's chat (YH H4 = O12 on the Host side).
// The Host offers a file to the Controller and lists both directions through
// `main_sense_host_offer_files(conn_id, paths)` and `main_sense_host_file_jobs()`
// (plan §2.6, D3d2). The Controller pulls an offered file into its incoming
// folder; it can read only what was offered here.

import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../models/platform_model.dart';
import '../../shared/chat/chat_entry.dart';
import '../../shared/chat/data/files.dart';

class SenseHostChatFiles implements SenseChatFiles {
  SenseHostChatFiles({required this.connId});

  /// The CM connection id (Client.id).
  final int connId;

  /// The bridge can send files from the Host (D3d2).
  static const bool available = true;

  @override
  Future<List<String>> send(List<String> paths) async {
    if (paths.isEmpty) return const [];
    return senseParseJobIds(
        await bind.mainSenseHostOfferFiles(connId: connId, paths: paths));
  }

  @override
  Future<List<SenseFileJob>> jobs() async =>
      senseParseFileJobs(await bind.mainSenseHostFileJobs());

  @override
  Future<void> reveal(String path) async {
    if (path.isEmpty) return;
    await launchUrl(Uri.file(senseParentFolder(path)));
  }
}

/// The system file chooser of the Host card's ataç: several files, any kind.
Future<List<String>> senseHostPickFiles() async {
  final r = await FilePicker.platform.pickFiles(allowMultiple: true);
  return [for (final f in r?.files ?? const <PlatformFile>[]) f.path]
      .whereType<String>()
      .toList();
}
