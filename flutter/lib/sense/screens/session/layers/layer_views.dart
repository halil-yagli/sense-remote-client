// Sense Remote: the connection layers (YH O13 c11/c12, O14 n07, O15 n08).
// Prototype: `.netov`, `.nc`, `.nm/.nmv`, `.nth`, `.nre`, `.endov`, `.idlebar`.
import 'dart:ui' as ui;
import 'dart:ui' show FontFeature;

import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import 'layer_controller.dart';
import 'layer_spec.dart';
import 'layer_strings.dart';
import 'link_machine.dart';
import 'session_end.dart';

/// Everything below is blurred and darkened (`backdrop-filter: blur() brightness()`);
/// brightness b is a black veil at 1 − b. Clicks do not reach what is below.
class SenseLayerVeil extends StatelessWidget {
  const SenseLayerVeil({
    super.key,
    required this.blur,
    required this.brightness,
    required this.child,
    this.appear = 1,
  });

  final double blur;
  final double brightness;
  final Widget child;

  /// 0…1 while the layer fades in (YH T4 "Katman belirmesi"); the blur grows with it
  /// (an Opacity above a BackdropFilter would hide the blur).
  final double appear;

  @override
  Widget build(BuildContext context) {
    final sigma = blur * appear;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: ColoredBox(
          color: SenseColors.bg.withOpacity((1 - brightness) * appear),
          child: Center(child: Opacity(opacity: appear, child: child)),
        ),
      ),
    );
  }
}

/// The card of the layers (`.nc`).
class SenseLayerCard extends StatelessWidget {
  const SenseLayerCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: SenseLayerLook.cardMinWidth),
      padding: const EdgeInsets.fromLTRB(SenseLayerLook.cardPadSide, SenseLayerLook.cardPadTop,
          SenseLayerLook.cardPadSide, SenseLayerLook.cardPadBottom),
      decoration: BoxDecoration(
        color: SenseColors.surface.withOpacity(SenseLayerLook.cardOpacity),
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseLayerLook.cardRadius),
        boxShadow: [
          BoxShadow(
            color: SenseColors.bg.withOpacity(SenseLayerLook.cardShadowOpacity),
            blurRadius: SenseLayerLook.cardShadowBlur,
            offset: const Offset(0, SenseLayerLook.cardShadowY),
          ),
        ],
      ),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: _spaced(children),
        ),
      ),
    );
  }

  static List<Widget> _spaced(List<Widget> c) => [
        for (var i = 0; i < c.length; i++) ...[
          if (i > 0) const SizedBox(height: SenseLayerLook.cardGap),
          c[i],
        ],
      ];
}

Widget _logo({required bool breathe, double opacity = 1}) {
  final mark = Padding(
    padding: const EdgeInsets.only(bottom: SenseLayerLook.logoGap),
    child: Opacity(
      opacity: opacity,
      child: const SenseMark(
          width: SenseLayerLook.logoWidth, height: SenseLayerLook.logoHeight),
    ),
  );
  return breathe ? SenseBreathe(spec: SenseMotion.breathe, child: mark) : mark;
}

Widget _title(String text, Color color) => Text(
      text,
      textAlign: TextAlign.center,
      style: SenseTextStyles.of(
          size: SenseLayerLook.titleSize, weight: SenseFontWeight.bold, color: color),
    );

Widget _sub(String text) => Text(
      text,
      textAlign: TextAlign.center,
      style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted),
    );

Widget _tiles(List<Widget> tiles) => Padding(
      padding: const EdgeInsets.only(
          top: SenseLayerLook.tilesTop - SenseLayerLook.cardGap,
          bottom: SenseLayerLook.tilesBottom),
      child: Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: SenseLayerLook.tilesGap),
            Expanded(child: tiles[i]),
          ],
        ],
      ),
    );

/// "Çalışılabilir bağlantı: gecikme 150 ms altı · kayıp %2 altı · 15 fps üstü",
/// from the limit tokens (YH T6).
String senseWorkingLimitsText() {
  String n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  final l = SenseThresholds.latency, p = SenseThresholds.packetLoss, f = SenseThresholds.frameRate;
  return 'Çalışılabilir bağlantı: gecikme ${n(l.warn)} ${l.unit} altı · '
      'kayıp %${n(p.warn)} altı · ${n(f.warn)} ${f.unit} üstü';
}

