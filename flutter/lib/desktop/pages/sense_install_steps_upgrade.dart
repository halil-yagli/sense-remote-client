// Sense Remote (update plan 2026-11-21 §8, package U7): the one-time manual move from
// version 2, which has no updater (part of sense_install_wizard.dart).
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

String _upgradeText(String key, SenseUpgrade upgrade) => _t(key)
    .replaceAll('{from}', '${upgrade.installed > 0 ? upgrade.installed : 2}')
    .replaceAll('{to}', '${upgrade.current}')
    .replaceAll('{n}', '${upgrade.installed}');

extension _SenseInstallUpgradeSteps on _SenseInstallWizardState {
  SenseUpgrade get _upgrade => widget.upgrade!;

  Future<void> _runUpgrade() async {
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
        _step =
            widget.mac ? SenseInstallStep.permissions : SenseInstallStep.done;
      } else if (code == 'not_newer') {
        _upgradeNotNewer = true;
      } else {
        _upgradeError = code;
      }
    });
    if (code.isEmpty && widget.mac) _startPermissionPoll();
  }

  Widget _upgradePage() {
    final upgrade = _upgrade;
    if (upgrade.mode == SenseUpgradeMode.current || _upgradeNotNewer) {
      return _page([
        _heading(_upgradeText('upgrade-current-title-a', upgrade),
            _t('upgrade-current-title-b')),
        _lead(_upgradeText('upgrade-current-lead', upgrade)),
      ], [
        const Spacer(),
        _primaryButton(_t('close'), _close,
            key: const Key('sense-upgrade-close')),
      ]);
    }
    final mac = widget.mac;
    final error = _upgradeError;
    return _page([
      _heading(_t(mac ? 'upgrade-mac-title-a' : 'upgrade-title-a'),
          _t(mac ? 'upgrade-mac-title-b' : 'upgrade-title-b')),
      _lead(_upgradeText(mac ? 'upgrade-mac-lead' : 'upgrade-lead', upgrade)),
      Text(_t(mac ? 'upgrade-mac-note' : 'upgrade-note'),
          key: const Key('sense-upgrade-note'),
          style: const TextStyle(fontSize: 13, color: SenseTokens.soft)),
      if (_upgradeRunning)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _progress(_t('upgrade-running')),
        ),
      if (error.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _errorRow(
              _t(error == 'cancelled' || error == 'not_installed'
                  ? 'upgrade-error-$error'
                  : 'upgrade-error-failed'),
              key: const Key('sense-upgrade-error')),
        ),
    ], [
      _secondaryButton(_t('close'), _upgradeRunning ? null : _close,
          key: const Key('sense-upgrade-cancel')),
      const Spacer(),
      _primaryButton(_t(mac ? 'upgrade-mac-start' : 'upgrade-start'),
          _upgradeRunning ? null : _runUpgrade,
          key: const Key('sense-upgrade-start')),
    ]);
  }

  Widget _upgradeDonePage() {
    final upgrade = _upgrade;
    final mac = widget.mac;
    final lines = [
      _upgradeText(mac ? 'upgrade-done-lead-mac' : 'upgrade-done-lead', upgrade),
      if (_permissionsSkipped) _t('done-permissions-missing'),
    ];
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
                _heading(
                    _t(mac ? 'upgrade-done-title-mac' : 'upgrade-done-title'),
                    '',
                    boldFirst: true),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Text(
                    lines.join(' '),
                    key: const Key('sense-upgrade-done'),
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 13, color: SenseTokens.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            const Spacer(),
            // macOS: the wizard runs inside the app, so it leaves through `finish` (a
            // Controller may open the app); Windows: the setup file only closes.
            if (mac && _controller) ...[
              _secondaryButton(_t('close'), () => widget.backend.finish(false),
                  key: const Key('sense-upgrade-finish-close')),
              const SizedBox(width: 10),
              _primaryButton(_t('open-app'), () => widget.backend.finish(true),
                  key: const Key('sense-upgrade-finish-open')),
            ] else
              _primaryButton(
                  _t('close'),
                  mac
                      ? () => widget.backend.finish(false)
                      : () => widget.onClose?.call(),
                  key: const Key('sense-upgrade-finish-close')),
          ],
        ),
      ],
    );
  }
}
