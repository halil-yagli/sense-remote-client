// Sense Remote: the one import for design tokens (İnşa planı §4.1, §4.3).
// Values come from tokens.g.dart (generated from design/tokens.json); this file only
// adds the small helpers screens need, so no screen writes a colour, size or limit by hand.
import 'package:flutter/painting.dart';

import 'token_types.dart';
import 'tokens.g.dart';

export 'token_types.dart';
export 'tokens.g.dart';

extension SenseLevelColor on SenseLevel {
  /// Status colour (YH T1, T6). An unreadable value is drawn faded.
  Color get color {
    switch (this) {
      case SenseLevel.ok:
        return SenseColors.ok;
      case SenseLevel.warn:
        return SenseColors.warn;
      case SenseLevel.hot:
        return SenseColors.hot;
      case SenseLevel.unknown:
        return SenseColors.textMuted;
    }
  }
}

/// The worst level of a closed category or group (YH T6): hot > warn > ok.
/// Unreadable values do not hide a real one; only when nothing could be read
/// is the result [SenseLevel.unknown].
SenseLevel senseWorstLevel(Iterable<SenseLevel> levels) {
  var worst = SenseLevel.unknown;
  for (final level in levels) {
    if (level.index > worst.index) worst = level;
  }
  return worst;
}

/// Letter spacing tokens are in em; Flutter wants logical px.
double senseLetterSpacing(double em, double fontSize) => em * fontSize;

/// Widths that follow the window (YH T3, T9). Like the prototype's `max-width` media
/// queries, a window exactly 1500 px wide is already medium and 1300 px already narrow.
abstract final class SenseLayout {
  static double popupWidth(double windowWidth) {
    if (windowWidth <= SenseBreakpoints.narrow) return SenseSizes.popupWidthNarrow;
    if (windowWidth <= SenseBreakpoints.medium) return SenseSizes.popupWidthMedium;
    return SenseSizes.popupWidth;
  }

  static double sideMenu(double windowWidth) => windowWidth <= SenseBreakpoints.narrow
      ? SenseSizes.sideMenuNarrow
      : SenseSizes.sideMenu;

  static double tileMin(double windowWidth) => windowWidth <= SenseBreakpoints.narrow
      ? SenseSizes.tileMinNarrow
      : SenseSizes.tileMin;
}
