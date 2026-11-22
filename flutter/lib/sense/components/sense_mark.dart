// Sense Remote: the transparent Sense mark (YH T5). No base plate, no frame.
// Drawn from the same path as assets/sense/mark_*.svg, so it is synchronous
// (no asset loading), takes any colour and renders the same in golden tests.
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';

/// Which part of the mark is drawn.
enum SenseMarkShape {
  /// Both halves (assets/sense/mark_white.svg, mark_black.svg).
  full,

  /// Right half only: the sign on the Sense island (assets/sense/mark_half.svg).
  half,
}

/// The Sense mark, transparent. Default size is the splash size (72 × 66).
class SenseMark extends StatelessWidget {
  const SenseMark({
    super.key,
    this.width = defaultWidth,
    this.height = defaultHeight,
    this.color = SenseColors.text,
    this.shape = SenseMarkShape.full,
    this.semanticLabel,
  });

  /// Splash logo size (prototype `.asplash svg`).
  static const double defaultWidth = 72;
  static const double defaultHeight = 66;

  final double width;
  final double height;
  final Color color;
  final SenseMarkShape shape;

  /// Read by screen readers; null hides the mark from them (decorative).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox(
      width: width,
      height: height,
      child: CustomPaint(painter: SenseMarkPainter(color: color, shape: shape)),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: mark);
    return Semantics(label: semanticLabel, image: true, child: mark);
  }
}

/// Paints the mark, scaled to fit (aspect kept) and centred.
class SenseMarkPainter extends CustomPainter {
  const SenseMarkPainter({required this.color, required this.shape});

  final Color color;
  final SenseMarkShape shape;

  /// The crop the prototype uses (`viewBox="187 78 468 440"` / `"410 180 260 350"`).
  static const Rect fullBox = Rect.fromLTWH(187, 78, 468, 440);
  static const Rect halfBox = Rect.fromLTWH(410, 180, 260, 350);

  /// Right half: `M532.14,496.37 l101.64-101.65 …` of the Drive SVG.
  static Path rightHalf() => Path()
    ..moveTo(532.14, 496.37)
    ..relativeLineTo(101.64, -101.65)
    ..relativeCubicTo(25.55, -25.56, 25.55, -66.99, 0, -92.54)
    ..relativeLineTo(-101.64, -101.64)
    ..relativeCubicTo(-41.22, -41.22, -111.71, -12.03, -111.71, 46.27)
    ..relativeCubicTo(0, 17.36, 6.89, 34, 19.17, 46.27)
    ..relativeLineTo(3.72, 3.72)
    ..relativeCubicTo(28.52, 28.52, 28.52, 74.76, 0, 103.28)
    ..relativeLineTo(-3.72, 3.72)
    ..relativeCubicTo(-12.27, 12.27, -19.17, 28.92, -19.17, 46.27)
    ..relativeLineTo(0, 0.02)
    ..relativeCubicTo(0, 58.3, 70.49, 87.5, 111.71, 46.27)
    ..close();

  /// Left half: `M309.75,98.9 l-101.64,101.65 …` (the right half turned half a
  /// turn around the page centre; written out like the SVG).
  static Path leftHalf() => Path()
    ..moveTo(309.75, 98.9)
    ..relativeLineTo(-101.64, 101.65)
    ..relativeCubicTo(-25.55, 25.56, -25.55, 66.99, 0, 92.54)
    ..relativeLineTo(101.64, 101.64)
    ..relativeCubicTo(41.22, 41.22, 111.71, 12.03, 111.71, -46.27)
    ..relativeCubicTo(0, -17.36, -6.89, -34, -19.17, -46.27)
    ..relativeLineTo(-3.72, -3.72)
    ..relativeCubicTo(-28.52, -28.52, -28.52, -74.76, 0, -103.28)
    ..relativeLineTo(3.72, -3.72)
    ..relativeCubicTo(12.27, -12.27, 19.17, -28.92, 19.17, -46.27)
    ..relativeLineTo(0, -0.02)
    ..relativeCubicTo(0, -58.3, -70.49, -87.5, -111.71, -46.27)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final box = shape == SenseMarkShape.full ? fullBox : halfBox;
    final scale = (size.width / box.width) < (size.height / box.height)
        ? size.width / box.width
        : size.height / box.height;
    final dx = (size.width - box.width * scale) / 2;
    final dy = (size.height - box.height * scale) / 2;
    canvas
      ..save()
      ..translate(dx, dy)
      ..scale(scale)
      ..translate(-box.left, -box.top);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    canvas.drawPath(rightHalf(), paint);
    if (shape == SenseMarkShape.full) canvas.drawPath(leftHalf(), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SenseMarkPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.shape != shape;
}
