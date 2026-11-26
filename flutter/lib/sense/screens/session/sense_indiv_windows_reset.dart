// Sense Remote (S9, #97): an older build hid the "Her ekranı ayrı pencerede aç" switch while ghost
// mode was on, so some computers kept the value "Y" without the user wanting it. Once per peer
// that value is reset to off; a per-peer marker records it. After that the user's own choice
// (switch on) is never touched again.

/// RustDesk session option behind the switch.
const String kSenseIndivWindowsOption = 'displays_as_individual_windows';

/// Per-peer marker: the Sürüm 9 reset was already done for this computer.
const String kSenseIndivResetOption = 'sense-s9-indiv-reset';

/// Resets "Y" to "N" once. Returns whether it did. The marker is written even when the value
/// was not "Y", so a later user choice of "Y" survives.
Future<bool> senseApplyIndivWindowsReset({
  required Future<bool> Function() readDone,
  required Future<String> Function() readValue,
  required Future<void> Function(String value) writeValue,
  required Future<void> Function() writeDone,
}) async {
  if (await readDone()) return false;
  final reset = (await readValue()) == 'Y';
  if (reset) await writeValue('N');
  await writeDone();
  return reset;
}
