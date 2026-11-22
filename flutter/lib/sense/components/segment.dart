// Sense Remote: segmented choice (YH T7; prototype `.seg`, `.aseg`, `.vsw`).
// Side-by-side options; the selected one is white with black text.
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';
import 'toggle.dart' show kSensePanelManaged;

// Prototype: outer padding / gap 2, option corner 6, option padding 5×4 (`.seg`,
// stretched) or 5×11 (`.aseg`, own width); 4 px vertical on short windows (≤ 800 px).
const double _kOuter = 2, _kOptionRadius = 6, _kPadHStretched = 4;

class SenseSegmentOption<T> {
  const SenseSegmentOption({required this.value, required this.label, this.enabled = true});

  final T value;
  final String label;
  final bool enabled;
}

class SenseSegment<T> extends StatelessWidget {
  const SenseSegment({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.locked = false,
    this.expand = true,
    this.semanticLabel,
  });

  final List<SenseSegmentOption<T>> options;

  /// Selected value; null = nothing selected yet.
  final T? value;
  final ValueChanged<T>? onChanged;

  /// Managed by the panel: faded, cannot be changed, tooltip "Panelden yönetilir".
  final bool locked;

  /// True: fills the width, options share it (`.seg`). False: own width (`.aseg`).
  final bool expand;
  final String? semanticLabel;

  /// Vertical padding of an option: 5, or 4 on windows at most 800 px high (T9).
  static double paddingV(double windowHeight) =>
      windowHeight <= SenseUi.shortWindowHeight ? SenseSizes.buttonSmallPadV - 1 : SenseSizes.buttonSmallPadV;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.maybeSizeOf(context)?.height ?? double.infinity;
    final padding = EdgeInsets.symmetric(
      horizontal: expand ? _kPadHStretched : SenseSizes.buttonPadH,
      vertical: paddingV(height),
    );
    final enabled = !locked && onChanged != null;
    final children = <Widget>[];
    for (var i = 0; i < options.length; i++) {
      final o = options[i];
      if (i > 0) children.add(const SizedBox(width: _kOuter));
      final item = _SegmentItem<T>(
        option: o,
        selected: o.value == value,
        padding: padding,
        onTap: enabled && o.enabled ? () => onChanged!(o.value) : null,
      );
      children.add(expand ? Expanded(child: item) : item);
    }
    Widget box = Container(
      padding: const EdgeInsets.all(_kOuter),
      decoration: BoxDecoration(
        color: expand ? SenseColors.surface : SenseColors.bg,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.button),
      ),
      child: Row(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, children: children),
    );
    box = Semantics(container: true, label: semanticLabel, child: box);
    if (!enabled) {
      box = Opacity(opacity: SenseUi.disabledOpacity, child: box);
    }
    if (locked) {
      // Tooltip import is from material; keep the widgets-only import here.
      box = _LockedTooltip(child: box);
    }
    return box;
  }
}

class _SegmentItem<T> extends StatelessWidget {
  const _SegmentItem({required this.option, required this.selected, required this.padding, required this.onTap});

  final SenseSegmentOption<T> option;
  final bool selected;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: option.enabled ? 1 : SenseUi.disabledOpacity,
        child: SenseInteractive(
          onTap: onTap,
          selected: selected,
          builder: (context, s) {
            final bg = selected
                ? SenseColors.text
                : (s.hovered || s.pressed ? SenseColors.hover : null);
            final fg = selected
                ? SenseColors.bg
                : (s.hovered ? SenseColors.text : SenseColors.textSecondary);
            return SenseFocusRing(
              visible: s.focused,
              radius: _kOptionRadius,
              child: Container(
                padding: padding,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(_kOptionRadius),
                ),
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SenseTextStyles.buttonSmall.copyWith(color: fg),
                ),
              ),
            );
          },
        ),
      );
}

class _LockedTooltip extends StatelessWidget {
  const _LockedTooltip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SenseInteractive(
        button: false,
        tooltip: kSensePanelManaged,
        builder: (_, __) => child,
      );
}
