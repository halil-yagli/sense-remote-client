// Sense Remote: waiting mark (YH T4 "Dönen işaret 0,9 s linear"; prototype `.spin`).
// A ring with a white top quarter. Stops when the platform turns animations off.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';

// Prototype `.spin` 13 px (11 px inline), ring 2 px.
const double _kRing = 2;

class SenseSpinner extends StatefulWidget {
  const SenseSpinner({super.key, this.size = 13, this.color, this.semanticLabel});

  final double size;

  /// Moving part; default white. The ring is the strong line colour.
  final Color? color;
  final String? semanticLabel;

  @override
  State<SenseSpinner> createState() => _SenseSpinnerState();
}

class _SenseSpinnerState extends State<SenseSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: SenseMotion.spinner.duration);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final off = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (off) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: widget.semanticLabel,
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => CustomPaint(
              painter: _SpinnerPainter(_c.value, widget.color ?? SenseColors.text),
            ),
          ),
        ),
      );
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(_kRing / 2);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kRing
      ..color = SenseColors.lineStrong;
    canvas.drawOval(rect, ring);
    final start = -math.pi * 3 / 4 + t * math.pi * 2;
    canvas.drawArc(rect, start, math.pi / 2, false, ring..color = color);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.t != t || old.color != color;
}
