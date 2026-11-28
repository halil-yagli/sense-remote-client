// Sense Remote (Sürüm 12, FO-A4): "Oturum notu" popup in the locked popup layout (Bilgisayar
// durumu: header, live line, box, one category, hint, footer). Prototype `noteHTML`.
// Opens from "Bitir" (ending), Eylemler › Oturuma not ekle (mid) and, for callers that want it,
// after the end (afterEnd). It replaces RustDesk's stock note box (`showAuditDialog`).
// The popup only returns what was chosen; the caller sends the note ([senseEndWithNote],
// [senseAddNote] do both).
import 'dart:async';

import 'package:flutter/material.dart' show Material, MaterialType, TextField, InputDecoration, OutlineInputBorder;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../sense.dart';
import '../../../../strings/note.dart';
import '../../layers/layer_controller.dart';
import '../../layers/layer_strings.dart';
import '../status/status_model.dart' show SenseStatusLine;
import '../status/status_widgets.dart' show SenseLiveLine, SenseLineRowView, SenseHintView, kSenseStatusBoxGap;
import 'note_state.dart';

export 'note_state.dart';

/// Look of the note field (prototype `.nt`: min height 92, padding 8 10, 12.5/1.5) and of the
/// chips row (`.chips` gap 6, margin-top 7).
abstract final class SenseNoteLook {
  static const double fieldMinHeight = 92;
  static const double fieldPadH = 10;
  static const double fieldPadV = 8;
  static const double fieldLine = 1.5;
  static const int fieldMinLines = 4;
  static const int maxLength = 1000;
  static const double chipsGap = 6;
  static const double chipsTop = 7;
  static const double footPadH = 12;
  static const double footPadV = 10;
  static const double footGap = 6;
}

class SenseNotePopup extends StatefulWidget {
  const SenseNotePopup({
    super.key,
    required this.mode,
    required this.onDone,
    this.facts = const SenseNoteFacts(),
    this.initialText = '',
    this.animateIn = true,
  });

  final SenseNoteMode mode;
  final SenseNoteFacts facts;
  final String initialText;
  final ValueChanged<SenseNoteResult> onDone;
  final bool animateIn;

  @override
  State<SenseNotePopup> createState() => _SenseNotePopupState();
}

class _SenseNotePopupState extends State<SenseNotePopup> {
  late final TextEditingController _text = TextEditingController(text: widget.initialText)
    ..addListener(_changed);
  bool _open = true;
  bool _done = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _finish(SenseNoteAction action) {
    if (_done) return;
    _done = true;
    widget.onDone(SenseNoteResult(action, action == SenseNoteAction.saved ? _text.text.trim() : ''));
  }

  void _chip(String word) {
    final now = _text.text.trimRight();
    _text.text = now.isEmpty ? word : '$now${SenseNoteStrings.chipJoin}$word';
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
  }

  String get _live => switch (widget.mode) {
        SenseNoteMode.ending => SenseNoteStrings.liveEnding,
        SenseNoteMode.mid => SenseNoteStrings.liveMid(SenseLayerStrings.durationValue(widget.facts.duration)),
        SenseNoteMode.afterEnd => SenseNoteStrings.liveAfterEnd,
      };

