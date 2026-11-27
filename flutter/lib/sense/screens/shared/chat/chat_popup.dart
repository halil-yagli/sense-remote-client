// Sense Remote: the chat popup (YH O10, O11 sesli, O12; onaylı
// 2026-11-22_popuplar-ve-sohbet `.pane[data-p=chat]`, `.chathead`,
// `.chatmsgs`, `.pfoot`). Same frame as every popup (SensePopupShell look), but
// the call row stays fixed while only the messages scroll ("Görüntü ve
// düğmeler sabit, mesajlar kayar"), so the frame is drawn here. Header has
// only "–" (back to the icon; no close).
//
// Used by the Controller window (session/chat_icon) and by the Host card (C5,
// with [SenseChatLabels.host]). A call from the Host shows the green
// "Sahadaki kişi sesli arıyor · Reddet / Kabul et" box above the call row (#73).

import 'package:flutter/material.dart';

import '../../../sense.dart';
import '../../../strings/chat.dart';
import 'chat_bubbles.dart';
import 'chat_call.dart';
import 'chat_composer.dart';
import 'chat_controller.dart';
import 'chat_entry.dart';

/// Puts a file-drop area around [child]; calls [onFiles] with the dropped
/// paths. The Controller window passes a desktop_drop wrapper; tests pass none.
typedef SenseFileDropBuilder = Widget Function(
    Widget child, void Function(List<String> paths) onFiles, ValueChanged<bool> onHover);

class SenseChatPopup extends StatefulWidget {
  const SenseChatPopup({
    super.key,
    required this.controller,
    this.labels = SenseChatLabels.controller,
    this.onMinimize,
    this.pickFiles,
    this.dropBuilder,
    this.from = SensePopupFrom.bottom,
    this.animateIn = true,
    this.canCall = true,
  });

  final SenseChatController controller;
  final SenseChatLabels labels;

  /// "–" and a tap on the header.
  final VoidCallback? onMinimize;

  /// Ataç: lets the person choose files; null hides the button.
  final Future<List<String>> Function()? pickFiles;
  final SenseFileDropBuilder? dropBuilder;
  final SensePopupFrom from;
  final bool animateIn;

  /// "Ara" is available (Host side: D3d2).
  final bool canCall;

  static const EdgeInsets headPadding = EdgeInsets.fromLTRB(12, 10, 12, 0);
  static const EdgeInsets messagesPadding = EdgeInsets.fromLTRB(12, 8, 12, 10);

  @override
  State<SenseChatPopup> createState() => _SenseChatPopupState();
}

class _SenseChatPopupState extends State<SenseChatPopup> {
  bool _dropHover = false;
  final ScrollController _scroll = ScrollController();

  SenseChatController get c => widget.controller;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _attach() async {
    final pick = widget.pickFiles;
    if (pick == null) return;
    final paths = await pick();
    if (paths.isNotEmpty) await c.sendFiles(paths);
  }

  @override
  Widget build(BuildContext context) {
    final frame = ListenableBuilder(
      listenable: c,
      builder: (context, _) => _frame(context),
    );
    Widget child = frame;
    final drop = widget.dropBuilder;
    if (drop != null) {
      child = drop(child, (paths) => c.sendFiles(paths), (v) {
        if (mounted && v != _dropHover) setState(() => _dropHover = v);
      });
    }
    child = Semantics(
      container: true,
      explicitChildNodes: true,
      label: SenseChatStrings.title,
      child: child,
    );
    return widget.animateIn ? SensePopupEnter(from: widget.from, child: child) : child;
  }

