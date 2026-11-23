// Sense Remote: the one 46 px session bar (YH O1, T9; prototype `.bar`, `.brand`, `.peer`,
// `.cats`, `.cat`, `.right`, `.btn`).
//  Left   logo · computer name · "Doğrudan · 60 fps · 18 ms" (orange "Dalgalı", red
//         "Görüntü gelmiyor"); pressing it opens the connection detail.
//  Lists  Ekranlar ▾ · Görüntü ▾ · Klavye ve fare ▾ · Eylemler ▾ (right-aligned to the middle),
//         with the status tags (red "Kayıt" + blinking dot, orange "Yalnız izle" /
//         "Giriş kilitli").
//  Popups Bilgisayar durumu · Ekran bilgisi (left-aligned from the middle), each with the
//         dot of its worst value; the open one underlined.
//  Right  Hayalet mod (white "Hayalet mod açık" when on; no window) · Tam ekran · red Bitir
//         (no note window, decision 4).
// The two middle groups are equally wide around the centre, where the Sense island hangs.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/blink.dart';
import '../../../components/button.dart';
import '../../../components/sense_mark.dart';
import '../../../strings/session.dart';
import '../../../tokens/sense_tokens.dart';
import '../../../tokens/theme.dart';
import '../data/session_state.dart';
import '../lists/backend.dart';
import '../lists/session_list.dart' show SenseStateChip;

/// The popups the bar opens (Bilgisayar durumu, Ekran bilgisi; drawn by their owner).
abstract class SenseBarPopups implements Listenable {
  bool isOpen(SenseBarPopup p);
  void toggle(SenseBarPopup p);
  void closeAll();

  /// Worst status inside the popup (T6), or null when unknown.
  SenseLevel? level(SenseBarPopup p);
}

/// Gap kept free in the middle of the bar for the island.
const double kSenseBarCentreGap = 40;

/// How long a ghost mode note stays next to the button.
const Duration kSenseGhostNoteHold = Duration(seconds: 5);

class SenseSessionBar extends StatefulWidget {
  const SenseSessionBar({
    super.key,
    required this.backend,
    required this.menus,
    required this.popups,
    this.links = const {},
    this.onDragStart,
    this.onDoubleTap,
  });

  final SenseSessionBackend backend;
  final SenseBarController menus;
  final SenseBarPopups popups;

  /// Anchor of each list under its button (the frame hangs the list there).
  final Map<SenseBarMenu, LayerLink> links;

  /// Window move / maximise from the empty bar (the remote window has no title bar).
  final VoidCallback? onDragStart;
  final VoidCallback? onDoubleTap;

  @override
  State<SenseSessionBar> createState() => _SenseSessionBarState();
}

class _SenseSessionBarState extends State<SenseSessionBar> {
  String? _note;
  Timer? _noteTimer;
  int _seenSerial = 0;

  SenseSessionBackend get b => widget.backend;

  @override
  void initState() {
    super.initState();
    _seenSerial = b.ghostNoteSerial;
    b.addListener(_onBackend);
  }

  @override
  void didUpdateWidget(SenseSessionBar old) {
    super.didUpdateWidget(old);
    if (old.backend != widget.backend) {
      old.backend.removeListener(_onBackend);
      widget.backend.addListener(_onBackend);
      _seenSerial = widget.backend.ghostNoteSerial;
    }
  }

  @override
  void dispose() {
    b.removeListener(_onBackend);
    _noteTimer?.cancel();
    super.dispose();
  }

  void _onBackend() {
    if (b.ghostNoteSerial != _seenSerial) {
      _seenSerial = b.ghostNoteSerial;
      final code = b.ghostNote;
      if (code != null) _showNote(SenseSessionStrings.ghostNote(code));
    }
  }

  void _showNote(String text) {
    _noteTimer?.cancel();
    setState(() => _note = text);
    _noteTimer = Timer(kSenseGhostNoteHold, () {
      if (mounted) setState(() => _note = null);
    });
  }

