// Sense Remote: small "Sürüm 3" label in the header of the Host and
// Controller home screens (update plan 2026-11-21, §6). Opens About.

import 'package:flutter/material.dart';

import '../../models/platform_model.dart';
import '../../desktop/pages/desktop_setting_page.dart';
import '../screens/host_live/sense_cm_style.dart';
import '../screens/controller/sense_home_about.dart' show kSenseVersionOption;
import '../screens/controller/sense_home_strings.dart';
import '../screens/controller/sense_update_strings.dart';

typedef _T = SenseCmTokens;

/// Sense version of this build, like the About page: the built-in option,
/// else `--dart-define=SENSE_VERSION`; null when the build has none.
int? senseAppVersion() =>
    senseVersionFrom(bind.mainGetBuildinOption(key: kSenseVersionOption)) ??
    senseVersionFrom(kSenseVersionDefine);

void senseOpenAbout() => DesktopSettingPage.switch2page(SettingsTabKey.about);

/// Pure: nothing when [version] is null (no made-up number).
class SenseVersionChip extends StatelessWidget {
  const SenseVersionChip({super.key, required this.version, this.onTap});

  final int? version;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (version == null) return const SizedBox.shrink();
    final label = Text(senseUpdateText('version', {'n': '$version'}),
        key: const Key('sense-version-chip'),
        style: _T.text(size: 11, color: _T.muted));
    return Semantics(
      button: onTap != null,
      hint: onTap != null ? senseUpdateText('version_tip') : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: label,
        ),
      ),
    );
  }
}
