// Sense Remote: "Bilgisayar bilgisi" (YH K4, i04–i05) and "Özet ve kurulum" (YH K5, i06).
//
// K4: the employee types only the name. Projects are those the panel assigned to them (no new
// project, at least one); the location is one of the panel locations of a chosen project (no
// free text). Both lists are read again every 10 s, so a membership or a location added in the
// panel shows up by itself.

part of 'sense_install_wizard.dart';

extension _SenseInstallInfoSteps on _SenseInstallWizardState {
  (List<Widget>, List<Widget>) _infoPage() {
    final projects = _projects;
    return (
      [
        _header([(_t('info-title-a'), false), (_t('info-title-b'), true)], _t('info-lead')),
        _field(
            _t('name'),
            _textInput(_name,
                hint: _t('name-hint'), maxLength: kSenseMaxName, key: const Key('sense-name'))),
        _field(_t('projects-label', {'n': '${projects?.length ?? 0}'}), _projectsBlock(projects)),
        _field(_t('location-label'), _locationsBlock(projects)),
        _field(
            _t('note'),
            _textInput(_note,
                hint: _t('note-hint'), maxLength: kSenseMaxNote, key: const Key('sense-note'))),
      ],
      [
        _button(_t('back'),
            _installed ? () => _go(SenseInstallStep.summary) : () => _go(SenseInstallStep.role),
            key: const Key('sense-back')),
        _note(_infoReady ? '' : _t('info-missing'), key: const Key('sense-info-missing')),
        _button(_t('next'), _infoReady ? _infoNext : null,
            primary: true, key: const Key('sense-info-next')),
      ],
    );
  }

