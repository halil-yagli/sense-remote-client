// Sense Remote: small "Sürüm 3" label in the header of the Host and
// Controller home screens (update plan 2026-11-21, §6). Opens About.
// A2a: bound to the design tokens (same look as before: 11 px, soft grey).

import 'package:flutter/widgets.dart';

import '../../models/platform_model.dart';
import '../../desktop/pages/desktop_setting_page.dart';
import '../screens/controller/sense_home_strings.dart';
import '../screens/controller/sense_update_strings.dart';
import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';

// Corner 6, padding 3×6 (unchanged; the prototype `.ver` frame comes with B's goldens).
const double _kRadius = 6, _kPadV = 3, _kPadH = 6;

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
    final hint = onTap != null ? senseUpdateText('version_tip') : null;
    return Semantics(
      button: onTap != null,
      hint: hint,
      child: SenseInteractive(
        onTap: onTap,
        button: false,
        mouseCursor: onTap == null ? MouseCursor.defer : null,
        builder: (_, s) => SenseFocusRing(
          visible: s.focused,
          radius: _kRadius,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: _kPadH, vertical: _kPadV),
            decoration: BoxDecoration(
              color: s.hovered ? SenseColors.hover : null,
              borderRadius: BorderRadius.circular(_kRadius),
            ),
            child: Text(
              senseUpdateText('version', {'n': '$version'}),
              key: const Key('sense-version-chip'),
              style: SenseTextStyles.of(
                size: SenseFontSize.hint,
                weight: SenseFontWeight.thin,
                color: s.hovered ? SenseColors.text : SenseColors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
