// Sense Remote (Mac M7, plan 2026-11-21 §4.1): macOS privacy permissions on the
// Sense home screens. Apple lets Screen Recording, Accessibility and Input
// Monitoring be approved only at the computer itself, so a missing one is
// shown in plain words with a button that opens its pane of System Settings.
// These replace the stock English permission / daemon cards on a Sense
// installation. A Host needs all three; a Controller only Input Monitoring.
// Nothing here runs on Windows (callers mount it on macOS only).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/platform_model.dart';
import 'sense_cm_style.dart';
import 'sense_cm_widgets.dart';
import 'sense_home_strings.dart';

typedef _T = SenseCmTokens;

enum SenseMacPermission { screenRecording, accessibility, inputMonitoring }

class SenseMacPermissions {
  const SenseMacPermissions({
    required this.screenRecording,
    required this.accessibility,
    required this.inputMonitoring,
  });

  final bool screenRecording;
  final bool accessibility;
  final bool inputMonitoring;

  bool granted(SenseMacPermission p) {
    switch (p) {
      case SenseMacPermission.screenRecording:
        return screenRecording;
      case SenseMacPermission.accessibility:
        return accessibility;
      case SenseMacPermission.inputMonitoring:
        return inputMonitoring;
    }
  }

  bool sameAs(SenseMacPermissions o) =>
      screenRecording == o.screenRecording &&
      accessibility == o.accessibility &&
      inputMonitoring == o.inputMonitoring;
}

/// Pure: permissions a role needs, in the order they are asked for.
List<SenseMacPermission> senseMacNeeded(SenseHomeRole role) {
  switch (role) {
    case SenseHomeRole.host:
    case SenseHomeRole.both:
      return SenseMacPermission.values;
    case SenseHomeRole.controller:
      return const [SenseMacPermission.inputMonitoring];
    case SenseHomeRole.none:
      return const [];
  }
}

/// Pure: needed permissions that are not granted.
List<SenseMacPermission> senseMacMissing(
        SenseHomeRole role, SenseMacPermissions permissions) =>
    [
      for (final p in senseMacNeeded(role))
        if (!permissions.granted(p)) p,
    ];

/// Pure: without Screen Recording or Accessibility the team can not see or
/// use this computer; Input Monitoring alone only affects keyboard shortcuts.
bool senseMacBlocksHost(List<SenseMacPermission> missing) =>
    missing.contains(SenseMacPermission.screenRecording) ||
    missing.contains(SenseMacPermission.accessibility);

String senseMacPermissionName(SenseMacPermission p) {
  switch (p) {
    case SenseMacPermission.screenRecording:
      return senseHomeText('mac_perm_screen');
    case SenseMacPermission.accessibility:
      return senseHomeText('mac_perm_accessibility');
    case SenseMacPermission.inputMonitoring:
      return senseHomeText('mac_perm_input');
  }
}

/// Pure: "Ekran Kaydı izni yok" / "Ekran Kaydı ve Erişilebilirlik izinleri yok".
String senseMacMissingText(List<SenseMacPermission> missing) {
  final names = missing.map(senseMacPermissionName).toList();
  if (names.isEmpty) return '';
  if (names.length == 1) {
    return senseHomeText('mac_perm_missing_one', {'name': names.single});
  }
  final head = names.sublist(0, names.length - 1).join(', ');
  return senseHomeText('mac_perm_missing_many',
      {'names': '$head${senseHomeText('mac_perm_and')}${names.last}'});
}

/// Pure: what the missing permissions cost, in one sentence.
String senseMacMissingNote(List<SenseMacPermission> missing) =>
    senseHomeText(senseMacBlocksHost(missing)
        ? 'mac_perm_note_host'
        : 'mac_perm_note_input');

/// Pane of System Settings › Privacy & Security for a permission.
String senseMacSettingsUrl(SenseMacPermission p) {
  const base = 'x-apple.systempreferences:com.apple.preference.security';
  switch (p) {
    case SenseMacPermission.screenRecording:
      return '$base?Privacy_ScreenCapture';
    case SenseMacPermission.accessibility:
      return '$base?Privacy_Accessibility';
    case SenseMacPermission.inputMonitoring:
      return '$base?Privacy_ListenEvent';
  }
}

/// System side of the permission notice; tests pass a fake.
abstract class SenseMacPermissionBackend {
  /// Current state, read without a system prompt.
  SenseMacPermissions read();

  /// Opens the pane of [permission] in System Settings.
  Future<void> open(SenseMacPermission permission);

  /// Restarts the background agent; "" on success.
  Future<String> restartAgent();
}

class SenseMacPermissionBind implements SenseMacPermissionBackend {
  const SenseMacPermissionBind();

  @override
  SenseMacPermissions read() => SenseMacPermissions(
        screenRecording: bind.mainIsCanScreenRecording(prompt: false),
        accessibility: bind.mainIsProcessTrusted(prompt: false),
        inputMonitoring: bind.mainIsCanInputMonitoring(prompt: false),
      );

