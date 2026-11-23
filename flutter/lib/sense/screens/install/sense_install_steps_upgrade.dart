// Sense Remote: move from an older version (YH K7 "geçiş", i09; update plan 2026-11-21 §8, U7).
//
// Windows: the new setup file finds an older installed version and shows the short
// "Güncelleme" screen; [Güncelle] asks for the administrator and runs the setup file with
// `--sense-upgrade-local` (backup + guard + update, `src/sense/update/manual.rs`). Same or
// newer installed: "Bu bilgisayarda Sürüm N kurulu", nothing is done (no downgrade).
// macOS: the new app was dragged over the old one; "Geçişi tamamla" asks for the administrator
// password (bundle to root, daemon and agent restarted), then the permissions step.
// Neither platform signs in or registers again: the backend's login and enroll are never used.

part of 'sense_install_wizard.dart';

/// What the setup file does on a computer that already has a Sense role.
enum SenseUpgradeMode {
  /// No role installed (or nothing to compare): the normal wizard.
  none,

  /// An older version is installed: the upgrade screen.
  upgrade,

  /// The same or a newer version is installed: only the information, nothing is done.
  current,
}

/// Pure (Windows): `installed` = HKLM `Version` (0 = version 2 or older, which wrote none),
/// `current` = this setup file's version (0 = a build without a Sense version: the normal
/// wizard, as before).
SenseUpgradeMode senseUpgradeMode(
    {required bool roleInstalled,
    required int installed,
    required int current}) {
  if (!roleInstalled || current <= 0) return SenseUpgradeMode.none;
  return installed >= current
      ? SenseUpgradeMode.current
      : SenseUpgradeMode.upgrade;
}

/// Pure (macOS): output of `stat -f '%u %Lp'` for the paths root executes. Trusted when every
/// one of the `expected` lines is owned by uid 0 and not writable by group or others (the rule
/// of `bundle_file_trusted` in `src/sense/identity/mac_script.rs`). Anything unreadable counts
/// as trusted: the screen is offered only when the move is clearly needed.
bool senseMacBundleTrusted(String statOutput, int expected) {
  final lines = statOutput
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.length != expected) return true;
  for (final line in lines) {
    final parts = line.split(' ');
    if (parts.length != 2) return true;
    final uid = int.tryParse(parts[0]);
    final mode = int.tryParse(parts[1], radix: 8);
    if (uid == null || mode == null) return true;
    if (uid != 0 || mode & 0x12 != 0) return false; // 0o022
  }
  return true;
}

/// The upgrade the setup page hands to the wizard.
class SenseUpgrade {
  const SenseUpgrade({
    required this.mode,
    required this.installed,
    required this.current,
    required this.host,
    required this.controller,
    required this.run,
  });

  /// [SenseUpgradeMode.upgrade] or [SenseUpgradeMode.current].
  final SenseUpgradeMode mode;

  /// Installed version; 0 = version 2 or older.
  final int installed;

  /// Version of this setup file / app.
  final int current;

  /// The installed role (for the macOS permissions).
  final bool host;
  final bool controller;

  /// `install_sense_upgrade_in_place`: "", `cancelled`, `not_installed`, `not_newer`, `failed`.
  final Future<String> Function() run;
}

String _fromVersion(SenseUpgrade u) => '${u.installed > 0 ? u.installed : 2}';

extension _SenseInstallUpgradeSteps on _SenseInstallWizardState {
  SenseUpgrade get _upgrade => widget.upgrade!;

  Future<void> _runUpgrade() async {
    if (_upgradeRunning) return;
    _update(() {
      _upgradeRunning = true;
      _upgradeError = '';
    });
    String code;
    try {
      code = await _upgrade.run();
    } catch (_) {
      code = 'failed';
    }
    if (!mounted) return;
    _update(() {
      _upgradeRunning = false;
      if (code.isEmpty) {
        if (widget.mac) {
          _step = SenseInstallStep.permissions;
        } else {
          _upgradeDone = true;
        }
      } else if (code == 'not_newer') {
        _upgradeNotNewer = true;
      } else {
        _upgradeError = code;
      }
    });
    if (code.isEmpty && widget.mac) _startPermissionPoll();
  }

