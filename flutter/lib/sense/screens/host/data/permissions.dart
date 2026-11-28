// Sense Remote: the Host permissions the panel set (YH H2 "Yetkiler"). The panel
// writes them with the signed envelope; here they are only read (bridge exists:
// `main_get_option`). #166 (FU-B10): the list is the panel's 13 permissions, in the
// panel's order (`PERMISSION_OPTION_KEYS`).
import '../../../../consts.dart';
import '../../../../models/platform_model.dart';
import '../../../strings/host.dart';

class SenseHostPermission {
  const SenseHostPermission(this.label, this.key, {this.onlyY = false});
  final String label;

  /// The option the panel writes ("Y" / "N").
  final String key;

  /// Decoded like the core's `option2bool`: `enable-*` options are on unless "N";
  /// the others (`allow-*`) are on only when "Y".
  final bool onlyY;
}

const kSenseHostPermissions = <SenseHostPermission>[
  SenseHostPermission(SenseHostStrings.permInput, kOptionEnableKeyboard),
  SenseHostPermission(SenseHostStrings.permClipboard, kOptionEnableClipboard),
  SenseHostPermission(SenseHostStrings.permFile, kOptionEnableFileTransfer),
  SenseHostPermission(SenseHostStrings.permAudio, kOptionEnableAudio),
  SenseHostPermission(SenseHostStrings.permRestart, kOptionEnableRemoteRestart),
  SenseHostPermission(SenseHostStrings.permRecord, kOptionEnableRecordSession),
  SenseHostPermission(SenseHostStrings.permBlockInput, kOptionEnableBlockInput),
  SenseHostPermission(SenseHostStrings.permGhost, kOptionEnablePrivacyMode),
  SenseHostPermission(SenseHostStrings.permTerminal, kOptionEnableTerminal),
  SenseHostPermission(SenseHostStrings.permTunnel, kOptionEnableTunnel),
  SenseHostPermission(SenseHostStrings.permCamera, kOptionEnableCamera),
  SenseHostPermission(SenseHostStrings.permPrinter, kOptionEnableRemotePrinter),
  SenseHostPermission(SenseHostStrings.permWallpaper, kOptionAllowRemoveWallpaper, onlyY: true),
];

/// Pure: option value → on.
bool senseOptionOn(String value) => value != 'N';

/// Pure: the value of [p] → on.
bool senseHostPermissionOn(SenseHostPermission p, String value) =>
    p.onlyY ? value == 'Y' : senseOptionOn(value);

/// Reads every permission, in [kSenseHostPermissions] order.
Future<List<bool>> senseHostPermissions() async => [
      for (final p in kSenseHostPermissions)
        senseHostPermissionOn(p, await bind.mainGetOption(key: p.key)),
    ];
