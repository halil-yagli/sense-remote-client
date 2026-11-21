// Sense Remote (Mac M3, plan 2026-11-21 §4.1): the two macOS-only steps of the Sense setup
// wizard (part of sense_install_wizard.dart).
//
// 0. Applications folder: macOS can not install from the disk image (or from an App
//    Translocation copy), so the wizard stops there until the app runs from /Applications.
// 6. Privacy permissions: Apple lets these be approved only at the computer itself, once. A
//    Host needs Screen Recording, Accessibility and Input Monitoring; a Controller only Input
//    Monitoring. Each row shows the live state and opens its pane of System Settings.

part of 'sense_install_wizard.dart';

extension _SenseInstallMacSteps on _SenseInstallWizardState {
  // ---- Step 0: Applications folder ----

  Future<void> _checkApplications({bool recheck = false}) async {
    bool inside;
    try {
      inside = await widget.backend.inApplications();
    } catch (_) {
      inside = false;
    }
    if (!mounted) return;
    _update(() {
      _inApplications = inside;
      _appsRechecked = recheck && !inside;
      if (inside && _step == SenseInstallStep.applications) {
        _step = SenseInstallStep.account;
      }
    });
  }

  Widget _applicationsPage() {
    final checking = _inApplications == null;
    return _page([
      _heading(_t('apps-title-a'), _t('apps-title-b'), boldFirst: true),
      _lead(_t('apps-lead')),
      if (checking)
        _statusLine(Icons.sync, _t('apps-checking'),
            key: const Key('sense-apps-checking'))
      else ...[
        Text(_t('apps-detail'),
            key: const Key('sense-apps-detail'),
            style: const TextStyle(fontSize: 13, color: SenseTokens.soft)),
        if (_appsRechecked)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _errorRow(_t('apps-still-outside'),
                key: const Key('sense-apps-outside')),
          ),
      ],
    ], [
      _secondaryButton(_t('close'), _close, key: const Key('sense-apps-close')),
      const Spacer(),
      _primaryButton(_t('apps-recheck'),
          checking ? null : () => _checkApplications(recheck: true),
          key: const Key('sense-apps-recheck')),
    ]);
  }

  // ---- Step 6: privacy permissions ----

  List<SenseMacPermission> get _neededPermissions =>
      senseMacPermissionsFor(host: _host, controller: _controller);

  void _startPermissionPoll() {
    _permissionPoll?.cancel();
    unawaited(_pollPermissions());
    _permissionPoll =
        Timer.periodic(widget.pollInterval, (_) => _pollPermissions());
  }

  Future<void> _pollPermissions() async {
    if (_permissionPolling) return;
    _permissionPolling = true;
    SenseMacPermissions? now;
    try {
      now = await widget.backend.macPermissions();
    } catch (_) {
      now = null;
    } finally {
      _permissionPolling = false;
    }
    final read = now;
    if (!mounted || read == null || _step != SenseInstallStep.permissions) {
      return;
    }
    final before = _permissions;
    if (before != null && before.sameAs(read)) return;
    _update(() => _permissions = read);
    // The agent that captures the screen was started before the permission existed; macOS
    // gives it the new permission only after a restart. Only on a change seen here: a
    // permission that was already there needs no restart.
    if (_host &&
        before != null &&
        !before.screenRecording &&
        read.screenRecording) {
      String error;
      try {
        error = await widget.backend.restartAgent();
      } catch (_) {
        error = 'failed';
      }
      if (mounted) _update(() => _agentRestartFailed = error.isNotEmpty);
    }
  }

  Future<void> _openPermission(SenseMacPermission permission) async {
    try {
      await widget.backend.openMacPermission(permission);
    } catch (_) {
      // The row stays "Bekleniyor"; the button can be pressed again.
    }
  }

  /// `skipped`: left with "Daha sonra" while something is missing (the done page says so).
  void _finishPermissions({required bool skipped}) {
    _permissionPoll?.cancel();
    _update(() {
      _permissionsSkipped = skipped;
      _step = SenseInstallStep.done;
    });
  }

  Widget _permissionsPage() {
    final needed = _neededPermissions;
    final state = _permissions;
    final missing = [
      for (final p in needed)
        if (state == null || !state.granted(p)) p,
    ];
    final allGranted = state != null && missing.isEmpty;
    final controllerOnly = _controller && !_host;
    return _page([
      _heading(_t('perm-title-a'), _t('perm-title-b')),
      _lead(_t(controllerOnly ? 'perm-lead-controller' : 'perm-lead')),
      for (var i = 0; i < needed.length; i++)
        _permissionRow(
          i + 1,
          needed[i],
          granted: state?.granted(needed[i]),
          // They are asked in order: the first missing one is the one to do now.
          current: missing.isNotEmpty && missing.first == needed[i],
        ),
      if (allGranted)
        _statusLine(Icons.check_circle_outline, _t('perm-all-granted'),
            key: const Key('sense-perm-all-granted'))
      else if (state != null)
        Text(_t('perm-open-hint'),
            style: const TextStyle(fontSize: 12, color: SenseTokens.muted)),
      if (_agentRestartFailed)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _errorRow(_t('perm-agent-error'),
              key: const Key('sense-perm-agent-error')),
        ),
      if (_laterWarned && !allGranted)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _errorRow(
              _t(controllerOnly
                  ? 'perm-later-warning-controller'
                  : 'perm-later-warning'),
              key: const Key('sense-perm-warning')),
        ),
    ], [
      const Spacer(),
      if (allGranted)
        _primaryButton(_t('next'), () => _finishPermissions(skipped: false),
            key: const Key('sense-perm-next'))
      else
        // "Daha sonra" only after the warning was shown: the first press explains what
        // will not work, the second one leaves.
        _secondaryButton(
            _t(_laterWarned ? 'perm-later-confirm' : 'perm-later'),
            _laterWarned
                ? () => _finishPermissions(skipped: true)
                : () => _update(() => _laterWarned = true),
            key: const Key('sense-perm-later')),
    ]);
  }

  Widget _permissionRow(int number, SenseMacPermission permission,
      {required bool? granted, required bool current}) {
    final name = permission.name;
    final isGranted = granted == true;
    final status = granted == null
        ? _t('perm-reading')
        : isGranted
            ? _t('perm-granted')
            : _t('perm-missing');
    return Container(
      key: Key('sense-perm-$name'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(SenseTokens.radiusCard),
        border: Border.all(
            color: current ? SenseTokens.soft : SenseTokens.line),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: isGranted
                ? const BoxDecoration(
                    gradient: SenseTokens.gradient, shape: BoxShape.circle)
                : BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: SenseTokens.border)),
            child: isGranted
                ? const Icon(Icons.check, size: 13, color: SenseTokens.white)
                : Text('$number',
                    style: const TextStyle(
                        fontSize: 11, color: SenseTokens.muted)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(_t('perm-${permission.textKey}'),
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    Text(status,
                        key: Key('sense-perm-status-$name'),
                        style: TextStyle(
                            fontSize: 12,
                            color: isGranted
                                ? SenseTokens.white
                                : SenseTokens.muted)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(_t('perm-${permission.textKey}-desc'),
                    style: const TextStyle(
                        fontSize: 12, color: SenseTokens.muted)),
              ],
            ),
          ),
          if (granted == false) ...[
            const SizedBox(width: 10),
            current
                ? _primaryButton(
                    _t('perm-open'), () => _openPermission(permission),
                    key: Key('sense-perm-open-$name'))
                : _secondaryButton(
                    _t('perm-open'), () => _openPermission(permission),
                    key: Key('sense-perm-open-$name')),
          ],
        ],
      ),
    );
  }
}
