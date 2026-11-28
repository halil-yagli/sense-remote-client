// Sense Remote (Sürüm 12, ST 4–7): small parts shared by the terminal and TCP tunnel
// windows. Prototype: `.axbadge` (pill), `.axask` (in-place step / notice strip).
import 'package:flutter/widgets.dart';

import '../../sense.dart';

/// `.axbadge`: outlined pill, 10.5 px; warn = orange line and text.
class SenseAuxBadge extends StatelessWidget {
  const SenseAuxBadge({super.key, required this.label, this.level});

  final String label;

  /// [SenseLevel.warn] / [SenseLevel.ok] colour it; null = neutral.
  final SenseLevel? level;

  @override
  Widget build(BuildContext context) {
    final c = switch (level) {
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.hot,
      SenseLevel.ok => SenseColors.ok,
      _ => null,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c ?? SenseColors.line),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: c ?? SenseColors.textMuted),
      ),
    );
  }
}

/// `.axask`: a framed strip under the tabs — bold line, muted text, buttons on the right.
/// Used for the admin step (warn), the admin request (neutral) and the clipboard notice.
class SenseAuxStrip extends StatelessWidget {
  const SenseAuxStrip({
    super.key,
    required this.title,
    this.body,
    this.level,
    this.leading,
    this.actions = const [],
    this.margin = const EdgeInsets.fromLTRB(12, 10, 12, 0),
  });

  final String title;
  final String? body;

  /// warn = orange frame; null = line colour.
  final SenseLevel? level;
  final Widget? leading;
  final List<Widget> actions;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final border = switch (level) {
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.hot,
      _ => SenseColors.line,
    };
    return Container(
      margin: margin,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(SenseRadii.popup),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Expanded(
              child: Text(title,
                  style: SenseTextStyles.of(size: SenseFontSize.categoryTitleSmall, weight: SenseFontWeight.bold)),
            ),
          ]),
          if (body != null && body!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(body!,
                style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted, height: 1.5)),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}
