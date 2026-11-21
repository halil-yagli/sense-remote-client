// Sense Remote (Mac, code review K4-5): the macOS privacy permissions in one
// place, shared by the setup wizard (M3) and the home screens (M7): which
// permissions a role needs, their state, their names, the pane of System
// Settings of each, and the calls into the system (read, open, restart the
// agent). Nothing here runs on Windows.

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/platform_model.dart';
import 'sense_install_strings.dart';

/// The macOS privacy permissions Sense Remote asks for, in the order they are asked.
enum SenseMacPermission {
  screenRecording('screen', 'Privacy_ScreenCapture'),
  accessibility('accessibility', 'Privacy_Accessibility'),
  inputMonitoring('input', 'Privacy_ListenEvent');

  const SenseMacPermission(this.textKey, this.pane);

  /// Text keys `perm-<textKey>` / `perm-<textKey>-desc` (sense_install_strings.dart).
  final String textKey;
  final String pane;

  /// The pane of System Settings > Privacy & Security for this permission.
  String get settingsUrl =>
      'x-apple.systempreferences:com.apple.preference.security?$pane';

  /// Name as macOS shows it ("Ekran Kaydı").
  String get label => senseInstallText('perm-$textKey');
}

/// What a role needs: a Host is watched and controlled (all three); a Controller only sends
/// its own keyboard input (Input Monitoring).
List<SenseMacPermission> senseMacPermissionsFor(
        {required bool host, required bool controller}) =>
    host
        ? SenseMacPermission.values
        : controller
            ? const [SenseMacPermission.inputMonitoring]
            : const [];

/// State of the three permissions, read without a system prompt.
class SenseMacPermissions {
  const SenseMacPermissions({
    this.screenRecording = false,
    this.accessibility = false,
    this.inputMonitoring = false,
  });

  final bool screenRecording;
  final bool accessibility;
  final bool inputMonitoring;

  bool granted(SenseMacPermission permission) {
    switch (permission) {
      case SenseMacPermission.screenRecording:
        return screenRecording;
      case SenseMacPermission.accessibility:
        return accessibility;
      case SenseMacPermission.inputMonitoring:
        return inputMonitoring;
    }
  }

  bool sameAs(SenseMacPermissions other) =>
      screenRecording == other.screenRecording &&
      accessibility == other.accessibility &&
      inputMonitoring == other.inputMonitoring;
}

/// System side of the permissions; tests pass a fake.
abstract class SenseMacPermissionSystem {
  /// Current state, read without a system prompt.
  SenseMacPermissions read();

  /// Asks macOS for the permission and opens its pane in System Settings.
  Future<void> open(SenseMacPermission permission);

  /// Restarts the background agent (it gets a new Screen Recording permission only after a
  /// restart); "" on success.
  Future<String> restartAgent();
}

/// The one binding to the native side (the same checks the heartbeat reports).
class SenseMacPermissionBind implements SenseMacPermissionSystem {
  const SenseMacPermissionBind();

  @override
  SenseMacPermissions read() => SenseMacPermissions(
        screenRecording: bind.mainIsCanScreenRecording(prompt: false),
        accessibility: bind.mainIsProcessTrusted(prompt: false),
        inputMonitoring: bind.mainIsCanInputMonitoring(prompt: false),
      );

  @override
  Future<void> open(SenseMacPermission permission) async {
    // The request puts Sense Remote into the list of that pane; macOS shows its own prompt
    // only once per app, so the pane is opened as well (later presses would do nothing).
    switch (permission) {
      case SenseMacPermission.screenRecording:
        bind.mainIsCanScreenRecording(prompt: true);
        break;
      case SenseMacPermission.accessibility:
        bind.mainIsProcessTrusted(prompt: true);
        break;
      case SenseMacPermission.inputMonitoring:
        bind.mainIsCanInputMonitoring(prompt: true);
        break;
    }
    try {
      await launchUrl(Uri.parse(permission.settingsUrl),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      debugPrint('Sense Remote: failed to open System Settings');
    }
  }

  @override
  Future<String> restartAgent() => bind.installSenseRestartAgent();
}
