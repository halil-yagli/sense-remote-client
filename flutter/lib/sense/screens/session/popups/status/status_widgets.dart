// Sense Remote: the rows of the session popups, drawn like the locked design
// (prototip/onayli/2026-11-22_bilgisayar-durumu_ONAYLI.html: `.mt`, `.r`, `.gt2`,
// `.sc`, `.tag`, `.hint2`, `.stop`). The library has the frame (SensePopupShell),
// the overall box (SenseStatusBox) and the categories (SenseAccordion); these
// smaller parts are popup-specific, so they live here (plan C2: not in components/).
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../../sense.dart';
import 'status_model.dart';
import 'status_strings.dart';

// Locked design measures (px): `.mt` gap 8, padding 4, label min 84, bar 6,
// value min 92; `.r` padding 3, gap 10; `.gt2` margin 9/3; `.sc` padding 7×9,
// margin 7, corner 8; `.tag` padding 1×5, corner 4, gap 5; `.hint2` margin 8;
// `.stop` margin 8, `.ov` margin 6.
const double _kMeterGap = 8, _kMeterPadV = 4, _kMeterLabel = 84, _kBar = 6, _kMeterValue = 92;
const double _kRowPadV = 3, _kRowGap = 10;
const double _kGroupTop = 9, _kGroupBottom = 3;
const double _kCardPadV = 7, _kCardPadH = 9, _kCardGap = 7, _kCardHeadGap = 6, _kCardHeadBottom = 3;
const double _kTagPadV = 1, _kTagPadH = 5, _kTagRadius = 4, _kTagGap = 5;
const double _kHintTop = 8, _kHintLine = 1.5;
const double kSenseStatusTopGap = 8, kSenseStatusBoxGap = 6;

/// Value colour of a level (`.v.warn`, `.v.hot`): warn orange, hot the soft red.
Color senseValueColor(SenseLevel? level) => switch (level) {
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.dangerText,
      _ => SenseColors.text,
    };

TextStyle _valueStyle(String? value, SenseLevel? level) {
  if (value == null) {
    // "okunamadı": faded and italic (T6).
    return SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textDim, fontStyle: FontStyle.italic);
  }
  final strong = level == SenseLevel.warn || level == SenseLevel.hot;
  return SenseTextStyles.of(
    size: SenseFontSize.hintLarge,
    weight: strong ? SenseFontWeight.bold : SenseFontWeight.regular,
    color: senseValueColor(level),
  );
}

/// `.mt`: label, bar, value.
class SenseMeterRowView extends StatelessWidget {
  const SenseMeterRowView({super.key, required this.row});

  final SenseStatusMeter row;

  @override
  Widget build(BuildContext context) {
    final pct = row.pct;
    final fill = switch (row.barLevel) {
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.hot,
      _ => SenseColors.text,
    };
    return Semantics(
      label: '${row.label}: ${row.text ?? SenseStatusStrings.unreadable}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: _kMeterPadV),
        child: Row(children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _kMeterLabel),
            child: Text(row.label, style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
          ),
          const SizedBox(width: _kMeterGap),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_kBar),
              child: Container(
                height: _kBar,
                color: SenseColors.hover,
                alignment: Alignment.centerLeft,
                child: pct == null
                    ? null
                    : FractionallySizedBox(
                        key: const Key('sense-meter-fill'),
                        widthFactor: math.max(2, math.min(100, pct)) / 100,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(_kBar)),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(width: _kMeterGap),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _kMeterValue),
            child: Text(row.text ?? SenseStatusStrings.unreadable,
                textAlign: TextAlign.right, style: _valueStyle(row.text, row.valueLevel)),
          ),
        ]),
      ),
    );
  }
}

/// `.r`: label left, value right, dashed line under it unless [last].
class SenseLineRowView extends StatelessWidget {
  const SenseLineRowView({super.key, required this.row, this.last = false});

