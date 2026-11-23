// Sense Remote: "Bu bilgisayarın rolü" inside Settings (YH C3: "H2 ile aynı").
// Plan B4: the category imports B2's `screens/host/role/` component. B2 has
// not landed yet, so this is a stand-in with the same outside: a widget that
// takes nothing and shows the two role cards (prototype `roleBlock`). It only
// shows the installed role; adding or removing a role comes with B2's
// component (D3b `main_sense_role_*`). When B2 merges, replace the body of
// [SenseRoleSection] with B2's widget and delete the rest of this file.
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/settings.dart';
import '../sense_home_strings.dart' show SenseHomeRole, senseRoleLabel;

/// Category summary on the right ("Controller").
String senseRoleSummary(SenseHomeRole role) => senseRoleLabel(role);

class SenseRoleSection extends StatelessWidget {
  const SenseRoleSection({super.key, required this.role});

  final SenseHomeRole role;

  @override
  Widget build(BuildContext context) {
    final host = role == SenseHomeRole.host || role == SenseHomeRole.both;
    final controller = role == SenseHomeRole.controller || role == SenseHomeRole.both;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(SenseSettingsStrings.roleHint,
            style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
        const SizedBox(height: SenseUi.rowPadV),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: _RoleCard(
                key: const Key('sense-role-host'),
                title: SenseSettingsStrings.roleHost,
                body: SenseSettingsStrings.roleHostBody,
                on: host),
          ),
          const SizedBox(width: SenseUi.rowGap),
          Expanded(
            child: _RoleCard(
                key: const Key('sense-role-controller'),
                title: SenseSettingsStrings.roleController,
                body: SenseSettingsStrings.roleControllerBody,
                on: controller),
          ),
        ]),
      ],
    );
  }
}

const double _kCardPad = 14, _kCheck = 16;

class _RoleCard extends StatelessWidget {
  const _RoleCard({super.key, required this.title, required this.body, required this.on});

  final String title;
  final String body;
  final bool on;

  @override
  Widget build(BuildContext context) => Semantics(
        checked: on,
        label: title,
        child: Container(
          padding: const EdgeInsets.all(_kCardPad),
          decoration: BoxDecoration(
            color: SenseColors.bg,
            border: Border.all(color: on ? SenseColors.text : SenseColors.line),
            borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(title, style: SenseTextStyles.categoryTitle),
                  if (on) ...[
                    const SizedBox(width: SenseUi.iconGap),
                    const SenseChip(label: SenseSettingsStrings.roleInstalled, level: SenseLevel.ok),
                  ],
                ]),
                const SizedBox(height: SenseUi.iconGap),
                Text(body, style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textSecondary)),
              ]),
            ),
            Container(
              width: _kCheck,
              height: _kCheck,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? SenseColors.text : null,
                border: Border.all(color: on ? SenseColors.text : SenseColors.lineStrong),
                borderRadius: BorderRadius.circular(SenseRadii.button / 2),
              ),
              child: on
                  ? Text('✓',
                      style: SenseTextStyles.of(size: SenseFontSize.capsSmall, weight: SenseFontWeight.bold, color: SenseColors.bg))
                  : null,
            ),
          ]),
        ),
      );
}
