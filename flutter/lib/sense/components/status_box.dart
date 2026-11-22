// Sense Remote: general status box (YH T7 "Genel durum kutusu", prototype
// `.ov`, `.als`, `.al`). The 3–6 most important values; the frame takes the
// worst level's colour; troubled categories show as tags that open them.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';

/// A tag for a troubled category ("Ekran kartı", "Depolama").
class SenseStatusAlert {
  const SenseStatusAlert({required this.label, required this.level, this.onTap});

  final String label;

  /// [SenseLevel.warn] or [SenseLevel.hot].
  final SenseLevel level;

  /// Usually opens that category.
  final VoidCallback? onTap;
}

class SenseStatusBox extends StatelessWidget {
  const SenseStatusBox({
    super.key,
    required this.level,
    required this.title,
    this.alerts = const [],
    this.children = const [],
  });

  /// Worst level inside ([senseWorstLevel]); colours the frame and the title.
  final SenseLevel level;

  /// "Dikkat gerekiyor", "Her şey yolunda" …
  final String title;
  final List<SenseStatusAlert> alerts;

  /// Value rows (the screen's own meter rows).
  final List<Widget> children;

  static Color borderColor(SenseLevel level) {
    switch (level) {
      case SenseLevel.warn:
        return SenseColors.warn.withOpacity(0.5);
      case SenseLevel.hot:
        return SenseColors.hot.withOpacity(0.6);
      case SenseLevel.ok:
      case SenseLevel.unknown:
        return SenseColors.line;
    }
  }

  static Color titleColor(SenseLevel level) {
    switch (level) {
      case SenseLevel.ok:
        return SenseColors.ok;
      case SenseLevel.warn:
        return SenseColors.warn;
      case SenseLevel.hot:
        return SenseColors.hot;
      case SenseLevel.unknown:
        return SenseColors.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hot = level == SenseLevel.hot;
    return Container(
      key: const Key('sense-status-box'),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: hot ? null : SenseColors.bg,
        gradient: hot
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.alphaBlend(SenseColors.hot.withOpacity(0.08), SenseColors.bg), SenseColors.bg],
                stops: const [0, 0.6],
              )
            : null,
        border: Border.all(color: borderColor(level)),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: SenseFont.family,
              fontSize: SenseFontSize.categoryTitleSmall,
              fontWeight: SenseFontWeight.bold,
              color: titleColor(level),
            ),
          ),
          const SizedBox(height: 4),
          if (alerts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [for (final a in alerts) SenseStatusTag(alert: a)],
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}

/// `.al`: 10.5 / 600, 5 px corners, tinted background.
class SenseStatusTag extends StatefulWidget {
  const SenseStatusTag({super.key, required this.alert});

  final SenseStatusAlert alert;

  @override
  State<SenseStatusTag> createState() => _SenseStatusTagState();
}

class _SenseStatusTagState extends State<SenseStatusTag> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final a = widget.alert;
    final hot = a.level == SenseLevel.hot;
    final fg = hot ? SenseColors.dangerText : SenseColors.warn;
    final bg = hot ? SenseColors.hot.withOpacity(0.18) : SenseColors.warn.withOpacity(0.15);
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _focus ? SenseColors.text : bg.withOpacity(0)),
      ),
      child: Text(
        a.label,
        style: TextStyle(
          fontFamily: SenseFont.family,
          fontSize: SenseFontSize.hintSmall,
          fontWeight: SenseFontWeight.bold,
          color: fg,
        ),
      ),
    );
    if (a.onTap == null) return tag;
    return Semantics(
      button: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            a.onTap!();
            return null;
          }),
        },
        child: GestureDetector(onTap: a.onTap, child: tag),
      ),
    );
  }
}