  final SenseStatusLine row;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final tag = row.tag;
    final labelStyle = SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted);
    final value = row.value ?? SenseStatusStrings.unreadable;
    final valueStyle = _valueStyle(row.value, row.valueLevel);
    final line = Padding(
      padding: const EdgeInsets.symmetric(vertical: _kRowPadV),
      child: LayoutBuilder(builder: (context, c) {
        // CSS `justify-content:space-between` with both sides allowed to shrink in
        // proportion to their width (a long value wraps the label, like "USB aygıtları").
        final scaler = MediaQuery.textScalerOf(context);
        double w(String t, TextStyle st) {
          final tp = TextPainter(text: TextSpan(text: t, style: st), textDirection: TextDirection.ltr, textScaler: scaler)
            ..layout();
          final width = tp.width;
          tp.dispose();
          return width;
        }
        final lw = w(row.label, labelStyle);
        var vw = w(value, valueStyle);
        if (tag != null) {
          vw += _kTagGap + 2 * _kTagPadH + w(tag, SenseStatusTagView.style(row.tagStrong));
        }
        final room = math.max(0.0, c.maxWidth - _kRowGap);
        final labelWidth = lw + vw <= room ? lw : math.max(0.0, room * lw / (lw + vw));
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: math.min(labelWidth.ceilToDouble(), room), child: Text(row.label, style: labelStyle)),
          const SizedBox(width: _kRowGap),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: value, style: valueStyle),
                if (tag != null)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(left: _kTagGap),
                      child: SenseStatusTagView(label: tag, strong: row.tagStrong),
                    ),
                  ),
              ]),
              textAlign: TextAlign.right,
            ),
          ),
        ]);
      }),
    );
    if (last) return line;
    return CustomPaint(painter: const _DashedLine(), child: line);
  }
}

class _DashedLine extends CustomPainter {
  const _DashedLine();

  @override
  void paint(Canvas canvas, Size size) {
    // `border-bottom:1px dashed #1b1b22`; the nearest token is hover.
    final paint = Paint()
      ..color = SenseColors.hover
      ..strokeWidth = 1;
    const dash = 3.0;
    final y = size.height - 0.5;
    for (var x = 0.0; x < size.width; x += dash * 2) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, size.width), y), paint);
    }
  }

  @override
  bool shouldRepaint(_DashedLine old) => false;
}

/// `.tag.dh` (grey) and `.tag.st` (white): 600, small, 4 px corners.
class SenseStatusTagView extends StatelessWidget {
  const SenseStatusTagView({super.key, required this.label, this.strong = false});

  final String label;
  final bool strong;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: _kTagPadH, vertical: _kTagPadV),
        decoration: BoxDecoration(
          color: strong ? SenseColors.text : SenseColors.line,
          borderRadius: BorderRadius.circular(_kTagRadius),
        ),
        child: Text(label, style: style(strong)),
      );

  static TextStyle style(bool strong) => SenseTextStyles.of(
        size: SenseFontSize.capsSmall,
        weight: SenseFontWeight.bold,
        color: strong ? SenseColors.bg : SenseColors.textSecondary,
      );
}

/// `.gt2`: small upper-case group title.
class SenseGroupTitleView extends StatelessWidget {
  const SenseGroupTitleView({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: _kGroupTop, bottom: _kGroupBottom),
        child: Text(
          title.toUpperCase(),
          style: SenseTextStyles.of(
            size: SenseFontSize.capsSmall,
            color: SenseColors.textDim,
            letterSpacingEm: SenseLetterSpacing.capsWide,
          ),
        ),
      );
}

/// `.hint2`: grey note.
class SenseHintView extends StatelessWidget {
  const SenseHintView({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: _kHintTop),
        child: Text(text,
            style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim, height: _kHintLine)),
      );
}

/// `.sc`: one object with its own Kopyala; frame in the worst colour inside.
class SenseStatusCardView extends StatelessWidget {
  const SenseStatusCardView({super.key, required this.card, this.onCopied});

  final SenseStatusCard card;
  final VoidCallback? onCopied;

  @override
  Widget build(BuildContext context) {
    final border = switch (card.level) {
      SenseLevel.warn => SenseColors.warn.withOpacity(0.45),
      SenseLevel.hot => SenseColors.hot.withOpacity(0.55),
      _ => SenseColors.line,
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: _kCardGap),
      padding: const EdgeInsets.symmetric(vertical: _kCardPadV, horizontal: _kCardPadH),
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(SenseRadii.button),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: _kCardHeadBottom),
          child: Row(children: [
            Flexible(
              child: Text(card.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.bold)),
            ),
            for (final t in card.tags) ...[
              const SizedBox(width: _kCardHeadGap),
              SenseStatusTagView(label: t),
            ],
            const Spacer(),
            const SizedBox(width: _kCardHeadGap),
            SenseCopyButton(key: Key('sense-copy-${card.title}'), text: card.copyText, onCopied: onCopied),
          ]),
        ),
        ...senseRowViews(card.rows, onCopied: onCopied),
      ]),
    );
  }
}

