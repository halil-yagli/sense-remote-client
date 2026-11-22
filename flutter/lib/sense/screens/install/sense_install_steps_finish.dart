// Sense Remote: step 4, panel registration and done of the Sense setup wizard (part of sense_install_wizard.dart,
// code review K3-6; behaviour unchanged).

part of 'sense_install_wizard.dart';

extension _SenseInstallFinishSteps on _SenseInstallWizardState {
  // ---- Step 4: summary ----

  Widget _summaryPage() {
    final r = _installRequest();
    final note = _note.text.trim();
    final controllerOnly = _controller && !_host;
    String orNone(String v) => v.isEmpty ? _t('none') : v;
    final projects = [
      for (final p in _chosenProjects) p.name,
      for (final name in _newProjects) '$name (${_t('new-tag')})',
    ].join(', ');
    final rows = <(String, String)>[
      (_t('account'), orNone(_login.email)),
      (_t('role'), senseRoleLabel(_host, _controller)),
      (_t('name'), r.name),
      (_t('projects'), orNone(projects)),
      (_t('location'), orNone(r.location)),
      if (note.isNotEmpty) (_t('note').split(' (').first, note),
      (_t('update'), _t('update-value')),
      (_t('password'), _t('password-value')),
    ];
    return _page([
      _heading(_t('summary-title'), '', boldFirst: true),
      _lead(_t(controllerOnly ? 'summary-lead-controller' : 'summary-lead')),
      Container(
        key: const Key('sense-summary'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SenseTokens.line),
        ),
        child: Column(
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(row.$1,
                          style: const TextStyle(
                              fontSize: 13, color: SenseTokens.muted)),
                    ),
                    Expanded(
                        child: Text(row.$2,
                            style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      // Sense Remote (Mac M3): folder and shortcut options are Windows only.
      if (!_installed && !widget.mac)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('sense-advanced'),
          onPressed:
              _installing ? null : () => _update(() => _advanced = !_advanced),
          style: TextButton.styleFrom(foregroundColor: SenseTokens.muted),
          icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more,
              size: 18),
          label: Text(_t('advanced'), style: const TextStyle(fontSize: 12)),
        ),
      ),
      if (_advanced && !_installed && !widget.mac) _advancedOptions(),
      if (_installing)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _progress(_t(widget.mac ? 'installing-mac' : 'installing')),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _errorRow(_error!, key: const Key('sense-error')),
        ),
    ], [
      _secondaryButton(
          _t('back'), _installing ? null : () => _go(SenseInstallStep.info)),
      const Spacer(),
      // Already installed (details fixed after a refused registration): register only.
      _installed
          ? _primaryButton(_t('register-save'), _registerAgain,
              key: const Key('sense-register-save'))
          : _primaryButton(_t('install'), _installing ? null : _install,
              key: const Key('sense-install')),
    ]);
  }

  Widget _advancedOptions() {
    Widget check(String label, bool value, ValueChanged<bool> onChanged) {
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _installing ? null : () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Checkbox(
                value: value,
                visualDensity:
                    const VisualDensity(horizontal: -4, vertical: -4),
                side: const BorderSide(color: SenseTokens.border),
                onChanged: _installing ? null : (v) => onChanged(v ?? false),
              ),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SenseTokens.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_t('install-path'),
              style: const TextStyle(fontSize: 12, color: SenseTokens.muted)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(_path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
              if (widget.onPickPath != null)
                TextButton(
                  onPressed: _installing
                      ? null
                      : () async {
                          final picked = await widget.onPickPath!(_path);
                          if (picked != null && mounted) {
                            _update(() => _path = picked);
                          }
                        },
                  style:
                      TextButton.styleFrom(foregroundColor: SenseTokens.white),
                  child: Text(_t('change-path')),
                ),
            ],
          ),
          const SizedBox(height: 6),
          check(_t('start-menu'), _startMenu,
              (v) => _update(() => _startMenu = v)),
          check(_t('desktop-icon'), _desktopIcon,
              (v) => _update(() => _desktopIcon = v)),
          check(_t('printer'), _printer, (v) => _update(() => _printer = v)),
        ],
      ),
    );
  }

  // ---- Panel registration (after installing) ----

  /// The one action that can fix the panel's answer (contract `EnrollErrorCode`).
  Widget? _registerAction() {
    switch (senseEnrollAction(_enrollError)) {
      case SenseEnrollAction.relogin:
        return _primaryButton(_t('relogin'), _reloginForRegister,
            key: const Key('sense-relogin-register'));
      case SenseEnrollAction.edit:
        return _primaryButton(_t('edit-details'), _editForRegister,
            key: const Key('sense-edit-register'));
      case SenseEnrollAction.wait:
        return _primaryButton(
            _waitLeft > 0
                ? '${_t('retry')} ($_waitLeft ${_t('seconds-short')})'
                : _t('retry'),
            _waitLeft > 0 ? null : _enroll,
            key: const Key('sense-retry-register'));
      case SenseEnrollAction.retry:
        return _primaryButton(_t('retry'), _enroll,
            key: const Key('sense-retry-register'));
      case SenseEnrollAction.none:
        return null;
    }
  }

  Widget _registerPage() {
    final failed = !_enrolling && _enrollError.isNotEmpty;
    final action = failed ? _registerAction() : null;
    return _page([
      _heading(_t('register-title-a'), _t('register-title-b')),
      const SizedBox(height: 20),
      if (_enrolling) _progress(_t('registering')),
      if (failed) ...[
        Text(_t('register-failed'),
            key: const Key('sense-register-failed'),
            style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 10),
        _errorRow(
            kSenseInstallTr['enroll-$_enrollError'] ?? _t('enroll-other'),
            key: const Key('sense-enroll-error')),
      ],
    ], [
      const Spacer(),
      if (failed) ...[
        _secondaryButton(_t('skip-register'), _skipRegister,
            key: const Key('sense-skip-register')),
        if (action != null) ...[const SizedBox(width: 10), action],
      ],
    ]);
  }

  // ---- Done ----

  String _doneText() {
    final lines = <String>[_t('done-lead')];
    if (!_registered) {
      lines.add(_t('done-pending'));
    } else if (_enrolledProjects.isEmpty) {
      lines.add(_t('done-panel-none'));
    } else {
      final key = _enrolledProjects.length == 1
          ? 'done-panel-project'
          : 'done-panel-projects';
      lines.add(_t(key).replaceAll('{projects}', _enrolledProjects.join(', ')));
    }
    if (_host) lines.add(_t('done-lead-locked'));
    if (_host && !_controller) lines.add(_t('done-host-background'));
    // Sense Remote (Mac M3): left the permissions step with "Daha sonra".
    if (_permissionsSkipped) lines.add(_t('done-permissions-missing'));
    return lines.join(' ');
  }

  Widget _donePage() {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                      gradient: SenseTokens.gradient, shape: BoxShape.circle),
                  child: const Icon(Icons.check,
                      size: 30, color: SenseTokens.white),
                ),
                const SizedBox(height: 16),
                _heading(_t('done-title'), '', boldFirst: true),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Text(
                    _doneText(),
                    key: const Key('sense-done'),
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 13, color: SenseTokens.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Sense Remote: a Host has no large window (decision: no large UI on the Host), so it
        // only closes; Controller and Host + Controller open the Sense home screen.
        Row(
          children: [
            const Spacer(),
            if (_controller) ...[
              _secondaryButton(_t('close'), () => widget.backend.finish(false),
                  key: const Key('sense-finish-close')),
              const SizedBox(width: 10),
              _primaryButton(_t('open-app'), () => widget.backend.finish(true),
                  key: const Key('sense-finish-open')),
            ] else
              _primaryButton(_t('close'), () => widget.backend.finish(false),
                  key: const Key('sense-finish-close')),
          ],
        ),
      ],
    );
  }
}
