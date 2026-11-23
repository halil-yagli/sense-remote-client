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

/// Local option the adapter keeps the choice in until D3d1 lands.
const kSenseIncomingDirOption = 'sense-incoming-dir';

class SenseIncomingDirBridge implements SenseIncomingDirSource {
  // TODO(D3d1): main_sense_incoming_dir — replace with
  // `bind.mainSenseIncomingDir()` (the core checks the folder can be reached).
  @override
  Future<String> current() async => bind.mainGetLocalOption(key: kSenseIncomingDirOption);

  // TODO(D3d1): main_sense_set_incoming_dir — replace with
  // `bind.mainSenseSetIncomingDir(path: path)`.
  @override
  Future<void> set(String path) => bind.mainSetLocalOption(key: kSenseIncomingDirOption, value: path);
}