/// Widgets for a list of rows; a line before a non-line has no dashed border.
List<Widget> senseRowViews(List<SenseStatusRow> rows, {VoidCallback? onCopied}) {
  final out = <Widget>[];
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final next = i + 1 < rows.length ? rows[i + 1] : null;
    out.add(switch (r) {
      SenseStatusLine l => SenseLineRowView(row: l, last: next is! SenseStatusLine),
      SenseStatusMeter m => SenseMeterRowView(row: m),
      SenseStatusGroup g => SenseGroupTitleView(title: g.title),
      SenseStatusNote n => SenseHintView(text: n.text),
      SenseStatusCard c => SenseStatusCardView(card: c, onCopied: onCopied),
      SenseStatusUnreadable() => Padding(
          padding: const EdgeInsets.symmetric(vertical: _kRowPadV),
          child: Text(SenseStatusStrings.unreadable, style: _valueStyle(null, null)),
        ),
    });
  }
  return out;
}

// ------------------------------------------------------------------ placement

/// Where the Sense chat icon is (O10: it can be dragged) in the popup host's
/// area, so a right-side popup ends above it instead of covering it.
@immutable
class SenseChatIconPlacement {
  const SenseChatIconPlacement({required this.icon, required this.area});

  /// Icon rectangle in the host area's coordinates.
  final Rect icon;

  /// Size of the popup host area (the remote screen under the toolbar).
  final Size area;

  @override
  bool operator ==(Object other) => other is SenseChatIconPlacement && other.icon == icon && other.area == area;

  @override
  int get hashCode => Object.hash(icon, area);
}

/// Highest a top-right popup may be (prototype `placeSide`): never closer than
/// [SenseSizes.popupBottomGap] to the bottom (the host already keeps that), and
/// when the icon sits in the lower right, under the popup column, the popup
/// ends 10 px above it (but stays at least 200 px tall).
double senseSidePopupMaxHeight({
  required double slotMaxHeight,
  required double popupWidth,
  SenseChatIconPlacement? chat,
  double margin = SensePopupHost.defaultMargin,
}) {
  if (chat == null) return slotMaxHeight;
  final underColumn = chat.icon.right > chat.area.width - (popupWidth + 2 * margin);
  final lower = chat.icon.top > chat.area.height / 2;
  if (!underColumn || !lower) return slotMaxHeight;
  final above = chat.icon.top - 2 * margin; // top margin + 10 px gap
  return math.min(slotMaxHeight, math.max(_kMinPopup, above));
}

const double _kMinPopup = 200;

/// Applies [senseSidePopupMaxHeight] inside the host slot.
class SenseAvoidChatIcon extends StatelessWidget {
  const SenseAvoidChatIcon({super.key, required this.child, this.chat});

  final Widget child;
  final ValueListenable<SenseChatIconPlacement?>? chat;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      Widget sized(SenseChatIconPlacement? p) {
        if (!c.maxHeight.isFinite) return child;
        final h = senseSidePopupMaxHeight(slotMaxHeight: c.maxHeight, popupWidth: c.maxWidth, chat: p);
        return ConstrainedBox(constraints: BoxConstraints(maxHeight: h), child: child);
      }

      final l = chat;
      if (l == null) return sized(null);
      return ValueListenableBuilder<SenseChatIconPlacement?>(valueListenable: l, builder: (_, p, __) => sized(p));
    });
  }
}

/// `.stop`: green dot + "Canlı · 8 sn önce" (T7 header line).
class SenseLiveLine extends StatelessWidget {
  const SenseLiveLine({super.key, required this.text, this.level = SenseLevel.ok});
  final String text;
  final SenseLevel level;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: kSenseStatusTopGap),
        child: Align(alignment: Alignment.centerLeft, child: SenseLiveStatus(text: text, level: level)),
      );
}

/// Loading / no panel info / failed + Yeniden dene.
class SenseStatusMessage extends StatelessWidget {
  const SenseStatusMessage({super.key, required this.text, this.onRetry, this.busy = false});
  final String text;
  final VoidCallback? onRetry;
  final bool busy;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: _kCardGap),
        child: Row(children: [
          if (busy) ...[const SenseSpinner(), const SizedBox(width: _kMeterGap)],
          Expanded(child: Text(text, style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted))),
          if (onRetry != null)
            SenseButton(key: const Key('sense-status-retry'), label: SenseStatusStrings.retry, onPressed: onRetry),
        ]),
      );
}
