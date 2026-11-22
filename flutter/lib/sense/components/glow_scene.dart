// Sense Remote: black background with the soft navy / purple glow (YH T1
// "Işıma": only big scenes: splash, maintenance curtain, connection layer,
// install and panel sign-in background).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';

/// One elliptic glow, like CSS `radial-gradient(ellipse at X Y, color, transparent stop)`
/// (ellipse sized to the farthest corner, as CSS does by default).
class SenseGlowSpot {
  const SenseGlowSpot({
    required this.center,
    required this.color,
    required this.opacity,
    required this.fadeAt,
  });

  /// Centre in fractions of the box (0..1, 0..1).
  final Offset center;
  final Color color;
  final double opacity;

  /// Where the glow has fully faded (0..1 of the ellipse radius).
  final double fadeAt;
}

enum SenseGlowStyle {
  /// Splash (T8, `.asplash`): one navy glow at 50 % / 45 %, opacity .45, fades at 60 %.
  splash,

  /// Large scene (`.screen`): navy at 35 % / 45 % (.5) and purple at 75 % / 70 % (.3).
  scene,
}

class SenseGlowScene extends StatelessWidget {
  const SenseGlowScene({super.key, this.style = SenseGlowStyle.splash, this.child});

  final SenseGlowStyle style;
  final Widget? child;

  static const List<SenseGlowSpot> splashSpots = [
    SenseGlowSpot(center: Offset(0.5, 0.45), color: SenseColors.glowStart, opacity: 0.45, fadeAt: 0.6),
  ];

  static const List<SenseGlowSpot> sceneSpots = [
    SenseGlowSpot(center: Offset(0.35, 0.45), color: SenseColors.glowStart, opacity: 0.5, fadeAt: 0.6),
    SenseGlowSpot(center: Offset(0.75, 0.70), color: SenseColors.glowEnd, opacity: 0.3, fadeAt: 0.55),
  ];

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: SenseGlowPainter(style == SenseGlowStyle.splash ? splashSpots : sceneSpots),
      child: child ?? const SizedBox.expand(),
    );
  }
}

class SenseGlowPainter extends CustomPainter {
  const SenseGlowPainter(this.spots);

  final List<SenseGlowSpot> spots;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = SenseColors.bg);
    if (size.isEmpty) return;
    // CSS paints the first gradient on top; draw from the last to the first.
    for (final s in spots.reversed) {
      final c = Offset(s.center.dx * size.width, s.center.dy * size.height);
      final dx = math.max(c.dx, size.width - c.dx);
      final dy = math.max(c.dy, size.height - c.dy);
      // farthest-corner ellipse keeps the box's aspect: rx = dx·√2, ry = dy·√2.
      final rx = dx * math.sqrt2;
      final ry = dy * math.sqrt2;
      final m = Matrix4.identity()
        ..translate(c.dx, c.dy)
        ..scale(1.0, ry / rx)
        ..translate(-c.dx, -c.dy);
      final shader = ui.Gradient.radial(
        c,
        rx,
        [s.color.withOpacity(s.opacity), s.color.withOpacity(0)],
        [0, s.fadeAt],
        ui.TileMode.clamp,
        m.storage,
      );
      canvas.drawRect(rect, Paint()..shader = shader);
    }
  }

  @override
  bool shouldRepaint(SenseGlowPainter oldDelegate) => oldDelegate.spots != spots;
}