  @override
  Widget build(BuildContext context) {
    final f = widget.facts;
    final typed = _text.text.trim();
    final ending = widget.mode == SenseNoteMode.ending;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => _finish(SenseNoteAction.cancelled),
      },
      child: SensePopupShell(
        key: const Key('sense-note-popup'),
        title: SenseNoteStrings.title,
        subtitle: SenseNoteStrings.subtitle,
        animateIn: widget.animateIn,
        onClose: () => _finish(SenseNoteAction.cancelled),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SenseLiveLine(key: const Key('sense-note-live'), text: _live),
            SenseStatusBox(
              level: SenseLevel.ok,
              title: SenseNoteStrings.boxTitle,
              children: [
                SenseLineRowView(
                    row: SenseStatusLine(SenseNoteStrings.rowComputer,
                        f.computer.isEmpty ? SenseLayerStrings.noValue : f.computer)),
                SenseLineRowView(
                    row: SenseStatusLine(SenseNoteStrings.rowDuration, SenseLayerStrings.durationValue(f.duration))),
                SenseLineRowView(
                    row: SenseStatusLine(SenseNoteStrings.rowSession, SenseNoteStrings.sessionCounts(f.messages, f.files)),
                    last: true),
              ],
            ),
            const SizedBox(height: kSenseStatusBoxGap),
            SenseCategory(
              headerKey: const Key('sense-note-category'),
              title: SenseNoteStrings.category,
              summary: typed.isEmpty ? SenseNoteStrings.empty : SenseNoteStrings.chars(typed.length),
              open: _open,
              onToggle: () => setState(() => _open = !_open),
              builder: (context) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _NoteField(controller: _text),
                  const SizedBox(height: SenseNoteLook.chipsTop),
                  Wrap(
                    spacing: SenseNoteLook.chipsGap,
                    runSpacing: SenseNoteLook.chipsGap,
                    children: [
                      for (final c in SenseNoteStrings.chips)
                        SensePill(key: Key('sense-note-chip-$c'), label: c, onTap: () => _chip(c)),
                    ],
                  ),
                ],
              ),
            ),
            const SenseHintView(text: SenseNoteStrings.hint),
          ],
        ),
        footer: Padding(
          padding: const EdgeInsets.symmetric(horizontal: SenseNoteLook.footPadH, vertical: SenseNoteLook.footPadV),
          child: Row(children: [
            SenseButton(
              key: const Key('sense-note-cancel'),
              label: ending ? SenseNoteStrings.cancel : SenseNoteStrings.close,
              onPressed: () => _finish(SenseNoteAction.cancelled),
            ),
            const Spacer(),
            if (ending) ...[
              SenseButton(
                key: const Key('sense-note-skip'),
                label: SenseNoteStrings.skipAndEnd,
                onPressed: () => _finish(SenseNoteAction.skipped),
              ),
              const SizedBox(width: SenseNoteLook.footGap),
              SenseButton(
                key: const Key('sense-note-save'),
                label: SenseNoteStrings.saveAndEnd,
                kind: SenseButtonKind.danger,
                onPressed: () => _finish(SenseNoteAction.saved),
              ),
            ] else
              SenseButton(
                key: const Key('sense-note-save'),
                label: SenseNoteStrings.save,
                kind: SenseButtonKind.primary,
                onPressed: () => _finish(SenseNoteAction.saved),
              ),
          ]),
        ),
      ),
    );
  }
}

/// `.nt`: black ground, line border, several lines.
class _NoteField extends StatelessWidget {
  const _NoteField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(SenseRadii.button),
      borderSide: const BorderSide(color: SenseColors.line),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: SenseNoteLook.fieldMinHeight),
      child: Material(
        type: MaterialType.transparency,
        child: TextField(
          key: const Key('sense-note-field'),
          controller: controller,
          autofocus: true,
          minLines: SenseNoteLook.fieldMinLines,
          maxLines: null,
          maxLength: SenseNoteLook.maxLength,
          keyboardType: TextInputType.multiline,
          style: SenseTextStyles.of(size: SenseFontSize.body, height: SenseNoteLook.fieldLine),
          cursorColor: SenseColors.text,
          decoration: InputDecoration(
            hintText: SenseNoteStrings.placeholder,
            hintStyle: SenseTextStyles.of(
                size: SenseFontSize.body, color: SenseColors.textMuted, height: SenseNoteLook.fieldLine),
            counterText: '',
            isDense: true,
            filled: true,
            fillColor: SenseColors.bg,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: SenseNoteLook.fieldPadH, vertical: SenseNoteLook.fieldPadV),
            enabledBorder: border,
            border: border,
            focusedBorder: border.copyWith(borderSide: const BorderSide(color: SenseColors.textDim)),
          ),
        ),
      ),
    );
  }
}

