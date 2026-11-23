// Sense Remote: "Yetkiler" category (YH H2): panelden · imzalı · N açık; every
// switch is locked (the panel's signed envelope sets them).
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/host.dart';
import '../data/permissions.dart';
import '../this_computer/widgets.dart';

export '../data/permissions.dart';

/// "panelden · imzalı · 8 açık".
String senseHostPermissionsSummary(List<bool> on) =>
    SenseHostStrings.permissionsSummary(on.where((v) => v).length);

class SensePermissionsCategoryBody extends StatelessWidget {
  const SensePermissionsCategoryBody({super.key, required this.on});

  /// One value per [kSenseHostPermissions] entry.
  final List<bool> on;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SenseHostMeta(SenseHostStrings.permissionsHint, color: SenseColors.textMuted),
          for (var i = 0; i < kSenseHostPermissions.length; i++)
            SenseToggleRow(
              key: Key('sense-perm-$i'),
              label: kSenseHostPermissions[i].label,
              value: i < on.length && on[i],
              onChanged: null,
              locked: true,
              last: i == kSenseHostPermissions.length - 1,
            ),
        ],
      );
}
