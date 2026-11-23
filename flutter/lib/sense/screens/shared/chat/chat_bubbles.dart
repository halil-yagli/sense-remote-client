// Sense Remote: chat bubbles (YH O10, O12; onaylı sohbet `.msg`, `.msg.file`,
// `.ring`). Own message: white bubble on the right, black text; the other
// side: raised dark bubble on the left. Under the text "ad · saat".

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/chat.dart';
import 'chat_entry.dart';

/// Bubble measures (`.msg{max-width:85%;padding:8px 11px;border-radius:12px;margin:6px 0}`).
abstract final class SenseChatBubbleSize {
  static const double maxWidthFactor = 0.85;
  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 11, vertical: 8);
  static const double radius = 12;
  static const double tail = 4;
  static const double gap = 6;
  static const double metaGap = 3;
  static const double metaOpacity = 0.55;
  static const double fileMinWidth = 250;
  static const double ring = 38;
  static const double ringStroke = 3;
  static const double ringArrow = 20;
  static const double ringGap = 10;
}

/// Green of a finished file on a white bubble: the ok colour darkened so it
/// reads on white (prototype `#00a87a`).
Color senseFileDoneOnWhite() => Color.lerp(SenseColors.ok, SenseColors.bg, 0.34)!;

/// Shell shared by text and file bubbles.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.mine, required this.child, this.minWidth = 0});

  final bool mine;
  final Widget child;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(SenseChatBubbleSize.radius);
    const t = Radius.circular(SenseChatBubbleSize.tail);
    return LayoutBuilder(builder: (context, c) {
      final max = c.maxWidth.isFinite ? c.maxWidth * SenseChatBubbleSize.maxWidthFactor : 360.0;
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          key: const Key('sense-bubble'),
          margin: const EdgeInsets.symmetric(vertical: SenseChatBubbleSize.gap / 2),
          padding: SenseChatBubbleSize.padding,
          constraints: BoxConstraints(maxWidth: max, minWidth: math.min(minWidth, max)),
          decoration: BoxDecoration(
            color: mine ? SenseColors.text : SenseColors.raised,
            borderRadius: BorderRadius.only(
              topLeft: r,
              topRight: r,
              bottomLeft: mine ? r : t,
              bottomRight: mine ? t : r,
            ),
          ),
          child: DefaultTextStyle(
            style: TextStyle(
              fontFamily: SenseFont.family,
              fontSize: SenseFontSize.body,
              height: 1.45,
              color: mine ? SenseColors.bg : SenseColors.text,
            ),
            child: child,
          ),
        ),
      );
    });
  }
}

/// "Sen · 17:11" under a bubble (`.msg small`).
class _Meta extends StatelessWidget {
  const _Meta({required this.text, required this.mine});

  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: SenseChatBubbleSize.metaGap),
      child: Opacity(
        opacity: SenseChatBubbleSize.metaOpacity,
        child: Text(
          text,
          style: TextStyle(
            fontFamily: SenseFont.family,
            fontSize: SenseFontSize.capsSmall,
            height: 1.3,
            color: mine ? SenseColors.bg : SenseColors.text,
          ),
        ),
      ),
    );
  }
}

class SenseChatBubble extends StatelessWidget {
  const SenseChatBubble({
    super.key,
    required this.text,
    required this.author,
    required this.time,
    required this.mine,
  });

  final String text;
  final String author;
  final String time;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return _Bubble(
      mine: mine,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(text),
          _Meta(text: '$author · $time', mine: mine),
        ],
      ),
    );
  }
}

/// File bubble (O12): ring with an arrow (up when sending, down when
/// receiving; it bobs while running), name, state line; when done a green ✓,
/// and on the receiving side "Klasörde göster".
class SenseFileBubble extends StatelessWidget {
  const SenseFileBubble({
    super.key,
    required this.job,
    required this.author,
    required this.time,
    this.onReveal,
  });

  final SenseFileJob job;
  final String author;
  final String time;

  /// "Klasörde göster"; shown only for a finished received file.
  final VoidCallback? onReveal;

  @override
  Widget build(BuildContext context) {
    final mine = job.mine;
    final fg = mine ? SenseColors.bg : SenseColors.text;
    final failed = job.state == SenseFileState.err;
    return _Bubble(
      mine: mine,
      minWidth: SenseChatBubbleSize.fileMinWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SenseFileRing(
                key: Key('sense-file-ring-${job.id}'),
                progress: job.progress,
                up: mine,
                done: job.finished,
                color: fg,
                doneColor: mine ? senseFileDoneOnWhite() : SenseColors.ok,
              ),
              const SizedBox(width: SenseChatBubbleSize.ringGap),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      job.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: SenseFontWeight.bold),
                    ),
                    Opacity(
                      opacity: failed ? 1 : 0.7,
                      child: Text(
                        senseFileLine(job),
                        key: Key('sense-file-line-${job.id}'),
                        style: TextStyle(
                          fontSize: SenseFontSize.hintSmall,
                          height: 1.4,
                          color: failed ? (mine ? SenseColors.danger : SenseColors.dangerText) : null,
                        ),
                      ),
                    ),
                    if (job.finished && !mine && onReveal != null)
                      _RevealLink(key: Key('sense-file-reveal-${job.id}'), onTap: onReveal!),
                  ],
                ),
              ),
            ],
          ),
          _Meta(text: '$author · $time', mine: mine),
        ],
      ),
    );
  }
}

