// Sense Remote: one object = one card (YH T7; prototype `.sc`, `.sc-h`, `.copy2`, `.r`).
// A disk, network adapter, screen or file is a card with its own Kopyala button.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';
import 'led.dart';
import 'stat_tile.dart' show kSenseUnreadable;

// Texts (only Turkish, T2); move to strings/common.dart with A2b.
const String kSenseCopy = 'Kopyala';
const String kSenseCopied = 'Kopyalandı';

// Prototype `.sc` padding 7×9, header gap 6 / bottom 3, status dot 8;
// `.copy2` corner 6, padding 3×8; `.r` padding 3, gap 10.
const double _kPadV = 7, _kPadH = 9, _kHeadGap = 6, _kHeadBottom = 3, _kDot = 8;
const double _kCopyRadius = 6, _kCopyPadV = 3, _kCopyPadH = 8;
const double _kRowPadV = 3, _kRowGap = 10;

class SenseCard extends StatelessWidget {
  const SenseCard({
    super.key,
    required this.title,
    required this.child,
    this.level,
    this.copyText,
    this.onCopied,
    this.trailing,
    this.tags = const <Widget>[],
  });

  final String title;
  final Widget child;

  /// Null = no status dot, plain frame. warn / hot also tint the frame.
  final SenseLevel? level;

  /// Set = the card has a Kopyala button that copies this text.
  final String? copyText;
  final VoidCallback? onCopied;

  /// Extra widget in the header, before Kopyala (right-aligned).
  final Widget? trailing;

  /// Small labels right after the title ("NVMe", "SSD"). The title takes the free
  /// space first and only ends in "…" when it really does not fit (G7).
  final List<Widget> tags;

  Color _border() {
    switch (level) {
      case SenseLevel.warn:
        return SenseColors.warn.withOpacity(0.45);
      case SenseLevel.hot:
        return SenseColors.hot.withOpacity(0.55);
      default:
        return SenseColors.line;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lvl = level;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: _kPadV, horizontal: _kPadH),
      decoration: BoxDecoration(
        border: Border.all(color: _border()),
        borderRadius: BorderRadius.circular(SenseRadii.button),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: _kHeadBottom),
            child: Row(
              children: [
                if (lvl != null) ...[
                  SenseLed(level: lvl, size: _kDot, glow: lvl == SenseLevel.hot, blink: false),
                  const SizedBox(width: _kHeadGap),
                ],
                Expanded(
                  child: SenseTitleWithTags(
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.bold),
                    ),
                    tags: tags,
                    gap: _kHeadGap,
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: _kHeadGap), trailing!],
                if (copyText != null) ...[
                  const SizedBox(width: _kHeadGap),
                  SenseCopyButton(text: copyText!, onCopied: onCopied),
                ],
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// A one-line title followed by small tags, inside the room it is given.
///
/// The tags keep their own width (never cut) and the title gets everything else, so
/// a long name ("Samsung SSD 980 PRO 1TB") is shown in full while there is room and
/// ends in "…" only when it really does not fit (G7). Avoids the `Flexible` + `Spacer`
/// pair, which splits the free space in half and cuts the title too early.
class SenseTitleWithTags extends StatelessWidget {
  const SenseTitleWithTags({super.key, required this.title, this.tags = const <Widget>[], this.gap = _kHeadGap});

  /// Usually a `Text` with `maxLines: 1` and `TextOverflow.ellipsis`.
  final Widget title;
  final List<Widget> tags;
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return title;
    return Row(
      children: [
        Flexible(child: title),
        for (final t in tags) ...[SizedBox(width: gap), t],
      ],
    );
  }
}

/// Small "Kopyala" button; after copying it says "Kopyalandı" for a moment.
class SenseCopyButton extends StatefulWidget {
  const SenseCopyButton({super.key, required this.text, this.onCopied, this.label = kSenseCopy});

  final String text;
  final VoidCallback? onCopied;
  final String label;

  @override
  State<SenseCopyButton> createState() => _SenseCopyButtonState();
}

class _SenseCopyButtonState extends State<SenseCopyButton> {
  bool _copied = false;
  Timer? _timer;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    widget.onCopied?.call();
    _timer?.cancel();
    setState(() => _copied = true);
    _timer = Timer(SenseMotion.savedHold.duration, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SenseInteractive(
        onTap: _copy,
        builder: (_, s) => SenseFocusRing(
          visible: s.focused,
          radius: _kCopyRadius,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: _kCopyPadV, horizontal: _kCopyPadH),
            decoration: BoxDecoration(
              color: s.hovered ? SenseColors.hover : SenseColors.bg,
              border: Border.all(color: SenseColors.line),
              borderRadius: BorderRadius.circular(_kCopyRadius),
            ),
            child: Text(
              _copied ? kSenseCopied : widget.label,
              style: SenseTextStyles.of(
                size: SenseFontSize.caps,
                weight: SenseFontWeight.medium,
                color: _copied
                    ? SenseColors.ok
                    : (s.hovered ? SenseColors.text : SenseColors.textMuted),
              ),
            ),
          ),
        ),
      );
}

/// "Label ··· value" line inside a card (`.r`). Null value = "okunamadı".
class SenseCardRow extends StatelessWidget {
  const SenseCardRow({super.key, required this.label, required this.value, this.level, this.last = false});

  final String label;
  final String? value;
  final SenseLevel? level;

  /// Last line: no dashed line under it.
  final bool last;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final TextStyle valueStyle;
    if (v == null) {
      valueStyle = SenseTextStyles.of(
          size: SenseFontSize.hintLarge, color: SenseColors.textMuted, fontStyle: FontStyle.italic);
    } else {
      switch (level) {
        case SenseLevel.warn:
          valueStyle = SenseTextStyles.of(
              size: SenseFontSize.hintLarge, weight: SenseFontWeight.bold, color: SenseColors.warn);
        case SenseLevel.hot:
          valueStyle = SenseTextStyles.of(
              size: SenseFontSize.hintLarge, weight: SenseFontWeight.bold, color: SenseColors.dangerText);
        default:
          valueStyle = SenseTextStyles.of(size: SenseFontSize.hintLarge);
      }
    }
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: _kRowPadV),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
          const SizedBox(width: _kRowGap),
          Expanded(
            child: Text(v ?? kSenseUnreadable, textAlign: TextAlign.right, style: valueStyle),
          ),
        ],
      ),
    );
    if (last) return row;
    return CustomPaint(painter: _RowLine(), child: row);
  }
}

class _RowLine extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Prototype `border-bottom:1px dashed #1b1b22`; nearest token is hover.
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
  bool shouldRepaint(_RowLine old) => false;
}
