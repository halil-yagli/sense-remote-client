// Sense Remote: the Sense island (YH O2; prototype `.notch`). A black island grows out of
// the bottom edge of the bar, joined to it by concave shoulders. Inside: one half of the
// Sense mark, tip down, at 40 %. On hover it springs open (0.42 s, 52×20 → 116×28), the
// mark turns fully visible and flips (tip up; a flip, never a turn) and "Gizle" appears;
// pressing sinks it a little. With the bar hidden the island sits at the top of the
// screen, tip down at 55 %, "Göster".
import 'package:flutter/material.dart';

import '../../../components/sense_mark.dart';
import '../../../strings/session.dart';
import '../../../tokens/sense_tokens.dart';
import '../../../tokens/theme.dart';

/// Opacity of the mark (prototype: idle .4, hidden bar .55, hover 1).
const double kSenseIslandIdleOpacity = 0.4;
const double kSenseIslandHiddenOpacity = 0.55;
const double kSenseIslandPressScale = 0.96;
const double kSenseIslandIcon = 14;

class SenseIsland extends StatefulWidget {
  const SenseIsland({
    super.key,
    required this.barHidden,
    required this.onTap,
    this.forceHover = false,
  });

  /// The bar is hidden: "Göster", tip down, no flip.
  final bool barHidden;
  final VoidCallback onTap;

  /// Draws the open state without a pointer (golden images).
  final bool forceHover;

  /// Total width including the shoulders.
  static double outerWidth(bool open) =>
      (open ? SenseSizes.islandWidthHover : SenseSizes.islandWidth) + 2 * SenseSizes.islandShoulder;

  @override
  State<SenseIsland> createState() => _SenseIslandState();
}

class _SenseIslandState extends State<SenseIsland> {
  bool _hover = false;
  bool _focus = false;
  bool _down = false;

  bool get _open => _hover || _focus || widget.forceHover;

  @override
  Widget build(BuildContext context) {
    final open = _open;
    final expand = SenseMotion.islandExpand;
    final flip = SenseMotion.islandIconFlip;
    final w = open ? SenseSizes.islandWidthHover : SenseSizes.islandWidth;
    final h = open ? SenseSizes.islandHeightHover : SenseSizes.islandHeight;
    final radius = open ? 16.0 : 13.0;
    final flipped = open && !widget.barHidden;
    final opacity = open
        ? 1.0
        : widget.barHidden
            ? kSenseIslandHiddenOpacity
            : kSenseIslandIdleOpacity;
    final label = widget.barHidden ? SenseSessionStrings.islandShow : SenseSessionStrings.islandHide;

    final mark = AnimatedOpacity(
      duration: flip.duration,
      opacity: opacity,
      child: TweenAnimationBuilder<double>(
        key: const ValueKey('sense-island-flip'),
        tween: Tween(end: flipped ? -1.0 : 1.0),
        duration: flip.duration,
        curve: flip.curve,
        builder: (context, sy, child) => Transform(
          alignment: Alignment.center,
          transform: Matrix4.diagonal3Values(1, sy, 1),
          child: child,
        ),
        // The right half of the mark, laid on its side so the tip points down.
        child: const RotatedBox(
          quarterTurns: 1,
          child: SenseMark(
            width: kSenseIslandIcon,
            height: kSenseIslandIcon,
            shape: SenseMarkShape.half,
          ),
        ),
      ),
    );

    final text = AnimatedContainer(
      duration: expand.duration,
      curve: SenseCurves.ease,
      constraints: BoxConstraints(maxWidth: open ? 60 : 0),
      child: AnimatedOpacity(
        duration: flip.duration,
        opacity: open ? 1 : 0,
        child: Text(
          label,
          key: const ValueKey('sense-island-label'),
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: SenseTextStyles.of(
              size: SenseFontSize.hint, weight: SenseFontWeight.medium, color: SenseColors.textSecondary),
        ),
      ),
    );

    final body = AnimatedContainer(
      key: const ValueKey('sense-island-body'),
      duration: expand.duration,
      curve: expand.curve,
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: SenseColors.bg,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(radius)),
        boxShadow: [BoxShadow(color: SenseColors.bg.withOpacity(0.45), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: OverflowBox(
        maxWidth: SenseSizes.islandWidthHover,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            AnimatedContainer(duration: expand.duration, width: open ? 8 : 0),
            text,
          ],
        ),
      ),
    );

    return Semantics(
      button: true,
      label: SenseSessionStrings.islandLabel,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap();
            return null;
          }),
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
          key: const ValueKey('sense-island'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            duration: SenseMotion.popupOpen.duration,
            scale: _down ? kSenseIslandPressScale : 1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Shoulder(left: true),
                body,
                const _Shoulder(left: false),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}

/// The concave piece that joins the island to the bar (`.notch::before/::after`).
class _Shoulder extends StatelessWidget {
  const _Shoulder({required this.left});
  final bool left;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(SenseSizes.islandShoulder),
      painter: _ShoulderPainter(left: left),
    );
  }
}

class _ShoulderPainter extends CustomPainter {
  const _ShoulderPainter({required this.left});
  final bool left;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    // Black square minus a quarter circle whose centre is the outer bottom corner.
    final square = Path()..addRect(Offset.zero & size);
    final centre = left ? Offset(0, s) : Offset(s, s);
    final hole = Path()..addOval(Rect.fromCircle(center: centre, radius: s));
    canvas.drawPath(
      Path.combine(PathOperation.difference, square, hole),
      Paint()..color = SenseColors.bg,
    );
  }

  @override
  bool shouldRepaint(_ShoulderPainter old) => old.left != left;
}
