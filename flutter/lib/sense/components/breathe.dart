// Sense Remote: endless opacity pulses (YH T4). "Nefes" (breathe) fades the
// splash / connection-layer logo to 0.55 and back over 2.2–2.4 s; "yanıp sönme"
// (blink, blink.dart) fades red dots to 0.3 over 1–1.4 s. No rotation, no scale.
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';

/// Opacity of a CSS keyframe pulse (`@keyframes x{50%{opacity:min}}`) at loop
/// position [t] (0..1). The curve runs on each half, like the CSS timing function.
double sensePulseOpacity(double t, {required double min, required Curve curve}) {
  final p = t - t.floorToDouble();
  if (p < 0.5) return 1 - (1 - min) * curve.transform(p * 2);
  return min + (1 - min) * curve.transform(p * 2 - 1);
}

/// Repeats an opacity pulse on [child] while [enabled]. With animations turned
/// off by the system (MediaQuery.disableAnimations) the child stays still.
class SensePulse extends StatefulWidget {
  const SensePulse({
    super.key,
    required this.child,
    required this.spec,
    required this.minOpacity,
    this.enabled = true,
  });

  final Widget child;
  final SenseMotionSpec spec;
  final double minOpacity;
  final bool enabled;

  @override
  State<SensePulse> createState() => _SensePulseState();
}

class _SensePulseState extends State<SensePulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.spec.duration);

  bool get _running =>
      widget.enabled && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SensePulse old) {
    super.didUpdateWidget(old);
    if (old.spec.duration != widget.spec.duration) _c.duration = widget.spec.duration;
    _sync();
  }

  void _sync() {
    if (_running) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: sensePulseOpacity(_c.value, min: widget.minOpacity, curve: widget.spec.curve),
        child: child,
      ),
    );
  }
}

/// Breathing logo (YH T4 "Nefes"): 2.2 s by default (splash, T8); the
/// connection layer uses [SenseMotion.breathe] (2.4 s).
class SenseBreathe extends StatelessWidget {
  const SenseBreathe({
    super.key,
    required this.child,
    this.spec = SenseMotion.breatheFast,
    this.enabled = true,
  });

  final Widget child;
  final SenseMotionSpec spec;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SensePulse(
        spec: spec,
        minOpacity: SenseMotionParams.breatheOpacityMin,
        enabled: enabled,
        child: child,
      );
}
