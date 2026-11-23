// Sense Remote: the small category / list caret (prototype `.cg-h .ch` ▶, `.sel` ▾).
// Drawn, not a glyph: Poppins has no ▶ ▼ ▾, so the text caret fell back to a missing-glyph
// box. Closed ▶, open ▼; it swaps without turning (T4).
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';

enum SenseCaretDirection { right, down }

class SenseCaret extends StatelessWidget {
  const SenseCaret({
    super.key,
    required this.direction,
    this.size = 9,
    this.color = SenseColors.textDim,
    this.small = false,
  });

  final SenseCaretDirection direction;

  /// Box edge in logical px (the prototype's caret font size).
  final double size;
  final Color color;

  /// The flatter ▾ of a list button (instead of ▼).
  final bool small;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: CustomPaint(
          size: Size.square(size),
          painter: _CaretPainter(direction, color, small),
        ),
      );
}

class _CaretPainter extends CustomPainter {
  _CaretPainter(this.direction, this.color, this.small);

  final SenseCaretDirection direction;
  final Color color;
  final bool small;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    // A glyph triangle is a bit smaller than its em box.
    final long = s * (small ? 0.4 : 0.7);
    final wide = s * (small ? 0.7 : 0.8);
    final path = Path();
    if (direction == SenseCaretDirection.right) {
      path
        ..moveTo(c.dx - long / 2, c.dy - wide / 2)
        ..lineTo(c.dx + long / 2, c.dy)
        ..lineTo(c.dx - long / 2, c.dy + wide / 2);
    } else {
      path
        ..moveTo(c.dx - wide / 2, c.dy - long / 2)
        ..lineTo(c.dx + wide / 2, c.dy - long / 2)
        ..lineTo(c.dx, c.dy + long / 2);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(_CaretPainter old) =>
      old.direction != direction || old.color != color || old.small != small;
}
