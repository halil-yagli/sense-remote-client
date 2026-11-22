// Sense Remote: number tile and its grid (YH T6, T7; prototype `.kv`, `.nmv`).
// Small label + big value; frame and value in the status colour. A value that could
// not be read says "okunamadı" (faded, italic) — never a guess.
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';

const String kSenseUnreadable = 'okunamadı';

// Prototype `.kv>div` padding 8×10, gap 2; `.nmv` padding 7×8 and a 15 px value
// (15 px is not a token yet: token candidate, see the A2a report).
const double _kPadV = 8, _kPadH = 10, _kGap = 2;
const double _kLargePadV = 7, _kLargePadH = 8, _kLargeValue = 15;
// Grid: `minmax(150px,1fr)`, 120 px at or under 1300 px; gap 8.
const double _kTileMin = 150, _kTileMinNarrow = 120, _kGridGap = 8;

class SenseStatTile extends StatelessWidget {
  const SenseStatTile({
    super.key,
    required this.label,
    required this.value,
    this.level,
    this.large = false,
    this.onTap,
  });

  final String label;

  /// Null = could not be read ("okunamadı").
  final String? value;

  /// Null = neutral (white value, plain frame).
  final SenseLevel? level;

  /// The centred, bigger tile of the connection overlay (`.nmv`).
  final bool large;

  /// Set when the tile opens something (e.g. its category).
  final VoidCallback? onTap;

  Color _border() {
    switch (level) {
      case SenseLevel.warn:
        return SenseColors.warn.withOpacity(large ? 0.5 : 0.45);
      case SenseLevel.hot:
        return SenseColors.hot.withOpacity(large ? 0.6 : 0.55);
      default:
        return SenseColors.line;
    }
  }

  Color _valueColor() {
    switch (level) {
      case SenseLevel.ok:
        return large ? SenseColors.text : SenseColors.ok;
      case SenseLevel.warn:
        return SenseColors.warn;
      case SenseLevel.hot:
        return SenseColors.dangerText;
      default:
        return SenseColors.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final readable = value != null;
    final valueText = Text(
      value ?? kSenseUnreadable,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: readable
          ? SenseTextStyles.of(
              size: large ? _kLargeValue : SenseFontSize.categoryTitle,
              weight: SenseFontWeight.bold,
              color: _valueColor(),
            ).copyWith(fontFeatures: const [FontFeature.tabularFigures()])
          : SenseTextStyles.of(
              size: large ? SenseFontSize.body : SenseFontSize.bodySmall,
              color: SenseColors.textMuted,
              fontStyle: FontStyle.italic,
            ),
    );
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: SenseTextStyles.of(
          size: large ? SenseFontSize.capsSmall : SenseFontSize.caps, color: SenseColors.textMuted),
    );
    Widget tile(SenseInteractionState s) => SenseFocusRing(
          visible: s.focused,
          radius: SenseRadii.category,
          child: Container(
            padding: large
                ? const EdgeInsets.symmetric(vertical: _kLargePadV, horizontal: _kLargePadH)
                : const EdgeInsets.symmetric(vertical: _kPadV, horizontal: _kPadH),
            decoration: BoxDecoration(
              color: large
                  ? SenseColors.bg
                  : (s.hovered ? SenseColors.hover : SenseColors.surface),
              border: Border.all(color: s.hovered && level == null ? SenseColors.lineStrong : _border()),
              borderRadius: BorderRadius.circular(SenseRadii.category),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: large ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: large
                  ? [valueText, labelText]
                  : [labelText, const SizedBox(height: _kGap), valueText],
            ),
          ),
        );
    return SenseInteractive(
      onTap: onTap,
      button: onTap != null,
      mouseCursor: onTap == null ? MouseCursor.defer : null,
      semanticLabel: '$label: ${value ?? kSenseUnreadable}',
      builder: (_, s) => tile(s),
    );
  }
}

/// Tiles in equal columns that fill the width (CSS `repeat(auto-fit, minmax(150px,1fr))`;
/// 120 px at or under 1300 px window width, T9).
class SenseStatGrid extends StatelessWidget {
  const SenseStatGrid({super.key, required this.children, this.minTileWidth});

  final List<Widget> children;

  /// Null = 150, or 120 on narrow windows.
  final double? minTileWidth;

  static double defaultMinTile(double windowWidth) =>
      windowWidth <= SenseBreakpoints.narrow ? _kTileMinNarrow : _kTileMin;

  /// Number of columns for [width] (never more than [count]).
  static int columns(double width, double minTile, int count) {
    final fit = ((width + _kGridGap) / (minTile + _kGridGap)).floor();
    return math.max(1, math.min(fit, math.max(count, 1)));
  }

  @override
  Widget build(BuildContext context) {
    final window = MediaQuery.maybeSizeOf(context)?.width ?? double.infinity;
    final min = minTileWidth ?? defaultMinTile(window);
    return LayoutBuilder(builder: (context, box) {
      if (!box.maxWidth.isFinite) {
        return Wrap(spacing: _kGridGap, runSpacing: _kGridGap, children: children);
      }
      final cols = columns(box.maxWidth, min, children.length);
      final w = (box.maxWidth - _kGridGap * (cols - 1)) / cols;
      return Wrap(
        spacing: _kGridGap,
        runSpacing: _kGridGap,
        children: [for (final c in children) SizedBox(width: w, child: c)],
      );
    });
  }
}
