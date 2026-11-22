// Sense Remote: status light (YH T3 9 px, T4 blink, T6 levels; prototype `.led`).
// Green / orange / red with a soft glow; red blinks; an unreadable value is a hollow
// ring (never a guessed colour).
import 'package:flutter/material.dart';

import '../tokens/sense_tokens.dart';

// Prototype glow radius per level (`box-shadow:0 0 6px / 7px / 8px`) and its strength.
const double _kGlowOk = 6, _kGlowWarn = 7, _kGlowHot = 8, _kRingWidth = 1.5;

class SenseLed extends StatefulWidget {
  const SenseLed({
    super.key,
    required this.level,
    this.size = SenseSizes.led,
    this.glow = true,
    this.blink,
    this.tooltip,
  });

  final SenseLevel level;
  final double size;

  /// False = flat dot (the 7 px "Canlı" dot of a header).
  final bool glow;

  /// Null = blink only when [level] is hot (T4). Animations are off when the
  /// platform asks for it (MediaQuery.disableAnimations).
  final bool? blink;
  final String? tooltip;

  @override
  State<SenseLed> createState() => _SenseLedState();
}

class _SenseLedState extends State<SenseLed> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: SenseMotion.blinkSlow.duration);

  bool _shouldBlink(BuildContext context) =>
      (widget.blink ?? widget.level == SenseLevel.hot) &&
      !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SenseLed old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (_shouldBlink(context)) {
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

  BoxDecoration _decoration() {
    final level = widget.level;
    if (level == SenseLevel.unknown) {
      return BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: SenseColors.textDim, width: _kRingWidth),
      );
    }
    final color = level.color;
    final blur = switch (level) {
      SenseLevel.ok => _kGlowOk,
      SenseLevel.warn => _kGlowWarn,
      _ => _kGlowHot,
    };
    final strength = switch (level) {
      SenseLevel.ok => 0.7,
      SenseLevel.warn => 0.8,
      _ => 0.9,
    };
    return BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: widget.glow
          ? [BoxShadow(color: color.withOpacity(strength), blurRadius: blur)]
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget dot = SizedBox.square(
      dimension: widget.size,
      child: DecoratedBox(decoration: _decoration()),
    );
    dot = AnimatedBuilder(
      animation: _c,
      child: dot,
      builder: (context, child) {
        // Keyframes 0 % and 100 % fully on, 50 % at the lowest opacity.
        final t = _c.value;
        final wave = t < 0.5 ? t * 2 : (1 - t) * 2;
        final min = SenseMotionParams.blinkOpacityMin;
        return Opacity(opacity: 1 - (1 - min) * wave, child: child);
      },
    );
    final tip = widget.tooltip;
    if (tip != null && tip.isNotEmpty) {
      dot = Tooltip(message: tip, child: dot);
    }
    return Semantics(label: tip, child: dot);
  }
}
