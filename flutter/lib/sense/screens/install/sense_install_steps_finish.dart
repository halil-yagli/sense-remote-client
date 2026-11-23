// Sense Remote: "Kuruldu" (YH K7, i08).

part of 'sense_install_wizard.dart';

extension _SenseInstallFinishStep on _SenseInstallWizardState {
  (List<Widget>, List<Widget>) _donePage() {
    if (widget.upgrade != null) return _upgradeDonePage();
    final projects = _enrolledProjects.isNotEmpty
        ? _enrolledProjects
        : [for (final p in _chosenProjects) p.name];
    final location =
        _enrolledLocation.isNotEmpty ? _enrolledLocation : (_location?.name ?? '');
    final lines = [
      _t('done-lead'),
      _registered
          ? _t('done-panel', {'projects': projects.join(', '), 'location': location})
          : _t('done-panel-skipped'),
      if (_host) ...[_t('done-locked'), _t('done-host')],
      if (_permissionsSkipped) _t('done-permissions-missing'),
    ];
    return (
      [_resultPage(_t('done-title'), lines, key: const Key('sense-done'))],
      [
        const Spacer(),
        _button(_t('close'), () => widget.backend.finish(false),
            key: const Key('sense-finish-close')),
        // A Host has no app window to open (#25: no large UI on the Host).
        if (_controller)
          _button(_t('open-app'), () => widget.backend.finish(true),
              primary: true, key: const Key('sense-finish-open')),
      ],
    );
  }
}