/// Plan §2.5: shows the note popup and returns what was chosen. Inside a connection window it
/// takes the one popup place ([SensePopupHost], T7); another popup opening there cancels it.
/// Without a host it opens over the window's overlay at the same top-right place.
Future<SenseNoteResult> senseShowSessionNote(
  BuildContext context, {
  required SenseNoteMode mode,
  SenseNoteFacts facts = const SenseNoteFacts(),
  String initialText = '',
  SensePopupController? popups,
}) {
  final done = Completer<SenseNoteResult>();
  final host = popups ?? SensePopupHost.maybeOf(context);
  void finish(SenseNoteResult r) {
    if (!done.isCompleted) done.complete(r);
  }

  if (host != null) {
    late final VoidCallback watch;
    watch = () {
      if (!host.isOpenWith(SenseNoteStrings.popupId)) {
        host.removeListener(watch);
        finish(SenseNoteResult.cancelled);
      }
    };
    host.open(
      SenseNoteStrings.popupId,
      (_) => SenseNotePopup(
        mode: mode,
        facts: facts,
        initialText: initialText,
        onDone: (r) {
          host.removeListener(watch);
          finish(r);
          host.close(SenseNoteStrings.popupId);
        },
      ),
    );
    host.addListener(watch);
    return done.future;
  }

  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return Future.value(SenseNoteResult.cancelled);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      top: SensePopupHost.defaultMargin,
      right: SensePopupHost.defaultMargin,
      width: SenseLayout.popupWidth(MediaQuery.maybeSizeOf(context)?.width ?? SenseSizes.windowWidth),
      child: SenseNotePopup(
        mode: mode,
        facts: facts,
        initialText: initialText,
        onDone: (r) {
          entry.remove();
          finish(r);
        },
      ),
    ),
  );
  overlay.insert(entry);
  return done.future;
}

/// The facts of connection [peerId] for the popup's box (zero when its layer is not up).
SenseNoteFacts senseNoteFactsOf(String peerId, {String computer = ''}) {
  final c = SenseLayerController.find(peerId);
  if (c == null) return SenseNoteFacts(computer: computer);
  return SenseNoteFacts(
    computer: computer,
    duration: c.elapsed,
    messages: c.host.chatMessages(),
    files: c.host.chatFiles(),
  );
}

/// "Bitir" (OT binds it): with "Oturum bitince not sor" on ([ask]) the popup comes first —
/// Vazgeç keeps the connection, Notsuz bitir / Notu kaydet ve bitir end it and the ended card
/// says "Bağlantıyı sen bitirdin". With [ask] off the connection ends at once (the card then
/// offers "Not ekle"). Returns false when the user stayed.
Future<bool> senseEndWithNote(
  BuildContext context, {
  required String peerId,
  required bool ask,
  String computer = '',
  SensePopupController? popups,
}) async {
  if (ask) {
    final r = await senseShowSessionNote(
      context,
      mode: SenseNoteMode.ending,
      facts: senseNoteFactsOf(peerId, computer: computer),
      initialText: SenseSessionNotes.lastText(peerId),
      popups: popups,
    );
    if (!r.ends) return false;
    if (!(r.action == SenseNoteAction.saved && SenseSessionNotes.send(peerId, r.text))) {
      SenseSessionNotes.markSkipped(peerId);
    }
  }
  SenseLayerController.find(peerId)?.endByUser();
  return true;
}

/// Eylemler › Oturuma not ekle (OT binds it; instead of the stock `showAuditDialog`). Shows the
/// toast "Not kaydedildi · …" (or "Not boş") in the nearest [SenseToastHost] ([SenseToast.show]).
Future<void> senseAddNote(
  BuildContext context, {
  required String peerId,
  String computer = '',
  SensePopupController? popups,
}) async {
  final r = await senseShowSessionNote(
    context,
    mode: SenseNoteMode.mid,
    facts: senseNoteFactsOf(peerId, computer: computer),
    initialText: SenseSessionNotes.lastText(peerId),
    popups: popups,
  );
  if (r.action != SenseNoteAction.saved) return;
  final sent = SenseSessionNotes.send(peerId, r.text);
  if (context.mounted) {
    SenseToast.show(context, sent ? SenseNoteStrings.savedToast : SenseNoteStrings.emptyToast);
  }
}