  (List<Widget>, List<Widget>) _upgradePage() {
    if (_upgradeDone) return _upgradeDonePage();
    final upgrade = _upgrade;
    if (upgrade.mode == SenseUpgradeMode.current || _upgradeNotNewer) {
      final n = '${upgrade.installed}';
      return (
        [
          _header([
            (_t('upgrade-current-title-a', {'n': n}), true),
            (_t('upgrade-current-title-b'), false),
          ], _t('upgrade-current-lead', {'n': n})),
        ],
        [
          const Spacer(),
          _button(_t('close'), _close, primary: true, key: const Key('sense-upgrade-close')),
        ],
      );
    }
    final mac = widget.mac;
    final error = _upgradeError;
    final to = '${upgrade.current}';
    return (
      [
        _header([(_t('upgrade-title-a'), false), (_t('upgrade-title-b'), true)],
            _t('upgrade-lead', {'from': _fromVersion(upgrade), 'to': to})),
        _box(
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 8),
            _tiles([
              (_t('upgrade-installed'), _t('upgrade-version', {'n': _fromVersion(upgrade)}), null),
              (_t('upgrade-target'), _t('upgrade-version', {'n': to}), SenseLevel.ok),
              (_t('upgrade-login'), _t('upgrade-login-value'), null),
            ], valueSize: SenseFontSize.categoryTitle),
            const SizedBox(height: 8),
            _hint(_t(mac ? 'upgrade-note-mac' : 'upgrade-note'),
                key: const Key('sense-upgrade-note')),
          ]),
          key: const Key('sense-upgrade-box'),
        ),
        if (_upgradeRunning) _progress(_t('upgrade-running'), key: const Key('sense-upgrade-running')),
        if (error.isNotEmpty)
          _statusBox(SenseLevel.hot, _t('upgrade-error'), [
            _meta(_t(error == 'cancelled' || error == 'not_installed'
                ? 'upgrade-error-$error'
                : 'upgrade-error-failed'))
          ], key: const Key('sense-upgrade-error')),
      ],
      [
        const Spacer(),
        _button(_t('close'), _upgradeRunning ? null : _close,
            key: const Key('sense-upgrade-cancel')),
        _button(_t(mac ? 'upgrade-mac-start' : 'upgrade-start'),
            _upgradeRunning ? null : _runUpgrade,
            primary: true, key: const Key('sense-upgrade-start')),
      ],
    );
  }

  (List<Widget>, List<Widget>) _upgradeDonePage() {
    final mac = widget.mac;
    final to = '${_upgrade.current}';
    final lines = [
      _t(mac ? 'upgrade-done-lead-mac' : 'upgrade-done-lead', {'to': to}),
      if (_permissionsSkipped) _t('done-permissions-missing'),
    ];
    return (
      [
        _resultPage(_t(mac ? 'upgrade-done-title-mac' : 'upgrade-done-title'), lines,
            key: const Key('sense-upgrade-done')),
      ],
      [
        const Spacer(),
        // macOS: the wizard runs inside the app, so it leaves through `finish` (a Controller
        // may open the app); Windows: the setup file only closes.
        if (mac && _controller) ...[
          _button(_t('close'), () => widget.backend.finish(false),
              key: const Key('sense-upgrade-finish-close')),
          _button(_t('open-app'), () => widget.backend.finish(true),
              primary: true, key: const Key('sense-upgrade-finish-open')),
        ] else
          _button(_t('close'),
              mac ? () => widget.backend.finish(false) : () => widget.onClose?.call(),
              primary: true, key: const Key('sense-upgrade-finish-close')),
      ],
    );
  }
}
