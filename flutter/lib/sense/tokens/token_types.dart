// Sense Remote: types the generated design tokens are built from (İnşa planı §4.3).
// Hand-written; values live in design/tokens.json and tokens.g.dart.
import 'package:flutter/animation.dart';

/// One named animation: how long it runs, its curve and whether it loops (YH T4).
class SenseMotionSpec {
  const SenseMotionSpec({
    required this.duration,
    required this.curve,
    required this.repeat,
  });

  final Duration duration;
  final Cubic curve;

  /// True for endless animations (breathe, blink, rings, spinner).
  final bool repeat;
}

/// Status colour level (YH T6). [unknown] is a value that could not be measured
/// ("okunamadı"): it is drawn faded, never guessed.
enum SenseLevel { unknown, ok, warn, hot }

/// Whether a bigger value is worse ([above]: usage, temperature, latency, loss)
/// or a smaller one ([below]: frame rate).
enum SenseThresholdDirection { above, below }

/// Orange / red limits of one measurement (YH T6). A value equal to a limit is
/// already in that level for [SenseThresholdDirection.above] ("%85" is orange);
/// for [SenseThresholdDirection.below] the level starts under the limit
/// ("15 fps altı").
class SenseThreshold {
  const SenseThreshold({
    required this.warn,
    required this.hot,
    required this.direction,
    required this.unit,
  });

  final double warn;
  final double hot;
  final SenseThresholdDirection direction;
  final String unit;

  SenseLevel levelOf(num? value) {
    if (value == null || value.isNaN) return SenseLevel.unknown;
    final v = value.toDouble();
    switch (direction) {
      case SenseThresholdDirection.above:
        if (v >= hot) return SenseLevel.hot;
        if (v >= warn) return SenseLevel.warn;
        return SenseLevel.ok;
      case SenseThresholdDirection.below:
        if (v < hot) return SenseLevel.hot;
        if (v < warn) return SenseLevel.warn;
        return SenseLevel.ok;
    }
  }
}
