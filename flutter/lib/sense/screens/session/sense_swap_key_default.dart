// Sense Remote (S7, #91): a Mac Controller on a Windows Host swaps Ctrl and Cmd by default
// (`allow_swap_key`), because Mac users press Cmd for the Windows shortcuts. The user can turn
// it off; that choice is remembered for this computer (a per-peer marker), so the default
// never turns it back on. Sürüm 11 (karar #135): a Windows Controller on a Mac Host swaps by
// default too. Every other pair keeps the RustDesk rule (off).

import 'package:flutter_hbb/consts.dart' show kPeerPlatformMacOS, kPeerPlatformWindows;

/// Per-peer option that says the user chose the swap themselves (on or off).
const String kSenseSwapKeyDecidedOption = 'sense-swap-key-decided';

/// The swap key option name of the session.
const String kSenseSwapKeyOption = 'allow_swap_key';

/// The pair is Mac Controller / Windows peer (#91) or Windows Controller / Mac peer (#135).
bool senseSwapKeyPair({
  required bool controllerIsMac,
  required bool controllerIsWindows,
  required String? peerPlatform,
}) =>
    (controllerIsMac && peerPlatform == kPeerPlatformWindows) ||
    (controllerIsWindows && peerPlatform == kPeerPlatformMacOS);

/// The default (on) applies to this session: a Mac / Windows pair, no choice yet.
bool senseSwapKeyDefaultApplies({
  required bool controllerIsMac,
  bool controllerIsWindows = false,
  required String? peerPlatform,
  required bool decided,
}) =>
    senseSwapKeyPair(
        controllerIsMac: controllerIsMac,
        controllerIsWindows: controllerIsWindows,
        peerPlatform: peerPlatform) &&
    !decided;

/// Turns the swap on once for a peer the user has not decided about. Returns whether it did.
Future<bool> senseApplySwapKeyDefault({
  required bool controllerIsMac,
  bool controllerIsWindows = false,
  required String? peerPlatform,
  required Future<bool> Function() readDecided,
  required bool Function() isOn,
  required Future<void> Function() turnOn,
}) async {
  if (!senseSwapKeyPair(
      controllerIsMac: controllerIsMac,
      controllerIsWindows: controllerIsWindows,
      peerPlatform: peerPlatform)) {
    return false;
  }
  if (!senseSwapKeyDefaultApplies(
      controllerIsMac: controllerIsMac,
      controllerIsWindows: controllerIsWindows,
      peerPlatform: peerPlatform,
      decided: await readDecided())) {
    return false;
  }
  if (isOn()) return false;
  await turnOn();
  return true;
}
