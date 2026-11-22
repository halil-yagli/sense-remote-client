// Sense Remote: blinking dot (YH T4 "Yanıp sönme"): red LED, recording dot,
// transfer dot, incoming-call dot. Opacity 1 → 0.3 → 1 over 1–1.4 s.
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import 'breathe.dart';

class SenseBlink extends StatelessWidget {
  const SenseBlink({
    super.key,
    required this.child,
    this.spec = SenseMotion.blink,
    this.enabled = true,
  });

  final Widget child;

  /// [SenseMotion.blink] (1.2 s), [SenseMotion.blinkFast] (1 s) or
  /// [SenseMotion.blinkSlow] (1.4 s).
  final SenseMotionSpec spec;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SensePulse(
        spec: spec,
        minOpacity: SenseMotionParams.blinkOpacityMin,
        enabled: enabled,
        child: child,
      );
}

/// A round status dot, optionally blinking (recording dot: `.cat .rec`, 8 px).
class SenseStatusDot extends StatelessWidget {
  const SenseStatusDot({
    super.key,
    this.color = SenseColors.hot,
    this.size = 8,
    this.blinking = false,
    this.glow = false,
  });

  final Color color;
  final double size;
  final bool blinking;

  /// Soft halo of the same colour (hot category dot: `box-shadow:0 0 8px`).
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: glow ? [BoxShadow(color: color, blurRadius: size)] : null,
      ),
    );
    return blinking ? SenseBlink(child: dot) : dot;
  }
}
