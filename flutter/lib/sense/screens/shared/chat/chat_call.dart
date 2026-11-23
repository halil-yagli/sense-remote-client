// Sense Remote: the call part of the chat (YH O11 voice only, #67: no camera
// button, no camera list, no video area). Status row "● Sahadaki kişi
// çevrimiçi · Ara" / "● Görüşmede · 01:35 · Aramayı bitir"; in a call, the
// Mikrofon button and its list (onaylı `.cbtn`, `.dm`, `.lvl`, `.offit`):
// connected microphones, Ses seviyesi bar, Ses çıkışı, red "Mikrofonu kapat".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../sense.dart';
import '../../../strings/chat.dart';
import 'chat_controller.dart';
import 'data/call.dart';

abstract final class SenseChatCallSize {
  static const double dot = 7;
  static const double dotGap = 5;
  static const double rowGap = 8;
  static const double menuGap = 6;
  static const double levelHeight = 6;
  static const double levelIndent = 36;
  static const double radio = 14;
  /// Height guess of a list row and of headers + level + line, to choose the
  /// list's side before it is laid out.
  static const double rowEstimate = 31;
  static const double menuExtra = 110;
  static const Duration levelEvery = Duration(milliseconds: 150);
}

/// "● Sahadaki kişi çevrimiçi [Ara]" / "● Aranıyor… [Aramayı bitir]" /
/// "● Görüşmede · 01:35 [Aramayı bitir]".
class SenseCallRow extends StatelessWidget {
  const SenseCallRow({
    super.key,
    required this.phase,
    required this.elapsed,
    required this.onlineText,
    required this.onCall,
    required this.onEnd,
  });

  final SenseCallPhase phase;
  final Duration elapsed;
  final String onlineText;

  /// "Ara"; null = calling is not possible here (button faded).
  final VoidCallback? onCall;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final String text;
    switch (phase) {
      case SenseCallPhase.idle:
      case SenseCallPhase.incoming:
        text = onlineText;
      case SenseCallPhase.calling:
        text = SenseChatStrings.calling;
      case SenseCallPhase.active:
        text = SenseChatStrings.inCall(senseCallClock(elapsed));
    }
    final inCall = phase == SenseCallPhase.calling || phase == SenseCallPhase.active;
    return Row(children: [
      const SenseStatusDot(color: SenseColors.ok, size: SenseChatCallSize.dot),
      const SizedBox(width: SenseChatCallSize.dotGap),
      Expanded(
        child: Text(
          text,
          key: const Key('sense-call-status'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SenseTextStyles.hint,
        ),
      ),
      const SizedBox(width: SenseChatCallSize.rowGap),
      if (inCall)
        SenseButton(
          key: const Key('sense-call-end'),
          label: SenseChatStrings.endCall,
          kind: SenseButtonKind.danger,
          onPressed: onEnd,
        )
      else
        SenseButton(
          key: const Key('sense-call-start'),
          label: SenseChatStrings.call,
          kind: SenseButtonKind.on,
          onPressed: onCall,
        ),
    ]);
  }
}

/// Elapsed-time text that ticks every second while [start] is set.
class SenseCallTicker extends StatefulWidget {
  const SenseCallTicker({super.key, required this.controller, required this.builder});

  final SenseChatController controller;
  final Widget Function(BuildContext context, Duration elapsed) builder;

  @override
  State<SenseCallTicker> createState() => _SenseCallTickerState();
}

class _SenseCallTickerState extends State<SenseCallTicker> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.controller.phase == SenseCallPhase.active) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.controller.callElapsed);
}

/// Display name of a device; '' is the system default.
String senseMicName(String device) => device.isEmpty ? SenseChatStrings.defaultMic : device;

/// "Mikrofon  Kulaklık mik… ▾" — opens the device list under it.
class SenseMicButton extends StatefulWidget {
  const SenseMicButton({super.key, required this.call});

  final SenseChatCall call;

  @override
  State<SenseMicButton> createState() => _SenseMicButtonState();
}

