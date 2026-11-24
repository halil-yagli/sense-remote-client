// Sense Remote (S7, #91): a Mac Controller on a Windows Host swaps Ctrl and Cmd by default
// (`allow_swap_key`), because Mac users press Cmd for the Windows shortcuts. The user can turn
// it off; that choice is remembered for this computer (a per-peer marker), so the default
// never turns it back on. Only a macOS Controller and a Windows peer: every other pair keeps
// the RustDesk rule (off).

import 'package:flutter_hbb/consts.dart' show kPeerPlatformWindows;

/// Per-peer option that says the user chose the swap themselves (on or off).
const String kSenseSwapKeyDecidedOption = 'sense-swap-key-decided';

/// The swap key option name of the session.
const String kSenseSwapKeyOption = 'allow_swap_key';

/// The default (on) applies to this session: Mac Controller, Windows peer, no choice yet.
bool senseSwapKeyDefaultApplies({
  required bool controllerIsMac,
  required String? peerPlatform,
  required bool decided,
}) =>
    controllerIsMac && peerPlatform == kPeerPlatformWindows && !decided;

/// Turns the swap on once for a peer the user has not decided about. Returns whether it did.
Future<bool> senseApplySwapKeyDefault({
  required bool controllerIsMac,
  required String? peerPlatform,
  required Future<bool> Function() readDecided,
  required bool Function() isOn,
  required Future<void> Function() turnOn,
}) async {
  if (!controllerIsMac || peerPlatform != kPeerPlatformWindows) return false;
  if (!senseSwapKeyDefaultApplies(
      controllerIsMac: controllerIsMac,
      peerPlatform: peerPlatform,
      decided: await readDecided())) {
    return false;
  }
  if (isOn()) return false;
  await turnOn();
  return true;
}
