// Sense Remote: small labels (YH T6, T7; prototype `.chip3`, `.al`, `.chip`).
// [SenseChip]: status label (neutral, green, orange, red); clickable = an alert tag
// that opens its category. [SensePill]: rounded choice chip (quick picks).
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';

// Prototype: `.chip3` corner 5, padding 1×7; `.al` padding 2×7; `.chip` corner 14, 4×10.
const double _kChipRadius = 5, _kChipPadH = 7, _kChipPadV = 1, _kAlertPadV = 2;
const double _kPillRadius = 14, _kPillPadH = 10, _kPillPadV = 4;

/// Background and text colour of a status label (`.chip3.ok/.warn/.hot`).
({Color bg, Color fg}) senseChipColors(SenseLevel? level) {
  switch (level) {
    case SenseLevel.ok:
      return (bg: SenseColors.ok.withOpacity(0.12), fg: SenseColors.ok);
    case SenseLevel.warn:
      return (bg: SenseColors.warn.withOpacity(0.15), fg: SenseColors.warn);
    case SenseLevel.hot:
      return (bg: SenseColors.hot.withOpacity(0.18), fg: SenseColors.dangerText);
    case SenseLevel.unknown:
    case null:
      return (bg: SenseColors.raised, fg: SenseColors.textSecondary);
  }
}

class SenseChip extends StatelessWidget {
  const SenseChip({super.key, required this.label, this.level, this.onTap, this.tooltip});

  final String label;

  /// Null or [SenseLevel.unknown] = neutral.
  final SenseLevel? level;

  /// Set = alert tag (`.al`, bold, opens its category).
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = senseChipColors(level);
    final clickable = onTap != null;
    Widget box(SenseInteractionState s) => SenseFocusRing(
          visible: s.focused,
          radius: _kChipRadius,
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: _kChipPadH, vertical: clickable ? _kAlertPadV : _kChipPadV),
            decoration: BoxDecoration(
              color: s.hovered ? Color.alphaBlend(c.bg, SenseColors.hover) : c.bg,
              borderRadius: BorderRadius.circular(_kChipRadius),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.of(
                size: SenseFontSize.caps,
                weight: clickable ? SenseFontWeight.bold : SenseFontWeight.regular,
                color: c.fg,
              ),
            ),
          ),
        );
    if (!clickable) {
      final plain = box(const SenseInteractionState());
      return tooltip == null
          ? plain
          : SenseInteractive(button: false, tooltip: tooltip, builder: (_, __) => plain);
    }
    return SenseInteractive(onTap: onTap, tooltip: tooltip, builder: (_, s) => box(s));
  }
}

class SensePill extends StatelessWidget {
  const SensePill({super.key, required this.label, this.onTap, this.selected = false});

  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null && !selected ? SenseUi.disabledOpacity : 1,
        child: SenseInteractive(
          onTap: onTap,
          selected: selected,
          builder: (_, s) {
            final fg = selected
                ? SenseColors.bg
                : (s.hovered ? SenseColors.text : SenseColors.textSecondary);
            final border = selected
                ? SenseColors.text
                : (s.hovered ? SenseColors.lineStrong : SenseColors.line);
            return SenseFocusRing(
              visible: s.focused,
              radius: _kPillRadius,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: _kPillPadH, vertical: _kPillPadV),
                decoration: BoxDecoration(
                  color: selected ? SenseColors.text : SenseColors.bg,
                  border: Border.all(color: border),
                  borderRadius: BorderRadius.circular(_kPillRadius),
                ),
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SenseTextStyles.of(size: SenseFontSize.hint, color: fg)),
              ),
            );
          },
        ),
      );
}
