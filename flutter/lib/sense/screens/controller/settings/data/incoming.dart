// Sense Remote: folder for files that arrive through the chat (YH C3 "Sohbetten
// gelen dosyalar"; plan §2.6 `main_sense_incoming_dir` / `main_sense_set_incoming_dir`,
// D3d1). The core answers the folder it really uses (Downloads when the chosen
// one cannot be reached); an empty answer means Downloads.
import '../../../../../models/platform_model.dart';

abstract class SenseIncomingDirSource {
  /// Folder in use; '' = the Downloads folder.
  Future<String> current();
  Future<void> set(String path);
}

/// Local option the core keeps the choice in (`chat_file.rs` INCOMING_DIR_OPTION).
const kSenseIncomingDirOption = 'sense-incoming-dir';

class SenseIncomingDirBridge implements SenseIncomingDirSource {
  /// The core checks the folder can be written to; '' when it falls back to
  /// Downloads.
  @override
  Future<String> current() => bind.mainSenseIncomingDir();

  @override
  Future<void> set(String path) => bind.mainSenseSetIncomingDir(path: path);
}