Widget _statusLine(String text, {bool spinner = true, Color color = SenseColors.textSecondary}) =>
    Padding(
      padding: const EdgeInsets.only(top: SenseLayerLook.retryTop),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner) ...[
            const SenseSpinner(),
            const SizedBox(width: SenseLayerLook.retryGap),
          ],
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: color)
                  .copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );

/// O13 — "Bağlantı zayıf" / "Bağlantı kesildi".
class SenseLinkLayer extends StatelessWidget {
  const SenseLinkLayer({super.key, required this.view, required this.onEnd, this.appear = 1});

  final SenseLinkView view;
  final VoidCallback onEnd;
  final double appear;

  @override
  Widget build(BuildContext context) {
    final lost = view.phase == SenseLinkPhase.lost;
    final s = view.sample;
    final List<Widget> tiles;
    if (lost) {
      // Prototype: nothing gets through — no delay, all lost, no frames.
      tiles = [
        const SenseStatTile(
            label: SenseLayerStrings.latency,
            value: SenseLayerStrings.noValue,
            level: SenseLevel.hot,
            large: true),
        SenseStatTile(
            label: SenseLayerStrings.lossEstimated,
            value: SenseLayerStrings.percent(100),
            level: SenseLevel.hot,
            large: true),
        SenseStatTile(
            label: SenseLayerStrings.frames,
            value: SenseLayerStrings.fps(0),
            level: SenseLevel.hot,
            large: true),
      ];
    } else {
      tiles = [
        SenseStatTile(
          label: SenseLayerStrings.latency,
          value: s.rttMs == null ? null : SenseLayerStrings.ms(s.rttMs!.round()),
          level: s.rttMs == null ? null : s.latencyLevel,
          large: true,
        ),
        SenseStatTile(
          label: SenseLayerStrings.lossEstimated,
          value: s.lossPct == null ? null : SenseLayerStrings.percent(s.lossPct!),
          level: s.lossPct == null ? null : s.lossLevel,
          large: true,
        ),
        SenseStatTile(
          label: SenseLayerStrings.frames,
          value: s.fps == null ? null : SenseLayerStrings.fps(s.fps!.round()),
          level: s.fps == null ? null : s.fpsLevel,
          large: true,
        ),
      ];
    }
    final String line = view.recoveringIn != null
        ? SenseLayerStrings.recovering(view.recoveringIn!)
        : lost
            ? SenseLayerStrings.reconnecting(view.attempt, view.closeIn)
            : SenseLayerStrings.betterPath;
    return SenseLayerVeil(
      key: Key(lost ? 'sense-layer-lost' : 'sense-layer-weak'),
      blur: lost ? SenseLayerLook.lostBlur : SenseLayerLook.weakBlur,
      brightness: lost ? SenseLayerLook.lostBrightness : SenseLayerLook.weakBrightness,
      appear: appear,
      child: SenseLayerCard(children: [
        _logo(breathe: true),
        _title(lost ? SenseLayerStrings.lostTitle : SenseLayerStrings.weakTitle,
            lost ? SenseColors.dangerText : SenseColors.warn),
        _sub(lost ? SenseLayerStrings.lostBody(view.stallSeconds) : SenseLayerStrings.weakBody),
        _tiles(tiles),
        Text(
          senseWorkingLimitsText(),
          textAlign: TextAlign.center,
          style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted),
        ),
        _statusLine(line),
        Padding(
          padding: const EdgeInsets.only(top: SenseLayerLook.buttonsTop - SenseLayerLook.cardGap),
          child: SenseInlineConfirm(
            question: SenseLayerStrings.endQuestion,
            confirmLabel: SenseLayerStrings.endConfirm,
            onConfirm: onEnd,
            builder: (context, ask) => SenseButton(
              key: const Key('sense-layer-end'),
              label: SenseLayerStrings.endConnection,
              kind: SenseButtonKind.danger,
              onPressed: ask,
            ),
          ),
        ),
      ]),
    );
  }
}