  void _ghost() {
    if (!b.ghostOn && b.ghostNeedsDisplay1) {
      _showNote(SenseSessionStrings.ghostDisplay1);
      return;
    }
    b.toggleGhost();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.maybeSizeOf(context)?.width ?? SenseSizes.minScreenWidth;
    final labels = senseBarLabels(width);
    return ListenableBuilder(
      listenable: Listenable.merge([b, widget.menus, widget.popups]),
      builder: (context, _) {
        final ready = b.ready;
        final menus = widget.menus;
        Widget menu(SenseBarMenu m, String label, {List<Widget> leading = const [], List<Widget> tags = const []}) {
          final button = _MenuButton(
            key: ValueKey('sense-bar-menu-${m.name}'),
            label: label,
            open: menus.isOpen(m),
            leading: leading,
            tags: tags,
            onTap: ready
                ? () {
                    if (!menus.isOpen(m)) widget.popups.closeAll();
                    menus.toggle(m);
                  }
                : null,
          );
          final link = widget.links[m];
          return link == null ? button : CompositedTransformTarget(link: link, child: button);
        }

        Widget popup(SenseBarPopup p, String label) => _PopupButton(
              key: ValueKey('sense-bar-popup-${p.name}'),
              label: label,
              active: widget.popups.isOpen(p),
              level: widget.popups.level(p),
              onTap: ready
                  ? () {
                      menus.close();
                      widget.popups.toggle(p);
                    }
                  : null,
            );

        final keyboardTag = b.inputLocked
            ? SenseSessionStrings.tagInputLocked
            : b.viewOnly
                ? SenseSessionStrings.tagViewOnly
                : null;
        final lists = Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          menu(SenseBarMenu.screens, labels.screens),
          menu(SenseBarMenu.display, labels.display),
          menu(SenseBarMenu.keyboard, labels.keyboard, tags: [
            if (keyboardTag != null)
              SenseStateChip(key: const ValueKey('sense-bar-tag-keyboard'), label: keyboardTag, level: SenseLevel.warn),
          ]),
          menu(SenseBarMenu.actions, labels.actions, leading: [
            if (b.recordingOn)
              const SenseStatusDot(key: ValueKey('sense-bar-rec-dot'), color: SenseColors.hot, blinking: true),
          ], tags: [
            if (b.recordingOn)
              const SenseStateChip(
                  key: ValueKey('sense-bar-tag-recording'),
                  label: SenseSessionStrings.tagRecording,
                  level: SenseLevel.hot),
          ]),
        ]);
        final popups = Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          popup(SenseBarPopup.status, labels.status),
          popup(SenseBarPopup.info, labels.info),
        ]);

        final line = senseLinkLine(b.link);
        final left = _Brand(
          name: b.peerName,
          line: line.text,
          level: line.level,
          onTap: ready
              ? () {
                  menus.close();
                  if (!widget.popups.isOpen(SenseBarPopup.info)) widget.popups.toggle(SenseBarPopup.info);
                }
              : null,
        );

        final right = Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(border: Border(left: BorderSide(color: SenseColors.line))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_note != null) ...[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(_note!,
                    key: const ValueKey('sense-bar-ghost-note'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.warn)),
              ),
              const SizedBox(width: 8),
            ],
            SenseButton(
              key: const ValueKey('sense-bar-ghost'),
              label: labels.ghost(b.ghostOn),
              tooltip: b.ghostAvailable ? SenseSessionStrings.ghostTooltip : SenseSessionStrings.ghostUnavailable,
              kind: b.ghostOn ? SenseButtonKind.on : SenseButtonKind.normal,
              onPressed: ready && b.ghostAvailable ? _ghost : null,
            ),
            const SizedBox(width: 6),
            SenseButton(
              key: const ValueKey('sense-bar-fullscreen'),
              label: b.fullscreen ? SenseSessionStrings.fullscreenExit : labels.fullscreen,
              onPressed: b.toggleFullscreen,
            ),
            const SizedBox(width: 6),
            SenseButton(
              key: const ValueKey('sense-bar-end'),
              label: labels.end,
              tooltip: SenseSessionStrings.endTooltip,
              kind: SenseButtonKind.danger,
              onPressed: b.end,
            ),
          ]),
        );

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: widget.onDragStart == null ? null : (_) => widget.onDragStart!(),
          onDoubleTap: widget.onDoubleTap,
          child: Container(
            key: const ValueKey('sense-session-bar'),
            height: SenseSizes.sessionToolbarHeight,
            decoration: const BoxDecoration(
              color: SenseColors.bg,
              border: Border(bottom: BorderSide(color: SenseColors.line)),
            ),
            child: CustomMultiChildLayout(
              delegate: _BarLayout(),
              children: [
                LayoutId(id: _Slot.left, child: left),
                LayoutId(id: _Slot.lists, child: ClipRect(child: lists)),
                LayoutId(id: _Slot.popups, child: ClipRect(child: popups)),
                LayoutId(id: _Slot.right, child: right),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _Slot { left, lists, popups, right }

/// Left and right blocks at the edges; the two middle groups take equal halves around the
/// centre (prototype grid `minmax(0,1fr) minmax(0,1fr)`), so the island is in the middle.
class _BarLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final h = size.height - 1; // above the bottom line
    final w = size.width;
    final rightSize = layoutChild(_Slot.right, BoxConstraints(maxWidth: w * 0.42, minHeight: h, maxHeight: h));
    final leftSize = layoutChild(_Slot.left, BoxConstraints(maxWidth: w * 0.26, minHeight: h, maxHeight: h));
    final side = leftSize.width > rightSize.width ? leftSize.width : rightSize.width;
    final half = (w / 2 - side - kSenseBarCentreGap / 2).clamp(0.0, w);
    final listsSize = layoutChild(_Slot.lists, BoxConstraints(maxWidth: half, minHeight: h, maxHeight: h));
    final popupsSize = layoutChild(_Slot.popups, BoxConstraints(maxWidth: half, minHeight: h, maxHeight: h));
    positionChild(_Slot.left, Offset.zero);
    positionChild(_Slot.right, Offset(w - rightSize.width, 0));
    positionChild(_Slot.lists, Offset(w / 2 - kSenseBarCentreGap / 2 - listsSize.width, 0));
    positionChild(_Slot.popups, Offset(w / 2 + kSenseBarCentreGap / 2, 0));
    assert(popupsSize.width <= half + 0.5);
  }

  @override
  bool shouldRelayout(_BarLayout oldDelegate) => false;
}

class _Brand extends StatelessWidget {
  const _Brand({required this.name, required this.line, required this.level, this.onTap});
  final String name;
  final String line;
  final SenseLevel level;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final lineColor = switch (level) {
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.dangerText,
      _ => SenseColors.textMuted,
    };
    final dotColor = switch (level) {
      SenseLevel.ok => SenseColors.ok,
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.hot,
      SenseLevel.unknown => SenseColors.textDim,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: SenseColors.line))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const SenseMark(width: 26, height: 24),
        const SizedBox(width: 10),
        Flexible(
          child: SenseInteractive(
            key: const ValueKey('sense-bar-link'),
            onTap: onTap,
            semanticLabel: SenseSessionStrings.linkDetail,
            tooltip: SenseSessionStrings.linkDetail,
            builder: (context, s) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SenseTextStyles.of(weight: SenseFontWeight.bold, height: 1.2)),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.only(right: 5),
                    decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
                  ),
                  Flexible(
                    child: Text(line,
                        key: const ValueKey('sense-bar-link-text'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SenseTextStyles.of(
                            size: SenseFontSize.hintSmall,
                            color: s.hovered ? SenseColors.text : lineColor,
                            height: 1.2)),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

/// A list opener (`.cat`): label + caret; open = raised background.
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    super.key,
    required this.label,
    required this.open,
    required this.onTap,
    this.leading = const [],
    this.tags = const [],
  });
  final String label;
  final bool open;
  final VoidCallback? onTap;
  final List<Widget> leading;
  final List<Widget> tags;

  @override
  Widget build(BuildContext context) {
    return SenseInteractive(
      onTap: onTap,
      semanticLabel: label,
      selected: open,
      builder: (context, s) {
        final fg = open || s.hovered ? SenseColors.text : SenseColors.textSecondary;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: open ? SenseColors.raised : (s.hovered ? SenseColors.hover : null),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final w in leading) ...[w, const SizedBox(width: 6)],
            Text(label,
                maxLines: 1,
                style: SenseTextStyles.of(weight: SenseFontWeight.medium, color: fg)),
            for (final w in tags) ...[const SizedBox(width: 6), w],
            const SizedBox(width: 6),
            Text('▾', style: SenseTextStyles.of(size: SenseFontSize.capsSmall, color: SenseColors.textDim)),
          ]),
        );
      },
    );
  }
}

/// A popup opener: label + worst-value dot; the open one has a white underline.
class _PopupButton extends StatelessWidget {
  const _PopupButton({super.key, required this.label, required this.active, required this.onTap, this.level});
  final String label;
  final bool active;
  final SenseLevel? level;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dot = switch (level) {
      SenseLevel.ok => SenseColors.ok,
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.hot,
      _ => null,
    };
    return SenseInteractive(
      onTap: onTap,
      semanticLabel: label,
      selected: active,
      builder: (context, s) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: s.hovered ? SenseColors.hover : null,
          border: Border(bottom: BorderSide(color: active ? SenseColors.text : SenseColors.bg.withOpacity(0), width: 2)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              maxLines: 1,
              style: SenseTextStyles.of(
                  weight: SenseFontWeight.medium,
                  color: active || s.hovered ? SenseColors.text : SenseColors.textSecondary)),
          if (dot != null) ...[
            const SizedBox(width: 7),
            SenseStatusDot(color: dot, size: 7, glow: level == SenseLevel.hot),
          ],
        ]),
      ),
    );
  }
}