  Widget _projectsBlock(List<SenseProject>? projects) {
    if (_optionsError.isNotEmpty) {
      final relogin = _optionsError == 'token_invalid';
      final key = 'projects-error-$_optionsError';
      return _statusBox(SenseLevel.hot, _t('projects-error'), [
        _meta(kSenseInstallTr.containsKey(key) ? _t(key) : _t('projects-error-retry')),
        _boxActions([
          if (relogin)
            _button(_t('relogin'), () {
              _cancelLogin();
              _go(SenseInstallStep.account);
            }, primary: true, key: const Key('sense-projects-relogin'))
          else
            _button(_t('retry'), _loadOptions,
                primary: true, key: const Key('sense-projects-retry')),
        ]),
      ], key: const Key('sense-projects-error'));
    }
    if (projects == null) {
      return Row(children: [
        const SenseSpinner(size: 11),
        const SizedBox(width: SenseUi.iconGap),
        _hint(_t('projects-loading')),
      ]);
    }
    if (projects.isEmpty) {
      return _statusBox(SenseLevel.warn, _t('projects-none'), [_meta(_t('projects-none-hint'))],
          key: const Key('sense-projects-none'));
    }
    final full = _selectedIds.length >= kSenseMaxProjects;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final p in projects)
          _chip(
              p.name,
              _selectedIds.contains(p.id),
              full && !_selectedIds.contains(p.id) ? null : () => _toggleProject(p),
              key: Key('sense-project-${p.id}')),
      ]),
      const SizedBox(height: 5),
      _hint(_t(full ? 'projects-max' : 'projects-hint')),
    ]);
  }

  Widget _locationsBlock(List<SenseProject>? projects) {
    if (_selectedIds.isEmpty) {
      return _hint(_t('location-first'), key: const Key('sense-location-first'));
    }
    final locations = _locations;
    if (locations.isEmpty) {
      final first = _chosenProjects.isEmpty ? '' : _chosenProjects.first.name;
      return _statusBox(SenseLevel.warn, _t('location-none'),
          [_meta(_t('location-none-hint', {'project': first}))],
          key: const Key('sense-location-none'));
    }
    final many = _selectedIds.length > 1;
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final l in locations)
        _chip(l.location.name, _locationId == l.location.id,
            () => _update(() => _locationId = l.location.id),
            prefix: many ? l.project.name : null, key: Key('sense-location-${l.location.id}')),
    ]);
  }

  // ---- Summary and install (K5) ----

  String get _roleLabel => _host && _controller
      ? '${_t('host')} + ${_t('controller')}'
      : _host
          ? _t('host')
          : _t('controller');

  (List<Widget>, List<Widget>) _summaryPage() {
    final projectNames = [for (final p in _chosenProjects) p.name];
    final tiles = <(String, String, SenseLevel?)>[
      (_t('sum-account'), _login.email.isEmpty ? _t('none') : _login.email, null),
      (_t('sum-role'), _roleLabel, null),
      (_t('sum-computer'), _name.text.trim(), null),
      (_t('sum-projects'), projectNames.isEmpty ? _t('none') : projectNames.join(', '), null),
      (_t('sum-location'), _location?.name ?? _t('none'), null),
      (_t('sum-update'), _t('sum-update-value'), null),
      (_t('sum-password'), _t('sum-password-value'), null),
    ];
    final registering = _installed && !_registered;
    return (
      [
        _header([(_t('summary-title'), true)],
            _t(_host ? 'summary-lead' : 'summary-lead-controller')),
        _box(Padding(padding: const EdgeInsets.only(top: 8), child: _tiles(tiles)),
            key: const Key('sense-summary-tiles')),
        if (!widget.mac && !_installed) _advanced(),
        ..._installState(),
      ],
      [
        _button(_t('back'), _busy || _installed ? null : () => _go(SenseInstallStep.info),
            key: const Key('sense-back')),
        _note(_t(widget.mac ? 'install-note-mac' : 'install-note')),
        if (registering)
          _button(_t('register-save'), _enrolling || _waitLeft > 0 ? null : _enroll,
              primary: true, key: const Key('sense-register'))
        else
          _button(_t('install'), _busy || _installed ? null : _install,
              primary: true, key: const Key('sense-install')),
      ],
    );
  }

  /// K5 "Gelişmiş" (Windows only): closed category, settings in place.
  Widget _advanced() {
    final summary = [
      _path,
      if (_startMenu) _t('advanced-start-menu'),
      if (_desktopIcon) _t('advanced-desktop'),
      if (_printer) _t('advanced-printer'),
    ].join(' · ');
    final enabled = !_busy;
    return SenseCategory(
      headerKey: const Key('sense-advanced'),
      title: _t('advanced'),
      summary: summary,
      density: SenseAccordionDensity.page,
      open: _advancedOpen,
      onToggle: () => _update(() => _advancedOpen = !_advancedOpen),
      builder: (_) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SenseSettingRow(
          label: _t('install-path'),
          description: _path,
          control: _button(_t('change-path'),
              enabled && widget.onPickPath != null ? _pickPath : null,
              key: const Key('sense-change-path')),
        ),
        if (_pathWarned == _path)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: _statusBox(SenseLevel.warn, _t('path-not-empty'),
                [_meta(_t('path-not-empty-hint', {'path': _path}))],
                key: const Key('sense-path-warning')),
          ),
        SenseToggleRow(
          key: const Key('sense-start-menu'),
          label: _t('start-menu'),
          value: _startMenu,
          onChanged: enabled ? (v) => _update(() => _startMenu = v) : null,
        ),
        SenseToggleRow(
          key: const Key('sense-desktop-icon'),
          label: _t('desktop-icon'),
          value: _desktopIcon,
          onChanged: enabled ? (v) => _update(() => _desktopIcon = v) : null,
        ),
        SenseToggleRow(
          key: const Key('sense-printer'),
          label: _t('printer'),
          value: _printer,
          onChanged: enabled ? (v) => _update(() => _printer = v) : null,
          last: true,
        ),
      ]),
    );
  }

  /// Progress and errors in place (K5): no window except the UAC prompt / macOS password.
  List<Widget> _installState() {
    if (_installing) {
      return [
        _progress(_t(widget.mac ? 'installing-mac' : 'installing'),
            key: const Key('sense-installing'))
      ];
    }
    if (_enrolling) {
      return [_progress(_t('registering'), key: const Key('sense-registering'))];
    }
    if (_installError.isNotEmpty) {
      final cancelled = _installError == 'cancelled';
      final hint = cancelled
          ? _t(widget.mac ? 'error-cancelled-hint-mac' : 'error-cancelled-hint')
          : _installError == 'failed'
              ? _t('error-failed-hint')
              : _t('error-$_installError');
      return [
        _statusBox(SenseLevel.hot, _t(cancelled ? 'error-cancelled' : 'error-failed'),
            [_meta(hint)],
            key: const Key('sense-install-error')),
      ];
    }
    if (_enrollError.isNotEmpty) {
      final code = _enrollError;
      final action = senseEnrollAction(code);
      final key = 'enroll-$code';
      final text = kSenseInstallTr.containsKey(key) ? _t(key) : _t('enroll-other');
      return [
        _statusBox(SenseLevel.hot, _t('register-failed'), [
          _meta(text, key: const Key('sense-enroll-error-text')),
          _boxActions([
            if (action == SenseEnrollAction.retry || action == SenseEnrollAction.wait)
              _button(
                  action == SenseEnrollAction.wait && _waitLeft > 0
                      ? '${_t('retry')} ($_waitLeft ${_t('seconds-short')})'
                      : _t('retry'),
                  _waitLeft > 0 ? null : _enroll,
                  primary: true,
                  key: const Key('sense-enroll-retry')),
            if (action == SenseEnrollAction.relogin || code == 'permission_denied')
              _button(_t('relogin'), _reloginForRegister,
                  primary: action == SenseEnrollAction.relogin,
                  key: const Key('sense-enroll-relogin')),
            if (action == SenseEnrollAction.edit)
              _button(_t('edit-details'), _editForRegister,
                  primary: true, key: const Key('sense-enroll-edit')),
            _button(_t('skip-register'), _skipRegister, key: const Key('sense-enroll-skip')),
          ]),
        ], key: const Key('sense-enroll-error')),
      ];
    }
    return const [];
  }
}
