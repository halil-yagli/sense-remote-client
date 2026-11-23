// Sense Remote: the Host permissions the panel set (YH H2 "Yetkiler"). The panel
// writes them with the signed envelope; here they are only read (bridge exists:
// `main_get_option`). An option is on unless it is "N".
import '../../../../consts.dart';
import '../../../../models/platform_model.dart';
import '../../../strings/host.dart';

class SenseHostPermission {
  const SenseHostPermission(this.label, this.key);
  final String label;

  /// Null = always on (seeing the screen is the connection itself).
  final String? key;
}

const kSenseHostPermissions = <SenseHostPermission>[
  SenseHostPermission(SenseHostStrings.permScreen, null),
  SenseHostPermission(SenseHostStrings.permInput, kOptionEnableKeyboard),
  SenseHostPermission(SenseHostStrings.permClipboard, kOptionEnableClipboard),
  SenseHostPermission(SenseHostStrings.permFile, kOptionEnableFileTransfer),
  SenseHostPermission(SenseHostStrings.permAudio, kOptionEnableAudio),
  SenseHostPermission(SenseHostStrings.permRestart, kOptionEnableRemoteRestart),
  SenseHostPermission(SenseHostStrings.permRecord, kOptionEnableRecordSession),
  SenseHostPermission(SenseHostStrings.permGhost, kOptionEnablePrivacyMode),
];

/// Pure: option value → on.
bool senseOptionOn(String value) => value != 'N';

/// Reads every permission, in [kSenseHostPermissions] order.
Future<List<bool>> senseHostPermissions() async => [
      for (final p in kSenseHostPermissions)
        p.key == null ? true : senseOptionOn(await bind.mainGetOption(key: p.key!)),
    ];