  @override
  Future<void> open(SenseMacPermission permission) async {
    // The request puts Sense Remote into the list of that pane (macOS shows
    // its own prompt only once per app, so the pane is opened as well).
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
    await launchUrl(Uri.parse(senseMacSettingsUrl(permission)),
        mode: LaunchMode.externalApplication);
  }

  @override
  Future<String> restartAgent() => bind.installSenseRestartAgent();
}

/// Keeps the missing permissions of [role] up to date (the state changes in
/// System Settings, outside the app) and hands them to [builder].
class SenseMacPermissionWatch extends StatefulWidget {
  const SenseMacPermissionWatch({
    super.key,
    required this.role,
    required this.builder,
    this.backend = const SenseMacPermissionBind(),
    this.interval = const Duration(seconds: 2),
    this.onChanged,
  });

  final SenseHomeRole role;
  final Widget Function(BuildContext context, List<SenseMacPermission> missing,
      void Function(SenseMacPermission) open) builder;
  final SenseMacPermissionBackend backend;
  final Duration interval;

  /// The notice appeared, changed or went away (the Host window follows its
  /// content height).
  final VoidCallback? onChanged;

  @override
  State<SenseMacPermissionWatch> createState() =>
      _SenseMacPermissionWatchState();
}

class _SenseMacPermissionWatchState extends State<SenseMacPermissionWatch> {
  SenseMacPermissions? _permissions;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _permissions = _read();
    _timer = Timer.periodic(widget.interval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  SenseMacPermissions? _read() {
    try {
      return widget.backend.read();
    } catch (_) {
      return null;
    }
  }

  void _poll() {
    final now = _read();
    if (!mounted || now == null) return;
    final before = _permissions;
    if (before != null && before.sameAs(now)) return;
    setState(() => _permissions = now);
    widget.onChanged?.call();
    // The agent that captures the screen was started before the permission
    // existed; macOS gives it the new permission only after a restart. Only on
    // a change seen here: a permission that was already there needs none.
    final hosts = widget.role == SenseHomeRole.host ||
        widget.role == SenseHomeRole.both;
    if (hosts &&
        before != null &&
        !before.screenRecording &&
        now.screenRecording) {
      unawaited(widget.backend.restartAgent().catchError((_) => 'failed'));
    }
  }

  void _open(SenseMacPermission permission) {
    unawaited(widget.backend.open(permission).catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    final permissions = _permissions;
    // Unreadable state: show nothing rather than a made-up warning.
    final missing = permissions == null
        ? const <SenseMacPermission>[]
        : senseMacMissing(widget.role, permissions);
    return widget.builder(context, missing, _open);
  }
}

/// Pure view: what is missing, what it costs, and the way to fix it. Empty
/// when nothing is missing. [showTitle] is off where the caller already says
/// what is missing (the status line of the Host home).
class SenseMacPermissionNotice extends StatelessWidget {
  const SenseMacPermissionNotice({
    super.key,
    required this.missing,
    required this.onOpen,
    this.showTitle = true,
  });

  final List<SenseMacPermission> missing;
  final void Function(SenseMacPermission) onOpen;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    if (missing.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(senseMacMissingText(missing),
                key: const Key('sense-mac-perm-title'),
                style: _T.text(size: 12, weight: FontWeight.w600)),
          ),
        Text(senseMacMissingNote(missing),
            key: const Key('sense-mac-perm-note'),
            style: _T.text(size: 11, color: _T.soft)),
        const SizedBox(height: 4),
        SenseCmTextButton(
            key: const Key('sense-mac-perm-open'),
            label: senseHomeText('mac_perm_open'),
            strong: true,
            // One pane at a time, in the order the permissions are needed;
            // the notice moves on to the next one once this is granted.
            onTap: () => onOpen(missing.first)),
      ],
    );
  }
}

/// Card for the left pane of the Controller and Host + Controller home.
class SenseMacPermissionCardView extends StatelessWidget {
  const SenseMacPermissionCardView(
      {super.key, required this.missing, required this.onOpen});

  final List<SenseMacPermission> missing;
  final void Function(SenseMacPermission) onOpen;

  @override
  Widget build(BuildContext context) {
    if (missing.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('sense-mac-perm-card'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 6),
      decoration: BoxDecoration(
        color: _T.field,
        borderRadius: BorderRadius.circular(_T.radiusCard),
        border: Border.all(color: _T.border),
      ),
      child: SenseMacPermissionNotice(missing: missing, onOpen: onOpen),
    );
  }
}

/// Binds the card to the live permission state.
class SenseMacPermissionCard extends StatelessWidget {
  const SenseMacPermissionCard({super.key, required this.role});

  final SenseHomeRole role;

  @override
  Widget build(BuildContext context) => SenseMacPermissionWatch(
        role: role,
        builder: (_, missing, open) =>
            SenseMacPermissionCardView(missing: missing, onOpen: open),
      );
}