  Widget _frame(BuildContext context) {
    final inCall = c.phase == SenseCallPhase.calling || c.phase == SenseCallPhase.active;
    return Container(
      key: const Key('sense-chat-popup'),
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: _dropHover ? SenseColors.text : SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.popup),
        boxShadow: SensePopupShell.shadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SenseRadii.popup - 1),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(subtitle: widget.labels.subtitle, onMinimize: widget.onMinimize),
            Container(height: 1, color: SenseColors.line),
            Padding(
              padding: SenseChatPopup.headPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // #73: the other side calls — its own box, not "Ara".
                  if (c.phase == SenseCallPhase.incoming) ...[
                    SenseIncomingCallBox(
                      text: widget.labels.incomingCall,
                      onAnswer: (accept) => accept ? c.startCall() : c.endCall(),
                    ),
                    const SizedBox(height: SenseChatCallSize.ringGap),
                  ],
                  SenseCallTicker(
                    controller: c,
                    builder: (context, elapsed) => SenseCallRow(
                      phase: c.phase,
                      elapsed: elapsed,
                      onlineText: widget.labels.peerOnline,
                      onCall: widget.canCall ? c.startCall : null,
                      onEnd: c.endCall,
                    ),
                  ),
                  if (inCall) ...[
                    const SizedBox(height: 8),
                    SenseMicButton(call: c.call),
                  ],
                ],
              ),
            ),
            Flexible(child: _messages()),
            Container(height: 1, color: SenseColors.line),
            SenseChatComposer(
              onSend: c.send,
              onAttach: widget.pickFiles == null ? null : _attach,
            ),
          ],
        ),
      ),
    );
  }

  Widget _messages() {
    final entries = c.entries;
    // Newest at the bottom and in view when opened: a reversed list.
    final rows = <Widget>[
      for (final e in entries.reversed) _row(e),
      const SenseChatWipeNote(),
    ];
    return RawScrollbar(
      controller: _scroll,
      thickness: SenseSizes.scrollbarThumb,
      radius: const Radius.circular(SenseSizes.scrollbarThumb),
      thumbColor: SenseColors.lineStrong,
      crossAxisMargin: (SenseSizes.scrollbarArea - SenseSizes.scrollbarThumb) / 2,
      child: ListView(
        key: const Key('sense-chat-messages'),
        controller: _scroll,
        reverse: true,
        shrinkWrap: true,
        primary: false,
        padding: SenseChatPopup.messagesPadding,
        children: rows,
      ),
    );
  }

  Widget _row(SenseChatEntry e) {
    final author = e.mine ? SenseChatStrings.me : widget.labels.peer;
    final time = senseChatTime(e.at);
    switch (e) {
      case SenseChatText():
        return SenseChatBubble(text: e.text, author: author, time: time, mine: e.mine);
      case SenseChatFileEntry():
        final job = c.job(e.jobId);
        if (job == null) return const SizedBox.shrink();
        return SenseFileBubble(
          key: Key('sense-file-${job.id}'),
          job: job,
          author: author,
          time: time,
          onReveal: job.path.isEmpty ? null : () => c.files.reveal(job.path),
          onRetry: c.canRetry(job.id) ? () => c.retry(job.id) : null,
        );
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.subtitle, required this.onMinimize});

  final String subtitle;
  final VoidCallback? onMinimize;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(children: [
        const Text(
          SenseChatStrings.title,
          style: TextStyle(
            fontFamily: SenseFont.family,
            fontSize: SenseFontSize.popupTitle,
            fontWeight: SenseFontWeight.bold,
            color: SenseColors.text,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: SenseFont.family,
              fontSize: SenseFontSize.popupSubtitle,
              fontWeight: SenseFontWeight.thin,
              color: SenseColors.textMuted,
            ),
          ),
        ),
        if (onMinimize != null)
          SensePopupIconButton(
            key: const Key('sense-chat-minimize'),
            glyph: '–',
            tooltip: SenseChatStrings.minimize,
            onPressed: onMinimize!,
          ),
      ]),
    );
    if (onMinimize == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('sense-chat-header'),
        behavior: HitTestBehavior.opaque,
        onTap: onMinimize,
        child: row,
      ),
    );
  }
}