/// O14 — "Bağlantı sona erdi".
class SenseEndedLayer extends StatelessWidget {
  const SenseEndedLayer({
    super.key,
    required this.summary,
    required this.backHomeIn,
    required this.reconnect,
    required this.onClose,
    required this.onReconnect,
    this.appear = 1,
  });

  final double appear;

  final SenseSessionSummary summary;
  final int backHomeIn;
  final SenseReconnectState reconnect;
  final VoidCallback onClose;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final connecting = reconnect == SenseReconnectState.connecting;
    final Widget status = switch (reconnect) {
      SenseReconnectState.connecting => _statusLine(SenseLayerStrings.reconnecting2),
      SenseReconnectState.busy => _statusLine(
          '${SenseLayerStrings.busy} · ${SenseLayerStrings.backHome(backHomeIn)}',
          spinner: false,
          color: SenseColors.warn),
      SenseReconnectState.idle =>
        _statusLine(SenseLayerStrings.backHome(backHomeIn), spinner: false),
    };
    return SenseLayerVeil(
      key: const Key('sense-layer-ended'),
      blur: SenseLayerLook.weakBlur,
      brightness: SenseLayerLook.weakBrightness,
      appear: appear,
      child: SenseLayerCard(children: [
        _logo(breathe: false, opacity: SenseLayerLook.endLogoOpacity),
        _title(SenseLayerStrings.endedTitle, SenseColors.text),
        _sub(summary.reasonText),
        _tiles([
          SenseStatTile(
            label: SenseLayerStrings.duration,
            value: SenseLayerStrings.durationValue(summary.duration),
            large: true,
          ),
          SenseStatTile(
            label: SenseLayerStrings.chatDeleted,
            value: SenseLayerStrings.chatSummary(summary.messages, summary.files),
            large: true,
          ),
        ]),
        status,
        Padding(
          padding: const EdgeInsets.only(top: SenseLayerLook.endButtonsTop - SenseLayerLook.cardGap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SenseButton(
                key: const Key('sense-ended-close'),
                label: SenseLayerStrings.close,
                onPressed: onClose,
              ),
              const SizedBox(width: SenseLayerLook.endButtonsGap),
              SenseButton(
                key: const Key('sense-ended-reconnect'),
                label: SenseLayerStrings.reconnect,
                kind: SenseButtonKind.primary,
                onPressed: connecting ? null : onReconnect,
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// O15 — the orange strip under the top bar, content on the left (the Sense island
/// sits in the middle of the bar edge).
class SenseIdleStrip extends StatelessWidget {
  const SenseIdleStrip({super.key, required this.secondsLeft, required this.onContinue});

  final int secondsLeft;
  final VoidCallback onContinue;

  static Color get textColor =>
      Color.lerp(SenseColors.warn, SenseColors.text, SenseLayerLook.idleTextLighten)!;

  @override
  Widget build(BuildContext context) {
    final style = SenseTextStyles.of(
        size: SenseFontSize.bodySmall, weight: SenseFontWeight.medium, color: textColor);
    return Container(
      key: const Key('sense-idle-strip'),
      height: SenseLayerLook.idleHeight,
      padding: const EdgeInsets.symmetric(horizontal: SenseLayerLook.idlePadSide),
      decoration: BoxDecoration(
        color: SenseColors.warn.withOpacity(SenseLayerLook.idleGroundOpacity),
        border: Border(
            bottom: BorderSide(
                color: SenseColors.warn.withOpacity(SenseLayerLook.idleLineOpacity))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          const SenseStatusDot(
              color: SenseColors.warn, size: SenseLayerLook.idleDot, blinking: true),
          const SizedBox(width: SenseLayerLook.idleGap),
          Text.rich(
            TextSpan(children: [
              const TextSpan(text: SenseLayerStrings.idlePrefix),
              TextSpan(
                text: SenseLayerStrings.idleCount(secondsLeft),
                style: style.copyWith(
                  fontWeight: SenseFontWeight.bold,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const TextSpan(text: SenseLayerStrings.idleSuffix),
            ]),
            style: style,
          ),
          const SizedBox(width: SenseLayerLook.idleGap),
          SenseButton(
            key: const Key('sense-idle-continue'),
            label: SenseLayerStrings.keepGoing,
            size: SenseButtonSize.small,
            onPressed: onContinue,
          ),
        ],
      ),
    );
  }
}
