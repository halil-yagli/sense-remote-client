// Sense Remote: the macOS-only steps (YH K1 "Uygulamalar klasörü", YH K6 "macOS izinleri", i07).
//
// Applications folder: macOS can not install from the disk image (or an App Translocation
// copy), so the wizard stops there until the app runs from /Applications.
// Permissions: Apple lets them be approved only at the computer itself, once. A Host needs
// Screen Recording, Accessibility and Input Monitoring; a Controller only Input Monitoring.
// The state is read every second; a granted row turns green by itself.

part of 'sense_install_wizard.dart';

extension _SenseInstallMacSteps on _SenseInstallWizardState {
  // ---- Applications folder ----

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

  (List<Widget>, List<Widget>) _applicationsPage() {
    final checking = _inApplications == null;
    return (
      [
        _header([(_t('apps-title-a'), true), (_t('apps-title-b'), false)], _t('apps-lead')),
        if (checking)
          Row(children: [
            const SenseSpinner(size: 11),
            const SizedBox(width: SenseUi.iconGap),
            _hint(_t('apps-checking'), key: const Key('sense-apps-checking')),
          ])
        else
          _statusBox(
              _appsRechecked ? SenseLevel.hot : SenseLevel.warn,
              _t('apps-outside'),
              [_meta(_t('apps-outside-hint'))],
              key: const Key('sense-apps-outside')),
      ],
      [
        const Spacer(),
        _button(_t('close'), _close, key: const Key('sense-apps-close')),
        _button(_t('apps-recheck'), checking ? null : () => _checkApplications(recheck: true),
            primary: true, key: const Key('sense-apps-recheck')),
      ],
    );
  }

  // ---- Permissions (K6) ----

  List<SenseMacPermission> get _neededPermissions =>
      senseMacPermissionsFor(host: _host, controller: _controller);

  void _startPermissionPoll() {
    _permissionPoll?.cancel();
    unawaited(_pollPermissions());
    _permissionPoll = Timer.periodic(widget.pollInterval, (_) => _pollPermissions());
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
    if (!mounted || read == null || _step != SenseInstallStep.permissions) return;
    final before = _permissions;
    if (before != null && before.sameAs(read)) return;
    _update(() => _permissions = read);
    // The capturing agent started before the permission existed; macOS gives it the new
    // permission only after a restart.
    if (_host && before != null && !before.screenRecording && read.screenRecording) {
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

  /// `skipped`: left with "Yine de devam et" while something is missing.
  void _finishPermissions({required bool skipped}) {
    _permissionPoll?.cancel();
    // Code review K4-4: macOS may keep answering "no Screen Recording" to this running
    // process, so leaving the step restarts the agent of a Host unconditionally.
    if (_host) {
      unawaited(widget.backend.restartAgent().then((error) {
        if (error.isNotEmpty) debugPrint('Sense Remote: agent restart failed: $error');
      }).catchError((_) {}));
    }
    _update(() {
      _permissionsSkipped = skipped;
      if (widget.upgrade != null) {
        _upgradeDone = true;
        _step = SenseInstallStep.upgrade;
      } else {
        _step = SenseInstallStep.done;
      }
    });
  }

  (List<Widget>, List<Widget>) _permissionsPage() {
    final needed = _neededPermissions;
    final state = _permissions;
    final missing = [
      for (final p in needed)
        if (state == null || !state.granted(p)) p,
    ];
    final allGranted = state != null && missing.isEmpty;
    final controllerOnly = _controller && !_host;
    return (
      [
        _header([(_t('perm-title-a'), false), (_t('perm-title-b'), true)],
            _t(needed.length == 1 ? 'perm-lead-one' : 'perm-lead')),
        _box(
          Column(children: [
            for (var i = 0; i < needed.length; i++)
              _permissionRow(needed[i],
                  granted: state?.granted(needed[i]),
                  // Asked in order: the first missing one is the one to do now.
                  current: missing.isNotEmpty && missing.first == needed[i],
                  last: i == needed.length - 1),
          ]),
          key: const Key('sense-perm-box'),
        ),
        if (!allGranted) _hint(_t('perm-hint')),
        if (_agentRestartFailed)
          _statusBox(SenseLevel.warn, _t('perm-agent-failed'), const [],
              key: const Key('sense-perm-agent-error')),
        if (_laterWarned && !allGranted)
          _statusBox(
              SenseLevel.warn,
              _t(controllerOnly ? 'perm-later-warning-controller' : 'perm-later-warning'),
              [
                _meta(_t(controllerOnly
                    ? 'perm-later-warning-controller-hint'
                    : 'perm-later-warning-hint'))
              ],
              key: const Key('sense-perm-warning')),
      ],
      [
        const Spacer(),
        if (allGranted)
          _button(_t('next'), () => _finishPermissions(skipped: false),
              primary: true, key: const Key('sense-perm-next'))
        else
          // The first press explains what will not work (in place), the second one leaves.
          _button(_t(_laterWarned ? 'perm-later-confirm' : 'perm-later'),
              _laterWarned
                  ? () => _finishPermissions(skipped: true)
                  : () => _update(() => _laterWarned = true),
              key: const Key('sense-perm-later')),
      ],
    );
  }

  Widget _permissionRow(SenseMacPermission permission,
      {required bool? granted, required bool current, required bool last}) {
    final name = permission.name;
    final isGranted = granted == true;
    final row = Padding(
      key: Key('sense-perm-$name'),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(permission.label,
                style: SenseTextStyles.of(weight: SenseFontWeight.bold)),
            Text(_t('perm-${permission.textKey}-desc'),
                style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textDim)),
          ]),
        ),
        const SizedBox(width: _L.gap),
        SenseChip(
          key: Key('sense-perm-status-$name'),
          label: _t(granted == null ? 'perm-reading' : isGranted ? 'perm-granted' : 'perm-missing'),
          level: isGranted ? SenseLevel.ok : null,
        ),
        if (granted == false) ...[
          const SizedBox(width: _L.gap),
          _button(_t('perm-open'), () => _openPermission(permission),
              primary: current, key: Key('sense-perm-open-$name')),
        ],
      ]),
    );
    if (last) return row;
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: SenseColors.hover)),
      ),
      child: row,
    );
  }
}