class _RevealLink extends StatelessWidget {
  const _RevealLink({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SenseInteractive(
      onTap: onTap,
      builder: (context, s) => Opacity(
        opacity: s.hovered || s.focused ? 1 : 0.85,
        child: const Text(
          SenseChatStrings.showInFolder,
          style: TextStyle(
            fontSize: SenseFontSize.hintSmall,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}

/// 38 px ring: grey track, progress arc from the top; arrow inside bobs
/// 3 px for 1 s while running; a ✓ when done (`.ring`, `@keyframes upb/dnb`).
class SenseFileRing extends StatefulWidget {
  const SenseFileRing({
    super.key,
    required this.progress,
    required this.up,
    required this.done,
    required this.color,
    required this.doneColor,
  });

  final double progress;
  final bool up;
  final bool done;
  final Color color;
  final Color doneColor;

  @override
  State<SenseFileRing> createState() => _SenseFileRingState();
}

class _SenseFileRingState extends State<SenseFileRing> with SingleTickerProviderStateMixin {
  late final AnimationController _bob =
      AnimationController(vsync: this, duration: SenseMotion.fileArrow.duration);

  @override
  void didUpdateWidget(SenseFileRing old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  void _sync() {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.done || still || !TickerMode.of(context)) {
      _bob.stop();
      _bob.value = 0;
    } else if (!_bob.isAnimating) {
      _bob.repeat();
    }
  }

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: SenseChatBubbleSize.ring,
      height: SenseChatBubbleSize.ring,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.progress),
        duration: SenseMotion.fileRing.duration,
        curve: SenseMotion.fileRing.curve,
        builder: (context, p, _) => AnimatedBuilder(
          animation: _bob,
          builder: (context, _) {
            // 0 → 1 → 0 over one period (`50%{transform:translateY(±3px)}`).
            final wave = SenseMotion.fileArrow.curve
                .transform(1 - (2 * _bob.value - 1).abs());
            final dy = (widget.up ? -1 : 1) * SenseMotionParams.fileArrowOffset * wave;
            return CustomPaint(
              painter: SenseFileRingPainter(
                progress: widget.done ? 1 : p,
                color: widget.color,
                doneColor: widget.doneColor,
                done: widget.done,
                up: widget.up,
                arrowDy: widget.done ? 0 : dy,
              ),
            );
          },
        ),
      ),
    );
  }
}

class SenseFileRingPainter extends CustomPainter {
  const SenseFileRingPainter({
    required this.progress,
    required this.color,
    required this.doneColor,
    required this.done,
    required this.up,
    required this.arrowDy,
  });

  final double progress;
  final Color color;
  final Color doneColor;
  final bool done;
  final bool up;
  final double arrowDy;

  @override
  void paint(Canvas canvas, Size size) {
    // viewBox 36, r 15, stroke 3 (`.ring circle`).
    final s = size.width / 36;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = 15 * s;
    final stroke = SenseChatBubbleSize.ringStroke * s;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = SenseColors.textMuted.withOpacity(0.28);
    canvas.drawCircle(center, radius, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = done ? doneColor : color;
    if (progress > 0) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2,
          2 * math.pi * progress.clamp(0.0, 1.0), false, arc);
    }
    // 20 px glyph in a 24 viewBox, centred (`svg.ar{inset:9px}`).
    final g = SenseChatBubbleSize.ringArrow * s / 24;
    final origin = Offset(center.dx - 12 * g, center.dy - 12 * g + arrowDy);
    Offset p(double x, double y) => origin + Offset(x * g, y * g);
    final glyph = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2 * g
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    final path = Path();
    if (done) {
      path
        ..moveTo(p(6, 12.5).dx, p(6, 12.5).dy)
        ..lineTo(p(10, 16.5).dx, p(10, 16.5).dy)
        ..lineTo(p(18, 7.5).dx, p(18, 7.5).dy);
    } else if (up) {
      path
        ..moveTo(p(12, 18).dx, p(12, 18).dy)
        ..lineTo(p(12, 6).dx, p(12, 6).dy)
        ..moveTo(p(7, 11).dx, p(7, 11).dy)
        ..lineTo(p(12, 6).dx, p(12, 6).dy)
        ..lineTo(p(17, 11).dx, p(17, 11).dy);
    } else {
      path
        ..moveTo(p(12, 6).dx, p(12, 6).dy)
        ..lineTo(p(12, 18).dx, p(12, 18).dy)
        ..moveTo(p(7, 13).dx, p(7, 13).dy)
        ..lineTo(p(12, 18).dx, p(12, 18).dy)
        ..lineTo(p(17, 13).dx, p(17, 13).dy);
    }
    canvas.drawPath(path, glyph);
  }

  @override
  bool shouldRepaint(SenseFileRingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.doneColor != doneColor ||
      old.done != done ||
      old.up != up ||
      old.arrowDy != arrowDy;
}

/// The faded note at the top of the messages (#56).
class SenseChatWipeNote extends StatelessWidget {
  const SenseChatWipeNote({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 2, bottom: 6),
      child: Text(
        SenseChatStrings.wipeNote,
        key: Key('sense-chat-wipe-note'),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: SenseFont.family,
          fontSize: SenseFontSize.hintSmall,
          color: SenseColors.textDim,
        ),
      ),
    );
  }
}
