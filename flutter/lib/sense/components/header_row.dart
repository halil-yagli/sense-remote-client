// Sense Remote: page header row (YH T2, T7; prototype `.ahead`, `.ahead h1`, `.live`).
// Bold title (+ optional thin continuation), live status (dot + "Canlı · 8 sn önce"),
// then the actions on the right.
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'led.dart';

// Prototype `.ahead` gap 10, bottom padding 8, top 4; `.live i` 7 px dot, gap 5.
const double _kGap = 10, _kPadTop = 4, _kPadBottom = 8, _kLiveDot = 7, _kLiveGap = 5;

/// Coloured dot + short status text ("Canlı · 8 sn önce", "3/12 çevrimiçi").
class SenseLiveStatus extends StatelessWidget {
  const SenseLiveStatus({super.key, required this.text, this.level = SenseLevel.ok});

  final String text;
  final SenseLevel level;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SenseLed(level: level, size: _kLiveDot, glow: false),
          const SizedBox(width: _kLiveGap),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted),
            ),
          ),
        ],
      );
}

class SenseHeaderRow extends StatelessWidget {
  const SenseHeaderRow({
    super.key,
    required this.title,
    this.titleThin,
    this.status,
    this.statusLevel = SenseLevel.ok,
    this.trailing = const <Widget>[],
    this.large = false,
  });

  /// Bold part ("Bilgisayarlar", "Bakım").
  final String title;

  /// Thin continuation after the bold part (" yapılıyor").
  final String? titleThin;

  /// Live status text; null = none.
  final String? status;
  final SenseLevel statusLevel;

  /// Right-aligned actions (search, buttons, version chip).
  final List<Widget> trailing;

  /// Setup title size (22 px) instead of the page title (18 px).
  final bool large;

  @override
  Widget build(BuildContext context) {
    final size = large ? SenseFontSize.setupTitle : SenseFontSize.pageTitle;
    final heading = Text.rich(
      TextSpan(children: [
        TextSpan(text: title, style: SenseTextStyles.of(size: size, weight: SenseFontWeight.bold)),
        if (titleThin != null)
          TextSpan(text: titleThin, style: SenseTextStyles.of(size: size, weight: SenseFontWeight.thin)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(top: _kPadTop, bottom: _kPadBottom),
        child: Row(
          children: [
            // The title takes all the room the status does not need; the status is
            // capped at half the width. Two `Flexible`s would split the free space in
            // half and cut a long title while space is left (G7).
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) => Row(
                  children: [
                    Flexible(child: heading),
                    if (status != null) ...[
                      const SizedBox(width: _kGap),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: c.maxWidth.isFinite ? c.maxWidth / 2 : double.infinity),
                        child: SenseLiveStatus(text: status!, level: statusLevel),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            for (final action in trailing) ...[
              const SizedBox(width: _kGap),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
