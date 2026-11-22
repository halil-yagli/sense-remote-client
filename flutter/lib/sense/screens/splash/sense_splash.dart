// Sense Remote: opening screen (YH T8, img/a08.png; prototype `.asplash`).
// Black ground with a soft navy glow, the transparent mark breathing (2.2 s),
// grey "Sense Remote açılıyor" under it and a thin loading line. After an
// update the text is "Sürüm N kuruluyor · Sense Remote yeniden açılıyor".
// Fades in over 0.3 s (T4 "Katman belirmesi"). A2c shows it from main.dart.
import 'package:flutter/widgets.dart';

import '../../components/breathe.dart';
import '../../components/glow_scene.dart';
import '../../components/sense_mark.dart';
import '../../strings/common.dart';
import '../../tokens/sense_tokens.dart';

class SenseSplash extends StatefulWidget {
  const SenseSplash({super.key, this.updatingToVersion, this.animate = true});

  /// Set while an update is being installed: shows the update text.
  final int? updatingToVersion;

  /// False draws one still frame (no fade, no breathing, line at rest).
  final bool animate;

  /// Gap between the mark, the text and the line (`.asplash{gap:16px}`).
  static const double gap = 16;

  static String textFor(int? updatingToVersion) => updatingToVersion == null
      ? SenseCommonStrings.splashOpening
      : SenseCommonStrings.splashUpdating(updatingToVersion);

  @override
  State<SenseSplash> createState() => _SenseSplashState();
}

class _SenseSplashState extends State<SenseSplash> with SingleTickerProviderStateMixin {
  late final AnimationController _fade =
      AnimationController(vsync: this, duration: SenseMotion.layerFade.duration);
  late final Animation<double> _opacity =
      CurvedAnimation(parent: _fade, curve: SenseMotion.layerFade.curve);

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _fade.forward();
    } else {
      _fade.value = 1;
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = SenseSplash.textFor(widget.updatingToVersion);
    return FadeTransition(
      opacity: _opacity,
      child: SenseGlowScene(
        style: SenseGlowStyle.splash,
        child: Center(
          child: Semantics(
            liveRegion: true,
            label: text,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SenseBreathe(
                  enabled: widget.animate,
                  child: const SenseMark(key: Key('sense-splash-mark')),
                ),
                const SizedBox(height: SenseSplash.gap),
                ExcludeSemantics(
                  child: Text(
                    text,
                    key: const Key('sense-splash-text'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: SenseFont.family,
                      fontSize: SenseFontSize.body,
                      fontWeight: SenseFontWeight.regular,
                      color: SenseColors.textMuted,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                const SizedBox(height: SenseSplash.gap),
                SenseLoadingLine(animate: widget.animate),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin loading line (`.abar`): 140 × 2 track, a 40 % white bar sliding from
/// −100 % to +260 % of its own width every 1.2 s (`@keyframes slide`).
class SenseLoadingLine extends StatefulWidget {
  const SenseLoadingLine({super.key, this.animate = true});

  final bool animate;

  static const double width = 140;
  static const double height = 2;
  static const double barFraction = 0.4;

  /// Left edge of the bar, in px from the track's left, at loop position [t].
  static double barLeft(double t) {
    final v = SenseMotion.loadingLine.curve.transform(t - t.floorToDouble());
    final bar = width * barFraction;
    return bar * (-1 + 3.6 * v);
  }

  @override
  State<SenseLoadingLine> createState() => _SenseLoadingLineState();
}

class _SenseLoadingLineState extends State<SenseLoadingLine> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: SenseMotion.loadingLine.duration);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = !widget.animate || (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (still) {
      _c
        ..stop()
        ..value = 0.5;
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
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(SenseLoadingLine.height),
      child: Container(
        key: const Key('sense-loading-line'),
        width: SenseLoadingLine.width,
        height: SenseLoadingLine.height,
        color: SenseColors.raised,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Stack(clipBehavior: Clip.none, children: [
            Positioned(
              key: const Key('sense-loading-bar'),
              left: SenseLoadingLine.barLeft(_c.value),
              top: 0,
              width: SenseLoadingLine.width * SenseLoadingLine.barFraction,
              height: SenseLoadingLine.height,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: SenseColors.text,
                  borderRadius: BorderRadius.circular(SenseLoadingLine.height),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
