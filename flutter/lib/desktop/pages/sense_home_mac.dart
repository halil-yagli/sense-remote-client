// Sense Remote (Mac M7, plan 2026-11-21 §4.1): macOS privacy permissions on the
// Sense home screens. Apple lets Screen Recording, Accessibility and Input
// Monitoring be approved only at the computer itself, so a missing one is
// shown in plain words with a button that opens its pane of System Settings.
// These replace the stock English permission / daemon cards. The permission
// model and the system calls are shared with the setup wizard
// (sense_mac_permissions.dart). Nothing here runs on Windows (callers mount
// it on macOS only).

import 'dart:async';

import 'package:flutter/material.dart';

import 'sense_cm_style.dart';
import 'sense_cm_widgets.dart';
import 'sense_home_strings.dart';
import 'sense_install_strings.dart';
import 'sense_mac_permissions.dart';

export 'sense_mac_permissions.dart';

typedef _T = SenseCmTokens;

bool _hosts(SenseHomeRole role) =>
    role == SenseHomeRole.host || role == SenseHomeRole.both;

/// Pure: permissions a role needs, in the order they are asked for.
List<SenseMacPermission> senseMacNeeded(SenseHomeRole role) =>
    senseMacPermissionsFor(
        host: _hosts(role), controller: role == SenseHomeRole.controller);

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

/// Pure: "Ekran Kaydı izni yok" / "Ekran Kaydı ve Erişilebilirlik izinleri yok".
String senseMacMissingText(List<SenseMacPermission> missing) {
  final names = [for (final p in missing) p.label];
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

/// Keeps the missing permissions of [role] up to date (the state changes in
/// System Settings, outside the app) and hands them to [builder].
class SenseMacPermissionWatch extends StatefulWidget {
  const SenseMacPermissionWatch({
    super.key,
    required this.role,
    required this.builder,
    this.system = const SenseMacPermissionBind(),
    this.interval = const Duration(seconds: 2),
    this.onChanged,
  });

  final SenseHomeRole role;
  final Widget Function(BuildContext context, List<SenseMacPermission> missing,
      void Function(SenseMacPermission) open) builder;
  final SenseMacPermissionSystem system;
  final Duration interval;

  /// The notice appeared, changed or went away (the Host window follows its
  /// content height).
  final VoidCallback? onChanged;

  @override
  State<SenseMacPermissionWatch> createState() =>
      _SenseMacPermissionWatchState();
}

class _SenseMacPermissionWatchState extends State<SenseMacPermissionWatch>
    with WidgetsBindingObserver {
  SenseMacPermissions? _permissions;
  Timer? _timer;

  /// The Screen Recording pane was opened from here and the user has not come
  /// back to the app yet.
  bool _screenPaneOpened = false;

  @override
  void initState() {
    super.initState();
    _permissions = _read();
    _timer = Timer.periodic(widget.interval, (_) => _poll());
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  // Code review K4-4: macOS may keep answering "no Screen Recording" to the
  // running process after the permission was given, so the restart does not
  // wait for the answer to change: coming back from the Screen Recording pane
  // restarts the agent of a Host unconditionally.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_screenPaneOpened) return;
    _screenPaneOpened = false;
    _restartAgent();
    _poll();
  }

  void _restartAgent() {
    if (!_hosts(widget.role)) return;
    unawaited(widget.system.restartAgent().catchError((_) => 'failed'));
  }

  SenseMacPermissions? _read() {
    try {
      return widget.system.read();
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
    // Granted some other way (System Settings opened by hand): the agent that
    // captures the screen was started before the permission existed and gets
    // it only after a restart. A permission that was already there needs none.
    if (before != null && !before.screenRecording && now.screenRecording) {
      _screenPaneOpened = false;
      _restartAgent();
    }
  }

  void _open(SenseMacPermission permission) {
    if (permission == SenseMacPermission.screenRecording) {
      _screenPaneOpened = true;
    }
    unawaited(widget.system.open(permission).catchError((_) {}));
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
            // Same words as in the setup wizard.
            label: senseInstallText('perm-open'),
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