class _SenseMicButtonState extends State<SenseMicButton> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  final Object _tapGroup = Object();
  final GlobalKey _buttonKey = GlobalKey();
  SenseAudioDevices _devices = const SenseAudioDevices();
  double? _level;
  bool _muteFailed = false;
  Timer? _levelTimer;
  double _width = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _levelTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await widget.call.devices();
    if (mounted) setState(() => _devices = d);
  }

  void _toggle() {
    if (_portal.isShowing) {
      _close();
    } else {
      _muteFailed = false;
      _load();
      _levelTimer?.cancel();
      _levelTimer = Timer.periodic(SenseChatCallSize.levelEvery, (_) => _readLevel());
      _readLevel();
      setState(_portal.show);
    }
  }

  void _close() {
    _levelTimer?.cancel();
    _levelTimer = null;
    if (_portal.isShowing) setState(_portal.hide);
  }

  Future<void> _readLevel() async {
    final l = await widget.call.level();
    if (mounted && l != _level) setState(() => _level = l);
  }

  Future<void> _chooseInput(String device) async {
    await widget.call.setInput(device);
    if (_devices.muted) await widget.call.setMuted(false);
    if (!mounted) return;
    setState(() => _devices = _devices.copyWith(input: device, muted: false));
    _close();
  }

  Future<void> _chooseOutput(String device) async {
    await widget.call.setOutput(device);
    if (!mounted) return;
    setState(() => _devices = _devices.copyWith(output: device));
    _close();
  }

  Future<void> _mute() async {
    final ok = await widget.call.setMuted(true);
    if (!mounted) return;
    if (ok) {
      setState(() => _devices = _devices.copyWith(muted: true));
      _close();
    } else {
      setState(() => _muteFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = _devices.muted;
    final open = _portal.isShowing;
    return TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) => _close(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _menu,
          child: SenseInteractive(
            key: _buttonKey,
            onTap: _toggle,
            semanticLabel: SenseChatStrings.microphone,
            builder: (context, s) => LayoutBuilder(
                key: const Key('sense-mic-button'),
                builder: (context, c) {
              if (c.maxWidth.isFinite) _width = c.maxWidth;
              return SenseFocusRing(
                visible: s.focused,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: s.hovered ? SenseColors.hover : SenseColors.bg,
                    border: Border.all(
                      color: open ? SenseColors.text : (muted ? SenseColors.danger : SenseColors.line),
                    ),
                    borderRadius: BorderRadius.circular(SenseRadii.category),
                  ),
                  child: Row(children: [
                    Text(SenseChatStrings.microphone,
                        style: SenseTextStyles.body.copyWith(fontWeight: SenseFontWeight.bold)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        muted ? SenseChatStrings.micOff : senseMicName(_devices.input),
                        key: const Key('sense-mic-current'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SenseTextStyles.hint.copyWith(
                          color: muted ? SenseColors.dangerTextSoft : SenseColors.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('▾', style: SenseTextStyles.hint.copyWith(color: SenseColors.textDim)),
                  ]),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  /// The list opens above the button when it does not fit under it (the chat
  /// sits at the bottom of the window and has no video area to push it down).
  bool _opensUp(BuildContext context, int rows) {
    final box = _buttonKey.currentContext?.findRenderObject();
    final screen = MediaQuery.maybeSizeOf(context);
    if (box is! RenderBox || !box.hasSize || screen == null) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    final below = screen.height - top - box.size.height;
    final need = SenseChatCallSize.menuGap + rows * SenseChatCallSize.rowEstimate + SenseChatCallSize.menuExtra;
    return below < need && top > below;
  }

  Widget _menu(BuildContext context) {
    final d = _devices;
    final inputs = ['', ...d.inputs.where((e) => e.isNotEmpty)];
    final outputs = d.outputs.isEmpty ? [''] : d.outputs;
    final up = _opensUp(context, inputs.length + outputs.length + 1);
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: up ? Alignment.topLeft : Alignment.bottomLeft,
      followerAnchor: up ? Alignment.bottomLeft : Alignment.topLeft,
      offset: Offset(0, up ? -SenseChatCallSize.menuGap : SenseChatCallSize.menuGap),
      showWhenUnlinked: false,
      child: Align(
        alignment: up ? Alignment.bottomLeft : Alignment.topLeft,
        child: TapRegion(
          groupId: _tapGroup,
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
            child: FocusScope(
              autofocus: true,
              child: Container(
                key: const Key('sense-mic-menu'),
                width: _width,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: SenseColors.surface,
                  border: Border.all(color: SenseColors.line),
                  borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
                  boxShadow: [
                    BoxShadow(
                      color: SenseColors.bg.withOpacity(0.7),
                      offset: const Offset(0, 18),
                      blurRadius: 50,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _MenuHeader(SenseChatStrings.micsHeader),
                    for (var i = 0; i < inputs.length; i++)
                      _MenuItem(
                        key: Key('sense-mic-input-$i'),
                        label: senseMicName(inputs[i]),
                        selected: !d.muted && inputs[i] == d.input,
                        onTap: () => _chooseInput(inputs[i]),
                      ),
                    _LevelBar(level: d.muted ? 0 : _level),
                    const _MenuHeader(SenseChatStrings.outputHeader),
                    for (var i = 0; i < outputs.length; i++)
                      _MenuItem(
                        key: Key('sense-mic-output-$i'),
                        label: outputs[i].isEmpty ? SenseChatStrings.defaultOutput : outputs[i],
                        selected: outputs[i] == d.output,
                        onTap: () => _chooseOutput(outputs[i]),
                      ),
                    Container(
                      height: 1,
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      color: SenseColors.line,
                    ),
                    _MenuItem(
                      key: const Key('sense-mic-mute'),
                      label: SenseChatStrings.muteMic,
                      selected: d.muted,
                      danger: true,
                      onTap: _mute,
                    ),
                    if (_muteFailed)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            SenseChatCallSize.levelIndent, 0, 12, 4),
                        child: Text(
                          SenseChatStrings.muteFailed,
                          key: const Key('sense-mic-mute-failed'),
                          style: SenseTextStyles.hint.copyWith(color: SenseColors.dangerText),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuHeader extends StatelessWidget {
  const _MenuHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Text(
        senseUpperTr(text),
        style: TextStyle(
          fontFamily: SenseFont.family,
          fontSize: SenseFontSize.caps,
          color: SenseColors.textDim,
          letterSpacing: senseLetterSpacing(SenseLetterSpacing.caps, SenseFontSize.caps),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final bool selected;
  final bool danger;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = danger ? SenseColors.dangerTextSoft : SenseColors.text;
    return SenseInteractive(
      onTap: onTap,
      selected: selected,
      semanticLabel: label,
      builder: (context, s) => Container(
        color: s.hovered || s.focused ? SenseColors.hover : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Container(
            width: SenseChatCallSize.radio,
            height: SenseChatCallSize.radio,
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? accent : SenseColors.textDim, width: 1.5),
            ),
            child: selected
                ? DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: accent))
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.body.copyWith(color: danger ? accent : SenseColors.text),
            ),
          ),
        ]),
      ),
    );
  }
}

/// "Ses seviyesi" with the green bar (`.lvl .mb i{background:var(--okc)}`).
/// [level] null = cannot be read: empty track.
class _LevelBar extends StatelessWidget {
  const _LevelBar({required this.level});

  final double? level;

  @override
  Widget build(BuildContext context) {
    final v = (level ?? 0).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(SenseChatCallSize.levelIndent, 4, 12, 4),
      child: Row(children: [
        Text(SenseChatStrings.level, style: SenseTextStyles.hint),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(SenseChatCallSize.levelHeight),
            child: Container(
              key: const Key('sense-mic-level'),
              height: SenseChatCallSize.levelHeight,
              color: SenseColors.raised,
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: v,
                heightFactor: 1,
                child: const ColoredBox(color: SenseColors.ok),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
