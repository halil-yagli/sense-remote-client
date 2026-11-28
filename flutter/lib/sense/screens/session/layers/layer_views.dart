// Sense Remote: the connection layers (YH O13 c11/c12, O14 n07, O15 n08).
// Prototype: `.netov`, `.nc`, `.nm/.nmv`, `.nth`, `.nre`, `.endov`, `.idlebar`.
import 'dart:ui' as ui;
import 'dart:ui' show FontFeature;

import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../components/sense_dialog.dart' show SenseDialogField;
import '../../../strings/note.dart';
import '../../../strings/session.dart';
import '../data/frame_rate.dart' show SenseFrameInfo;
import '../popups/note/note_state.dart' show SenseNoteStatus;
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
    this.shrink = 0,
    this.shrinkTo = Offset.zero,
  });

  final double blur;
  final double brightness;
  final Widget child;

  /// 0…1 while the layer fades in (YH T4 "Katman belirmesi"); the blur grows with it
  /// (an Opacity above a BackdropFilter would hide the blur).
  final double appear;

  /// 0..1 while the card shrinks into the bar's logo area (karar #94): the veil fades
  /// out and the card moves to [shrinkTo] (window coordinates) while it gets small.
  final double shrink;
  final Offset shrinkTo;

  @override
  Widget build(BuildContext context) {
    final shown = appear * (1 - shrink);
    final sigma = blur * shown;
    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: ColoredBox(
          color: SenseColors.bg.withOpacity((1 - brightness) * shown),
          child: LayoutBuilder(builder: (context, box) {
            final centre = Offset(box.maxWidth / 2, box.maxHeight / 2);
            final move = (shrinkTo - centre) * shrink;
            final scale = 1 - (1 - SenseLayerLook.shrinkScale) * shrink;
            return Center(
              child: Opacity(
                opacity: shown,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.translationValues(move.dx, move.dy, 0)..scale(scale, scale, 1),
                  child: child,
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// The card of the layers (`.nc`).
class SenseLayerCard extends StatelessWidget {
  const SenseLayerCard({super.key, required this.children, this.onClose, this.closeLabel});

  final List<Widget> children;

  /// Tooltip of the "x"; default: the weak card's "Kapat (durum alanına küçülür)".
  final String? closeLabel;

  /// "x" in the top right corner (weak card only, karar #94); null = none.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final card = Container(
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
    if (onClose == null) return card;
    // The "x" sits inside the card's corner (outside the card it would not take clicks).
    return Stack(
      children: [
        card,
        Positioned(
          top: SenseLayerLook.closeInset,
          right: SenseLayerLook.closeInset,
          child: SenseInteractive(
            key: const Key('sense-layer-minimize'),
            onTap: onClose,
            semanticLabel: closeLabel ?? SenseLayerStrings.minimize,
            tooltip: closeLabel ?? SenseLayerStrings.minimize,
            builder: (context, s) => SizedBox(
              width: SenseLayerLook.closeSize,
              height: SenseLayerLook.closeSize,
              child: Center(
                child: SenseGlyph(SenseGlyphKind.cross,
                    size: SenseFontSize.body,
                    color: s.hovered ? SenseColors.text : SenseColors.textMuted),
              ),
            ),
          ),
        ),
      ],
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
  const SenseLinkLayer({
    super.key,
    required this.view,
    required this.onEnd,
    this.onMinimize,
    this.appear = 1,
    this.shrink = 0,
    this.shrinkTo = Offset.zero,
  });

  final SenseLinkView view;
  final VoidCallback onEnd;

  /// "x": only while the link is not lost (karar #94).
  final VoidCallback? onMinimize;
  final double appear;
  final double shrink;
  final Offset shrinkTo;

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
          level: s.fps == null ? null : s.fpsShownLevel,
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
      shrink: shrink,
      shrinkTo: shrinkTo,
      child: SenseLayerCard(onClose: lost ? null : onMinimize, children: [
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

/// Karar #152: the rate the good-link card shows and its line. A still screen (K44 rule,
/// or 0 fps on a healthy link) shows the last rate measured while the picture moved, else
/// the reachable one; a moving picture the rate drawn on this screen. Null: not measured.
({int shown, String line})? senseCardFrame(SenseLinkSample s, SenseFrameInfo f) {
  final fps = s.fps;
  if (fps == null) return null;
  final still = s.still || fps == 0;
  final stalling = !still && s.fpsLevel != SenseLevel.ok;
  final shown = still ? (f.recentFps ?? f.reachableFps ?? fps.round()) : (f.drawnFps ?? fps.round());
  return (
    shown: shown,
    line: SenseSessionStrings.frameLine(shown, still: still, stalling: stalling, remoteHz: f.remoteHz),
  );
}

/// Sürüm 10 (#110), Sürüm 12 (FO-B1): the connection card opened from the bar's logo / status
/// area while the link is good. A small card that drops from under the computer name (no veil,
/// no blur; prototype `.qcard`): title, `Sunucu: … · yol · ms`, connection type, `Kare hızı: …`,
/// and the v11 value boxes and limits as lines. A click beside it (the logo area too) closes it.
class SenseLinkInfoLayer extends StatelessWidget {
  const SenseLinkInfoLayer({
    super.key,
    required this.view,
    required this.direct,
    required this.onClose,
    this.serverName,
    this.frame = const SenseFrameInfo(),
    this.appear = 1,
    this.anchor = const Offset(SenseQuickCardLook.left, SenseSizes.sessionToolbarHeight + SenseQuickCardLook.below),
  });

  final SenseLinkView view;

  /// true = direct, false = relay, null = not known yet.
  final bool? direct;
  final VoidCallback onClose;

  /// Sürüm 11 (#144): ID server name for the `Sunucu:` line (null/empty = `Sunucu: —`).
  final String? serverName;

  /// Karar #152: drawn / last measured / reachable rate and the Host's refresh rate.
  final SenseFrameInfo frame;
  final double appear;

  /// Top-left corner of the card in the layer (under the computer name).
  final Offset anchor;

  static Color _levelColor(SenseLevel? l) => switch (l) {
        SenseLevel.warn => SenseColors.warn,
        SenseLevel.hot => SenseColors.dangerText,
        _ => SenseColors.text,
      };

  @override
  Widget build(BuildContext context) {
    final s = view.sample;
    final fr = senseCardFrame(s, frame);
    final path = switch (direct) {
      true => SenseLayerStrings.pathDirect,
      false => SenseLayerStrings.pathRelay,
      null => SenseLayerStrings.pathUnknown,
    };
    final muted = SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted);
    TextSpan value(String label, String? v, SenseLevel? level) => TextSpan(children: [
          TextSpan(text: '$label '),
          TextSpan(
            text: v ?? SenseLayerStrings.noValue,
            style: muted.copyWith(
              color: v == null ? SenseColors.textMuted : _levelColor(level),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ]);
    final dot = TextSpan(text: ' · ', style: muted);
    final card = Container(
      key: const Key('sense-layer-info'),
      constraints: const BoxConstraints(minWidth: SenseQuickCardLook.minWidth),
      padding: const EdgeInsets.symmetric(horizontal: SenseQuickCardLook.padH, vertical: SenseQuickCardLook.padV),
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.popup),
        boxShadow: [
          BoxShadow(
            color: SenseColors.bg.withOpacity(SenseQuickCardLook.shadowOpacity),
            blurRadius: SenseQuickCardLook.shadowBlur,
            offset: const Offset(0, SenseQuickCardLook.shadowY),
          ),
        ],
      ),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              view.wavy ? SenseLayerStrings.wavyTitle : SenseLayerStrings.goodTitle,
              style: SenseTextStyles.of(
                  size: SenseFontSize.popupTitle,
                  weight: SenseFontWeight.bold,
                  color: view.wavy ? SenseColors.warn : SenseColors.text),
            ),
            const SizedBox(height: SenseQuickCardLook.gap),
            Text(
              SenseSessionStrings.serverLine(serverName, direct, s.rttMs?.round()),
              key: const Key('sense-layer-info-server'),
              style: muted.copyWith(color: SenseColors.text),
            ),
            const SizedBox(height: SenseQuickCardLook.gap),
            Text(path, key: const Key('sense-layer-info-path'), style: muted),
            if (fr != null) ...[
              const SizedBox(height: SenseQuickCardLook.gap),
              Text(fr.line, key: const Key('sense-layer-info-frames'), style: muted),
            ],
            const SizedBox(height: SenseQuickCardLook.gap + SenseQuickCardLook.valuesTop),
            Text.rich(
              TextSpan(children: [
                value(SenseLayerStrings.latency, s.rttMs == null ? null : SenseLayerStrings.ms(s.rttMs!.round()),
                    s.rttMs == null ? null : s.latencyLevel),
                dot,
                value(SenseLayerStrings.lossEstimated, s.lossPct == null ? null : SenseLayerStrings.percent(s.lossPct!),
                    s.lossPct == null ? null : s.lossLevel),
                dot,
                value(SenseLayerStrings.frames, fr == null ? null : SenseLayerStrings.fps(fr.shown),
                    s.fps == null ? null : s.fpsShownLevel),
              ]),
              key: const Key('sense-layer-info-values'),
              style: muted,
            ),
            const SizedBox(height: SenseQuickCardLook.gap),
            Text(
              senseWorkingLimitsText(),
              style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim),
            ),
          ],
        ),
      ),
    );
    return Stack(children: [
      // A click beside the card closes it (the card itself takes its own clicks).
      Positioned.fill(
        child: GestureDetector(
          key: const Key('sense-layer-info-barrier'),
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
        ),
      ),
      Positioned(
        left: anchor.dx,
        top: anchor.dy,
        child: Opacity(
          opacity: appear,
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}, child: card),
        ),
      ),
    ]);
  }
}

/// Sürüm 11 (#121): logged in, no picture yet — the O13 card's look with the connection type
/// and "Bağlantıyı bitir", instead of a black screen.
class SenseWaitingImageLayer extends StatelessWidget {
  const SenseWaitingImageLayer({
    super.key,
    required this.direct,
    required this.onEnd,
    this.appear = 1,
  });

  /// true = direct, false = relay, null = not known yet.
  final bool? direct;
  final VoidCallback onEnd;
  final double appear;

  @override
  Widget build(BuildContext context) {
    final path = switch (direct) {
      true => SenseLayerStrings.waitingDirect,
      false => SenseLayerStrings.waitingRelay,
      null => SenseLayerStrings.waitingUnknown,
    };
    return SenseLayerVeil(
      key: const Key('sense-layer-waiting'),
      blur: SenseLayerLook.weakBlur,
      brightness: SenseLayerLook.weakBrightness,
      appear: appear,
      child: SenseLayerCard(children: [
        _logo(breathe: true),
        _title(SenseLayerStrings.waitingTitle, SenseColors.text),
        _sub(path),
        _statusLine(SenseLayerStrings.waitingStatus),
        Padding(
          padding: const EdgeInsets.only(top: SenseLayerLook.buttonsTop - SenseLayerLook.cardGap),
          child: SenseInlineConfirm(
            question: SenseLayerStrings.endQuestion,
            confirmLabel: SenseLayerStrings.endConfirm,
            onConfirm: onEnd,
            builder: (context, ask) => SenseButton(
              key: const Key('sense-waiting-end'),
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

/// O14 — "Bağlantı sona erdi". Sürüm 12 (FO-A4, FO-A11): the note row — "Not ekle" opens a field
/// in the card (the window does not go back while it is open), a saved note says so; after
/// "Notsuz bitir" (and for a busy computer) there is no row.
class SenseEndedLayer extends StatelessWidget {
  const SenseEndedLayer({
    super.key,
    required this.summary,
    required this.backHomeIn,
    required this.reconnect,
    required this.onClose,
    required this.onReconnect,
    this.appear = 1,
    this.failed = false,
    this.note = SenseNoteStatus.none,
    this.noteOpen = false,
    this.onAddNote,
    this.onSaveNote,
  });

  final double appear;

  /// Sürüm 11 (O7): the last "Yeniden bağlan" got no answer.
  final bool failed;

  final SenseSessionSummary summary;
  final int backHomeIn;
  final SenseReconnectState reconnect;
  final VoidCallback onClose;
  final VoidCallback onReconnect;

  /// Sürüm 12 (FO-A4): what happened to this connection's note.
  final SenseNoteStatus note;

  /// The note field is open in the card.
  final bool noteOpen;

  /// "Not ekle" (null = no note row: the window cannot send a note).
  final VoidCallback? onAddNote;

  /// "Kaydet" / Enter in the field.
  final ValueChanged<String>? onSaveNote;

  @override
  Widget build(BuildContext context) {
    final connecting = reconnect == SenseReconnectState.connecting;
    final Widget status = switch (reconnect) {
      SenseReconnectState.connecting => _statusLine(SenseLayerStrings.reconnecting2),
      SenseReconnectState.busy => _statusLine(
          '${SenseLayerStrings.busy} · ${SenseLayerStrings.backHome(backHomeIn)}',
          spinner: false,
          color: SenseColors.warn),
      SenseReconnectState.idle => noteOpen
          ? _statusLine(SenseNoteStrings.holdHome, spinner: false)
          : failed
              ? _statusLine('${SenseLayerStrings.reconnectFailed} · ${SenseLayerStrings.backHome(backHomeIn)}',
                  spinner: false, color: SenseColors.warn)
              : _statusLine(SenseLayerStrings.backHome(backHomeIn), spinner: false),
    };
    final Widget? noteRow;
    if (note == SenseNoteStatus.saved) {
      noteRow = Padding(
        padding: const EdgeInsets.only(top: SenseEndNoteLook.top - SenseLayerLook.cardGap, bottom: SenseEndNoteLook.bottom),
        child: Text(
          SenseNoteStrings.saved,
          key: const Key('sense-ended-note-saved'),
          textAlign: TextAlign.center,
          style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.ok),
        ),
      );
    } else if (noteOpen && onSaveNote != null) {
      noteRow = Padding(
        padding: const EdgeInsets.only(top: SenseEndNoteLook.top - SenseLayerLook.cardGap, bottom: SenseEndNoteLook.bottom),
        child: _EndNoteField(onSave: onSaveNote!),
      );
    } else if (onAddNote != null &&
        note == SenseNoteStatus.none &&
        summary.reason != SenseEndReason.busy &&
        reconnect == SenseReconnectState.idle) {
      noteRow = Padding(
        padding: const EdgeInsets.only(top: SenseEndNoteLook.top - SenseLayerLook.cardGap),
        child: SenseButton(
          key: const Key('sense-ended-add-note'),
          label: SenseNoteStrings.addNote,
          size: SenseButtonSize.small,
          onPressed: onAddNote,
        ),
      );
    } else {
      noteRow = null;
    }
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
        if (noteRow != null) noteRow,
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

/// `.endnote`: the field and "Kaydet" side by side.
class _EndNoteField extends StatefulWidget {
  const _EndNoteField({required this.onSave});

  final ValueChanged<String> onSave;

  @override
  State<_EndNoteField> createState() => _EndNoteFieldState();
}

class _EndNoteFieldState extends State<_EndNoteField> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() => widget.onSave(_text.text);

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: SenseEndNoteLook.fieldWidth,
            child: SenseDialogField(
              key: const Key('sense-ended-note-field'),
              controller: _text,
              hint: SenseNoteStrings.endPlaceholder,
              autofocus: true,
              maxLength: SenseEndNoteLook.maxLength,
              onSubmitted: (_) => _save(),
            ),
          ),
          const SizedBox(width: SenseEndNoteLook.gap),
          SenseButton(
            key: const Key('sense-ended-note-save'),
            label: SenseNoteStrings.endSave,
            kind: SenseButtonKind.primary,
            size: SenseButtonSize.small,
            onPressed: _save,
          ),
        ],
      );
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
