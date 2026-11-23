// Sense Remote: small pieces the Settings and About pages share (prototype
// `.ahead`, `.ov`, `.srow .val`). Not in the component library (plan B4 rule:
// a missing piece is written in its own screen folder and reported).
import 'package:flutter/widgets.dart';

import '../../../sense.dart';

/// `.amain` gap between blocks.
const double kSensePageGap = 10;

/// `.ov` padding.
const double _kBoxPadH = 10, _kBoxPadV = 8;

/// `.ahead`: bold title + thin continuation + a muted note (no dot).
class SensePageHead extends StatelessWidget {
  const SensePageHead({super.key, required this.title, this.titleThin, this.note});

  final String title;
  final String? titleThin;
  final String? note;

  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        child: Padding(
          padding: const EdgeInsets.only(top: SenseUi.iconGap / 2, bottom: SenseUi.iconGap),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: title, style: SenseTextStyles.pageTitleBold),
              if (titleThin != null) TextSpan(text: titleThin, style: SenseTextStyles.pageTitleThin),
            ])),
            if (note != null) ...[
              const SizedBox(width: kSensePageGap),
              Flexible(
                child: Text(note!,
                    key: const Key('sense-page-note'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
              ),
            ],
          ]),
        ),
      );
}

/// `.ov`: black box with a title (coloured by [level]: ok green, warn orange),
/// a muted line under it and an optional button on the right (`.hrow`).
class SenseOverviewBox extends StatelessWidget {
  const SenseOverviewBox({
    super.key,
    this.title,
    this.body,
    this.level,
    this.trailing,
    this.child,
  });

  final String? title;
  final String? body;

  /// Null: white title, plain frame.
  final SenseLevel? level;
  final Widget? trailing;
  final Widget? child;

  Color _border() {
    switch (level) {
      case SenseLevel.warn:
        return SenseColors.warn.withOpacity(0.5);
      case SenseLevel.hot:
        return SenseColors.hot.withOpacity(0.6);
      default:
        return SenseColors.line;
    }
  }

  @override
  Widget build(BuildContext context) {
    final head = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          Text(title!,
              key: const Key('sense-ov-title'),
              style: SenseTextStyles.of(
                  size: SenseFontSize.categoryTitleSmall,
                  weight: SenseFontWeight.bold,
                  color: level == null ? SenseColors.text : level!.color)),
        if (body != null)
          Padding(
            padding: const EdgeInsets.only(top: SenseUi.iconGap / 2),
            child: Text(body!, style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
          ),
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: _kBoxPadH, vertical: _kBoxPadV),
      decoration: BoxDecoration(
        color: SenseColors.bg,
        border: Border.all(color: _border()),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || body != null)
            Row(children: [
              Expanded(child: head),
              if (trailing != null) ...[const SizedBox(width: kSensePageGap), trailing!],
            ]),
          if (child != null) child!,
        ],
      ),
    );
  }
}

/// `.srow .val`: a muted value on the right of a setting row.
class SenseRowValue extends StatelessWidget {
  const SenseRowValue(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: SenseSizes.popupWidth),
        child: Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
      );
}

/// `lockVal`: a setting the panel manages; the value is shown, nothing to change.
class SenseLockedValueRow extends StatelessWidget {
  const SenseLockedValueRow({super.key, required this.label, required this.value, this.description, this.last = false});

  final String label;
  final String value;
  final String? description;
  final bool last;

  @override
  Widget build(BuildContext context) => SenseSettingRow(
        label: label,
        description: description,
        locked: true,
        last: last,
        control: SenseRowValue(value),
      );
}
