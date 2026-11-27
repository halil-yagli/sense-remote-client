// Sense Remote: the Host card (YH H4; h02, h05; prototype `#hside` + chatHTML
// host view; onaylı 2026-11-22_popuplar-ve-sohbet). Opens beside the Sense
// icon, "–" brings the icon back (no close). From the top:
//   header "Sense Remote · Sense Department ile" · –
//   red recording strip "Bu bağlantı kaydediliyor · 01:15" (S7, #37)
//   green "Sense Department bağlı" box: kişi · süre · yetkiler + Bağlantıyı bitir
//   incoming voice call "Sense Department sesli arıyor" · Reddet / Kabul et (#67)
//   call row "● Sense Department ile sohbet · Ara" and the chat (C3, shared)
// Usable while the maintenance curtain is on (#22): the CM window stays above it.
//
// Pure widget (data + callbacks), covered by widget tests; `SenseCmRoot`
// wires it.

import 'package:flutter/material.dart';

import '../../../models/server_model.dart';
import '../../sense.dart';
import '../../strings/chat.dart';
import '../../strings/host_live.dart';
import '../shared/chat/chat_bubbles.dart';
import '../shared/chat/chat_call.dart';
import '../shared/chat/chat_composer.dart';
import '../shared/chat/chat_controller.dart';
import '../shared/chat/chat_entry.dart';
import '../shared/chat/chat_popup.dart' show SenseFileDropBuilder;

/// Actions of the card; the root wires them to the connection manager.
class SenseHostCardActions {
  const SenseHostCardActions({
    required this.onMinimize,
    required this.onEnd,
    required this.onAccept,
    required this.onReject,
    required this.onCloseEnded,
    required this.onAnswerCall,
    this.onDragStart,
  });

  /// "–" and a tap on the header: back to the icon.
  final VoidCallback onMinimize;

  /// "Bağlantıyı bitir".
  final VoidCallback onEnd;

  /// Access request (approve mode "click").
  final VoidCallback onAccept;
  final VoidCallback onReject;

  /// "Kapat" of an ended connection.
  final VoidCallback onCloseEnded;

  /// Incoming voice call: Kabul et (true) / Reddet (false).
  final ValueChanged<bool> onAnswerCall;

  /// Dragging the header moves the window.
  final VoidCallback? onDragStart;
}

/// Measures of the card's own boxes (`.recbar`, `.ov`, `.ringin`).
abstract final class SenseHostCardSize {
  static const EdgeInsets headPadding = EdgeInsets.fromLTRB(14, 10, 10, 10);
  static const EdgeInsets bodyPadding = EdgeInsets.fromLTRB(12, 10, 12, 0);
  static const EdgeInsets boxPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 8);
  static const EdgeInsets recPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 7);
  static const double boxGap = 8;
  static const double titleGap = 8;
  static const double metaGap = 4;
  static const double recDot = 8;
  static const double recBorderOpacity = 0.45;
  static const double recFillOpacity = 0.08;
}

class SenseHostCard extends StatefulWidget {
  const SenseHostCard({
    super.key,
    required this.client,
    required this.chat,
    required this.whoLine,
    required this.actions,
    this.recording,
    this.canAccept = true,
    this.canCall = false,
    this.pickFiles,
    this.dropBuilder,
    this.from = SensePopupFrom.bottom,
    this.animateIn = true,
    this.endedClosingIn,
    this.connectionsLine,
    this.waiting,
  });

  /// The one connection (#40: one Controller at a time).
  final Client client;
  final SenseChatController chat;

  /// "Halil Y. · 14 dk · ekran, fare ve klavye, dosya".
  final String whoLine;
  final SenseHostCardActions actions;

  /// How long the Controller has been recording; null = not recording.
  final Duration? recording;

  /// False when the approve mode is "password" (no "Kabul et").
  final bool canAccept;

  /// "Ara" from the Host (D3d2); false draws it faded.
  final bool canCall;

  /// Ataç; null hides it (Host → Controller files wait for D3d2).
  final Future<List<String>> Function()? pickFiles;
  final SenseFileDropBuilder? dropBuilder;
  final SensePopupFrom from;
  final bool animateIn;

  /// #101: seconds until the window closes after every connection ended;
  /// null when it is not closing by itself.
  final int? endedClosingIn;

  /// O6: "2 bağlantı · ekran, terminal" when the Controller holds more than
  /// one connection; the button then reads "Tümünü bitir". Null for one.
  final String? connectionsLine;

  /// O6: a second connection waiting for an answer while [client] is live
  /// (approve mode "click"); shown in its own box above the live one.
  final Client? waiting;

  @override
  State<SenseHostCard> createState() => _SenseHostCardState();
}

class _SenseHostCardState extends State<SenseHostCard> {
  final ScrollController _scroll = ScrollController();
  bool _dropHover = false;

  SenseChatController get c => widget.chat;
  Client get client => widget.client;

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
    Widget child = ListenableBuilder(listenable: c, builder: (context, _) => _frame());
    final drop = widget.dropBuilder;
    if (drop != null && widget.pickFiles != null) {
      child = drop(child, (paths) => c.sendFiles(paths), (v) {
        if (mounted && v != _dropHover) setState(() => _dropHover = v);
      });
    }
    child = Semantics(
      container: true,
      explicitChildNodes: true,
      label: SenseHostLiveStrings.brand,
      child: child,
    );
    return widget.animateIn ? SensePopupEnter(from: widget.from, child: child) : child;
  }

  Widget _frame() {
    final live = client.authorized && !client.disconnected;
    final inCall = c.phase == SenseCallPhase.calling || c.phase == SenseCallPhase.active;
    return Container(
      key: const Key('sense-host-card'),
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: _dropHover ? SenseColors.text : SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.popup),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SenseRadii.popup - 1),
        child: DefaultTextStyle(
          style: SenseTextStyles.body,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onMinimize: widget.actions.onMinimize, onDragStart: widget.actions.onDragStart),
              Container(height: 1, color: SenseColors.line),
              Padding(
                padding: SenseHostCardSize.bodyPadding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.recording != null && !client.disconnected)
                      _RecordingStrip(elapsed: widget.recording!),
                    if (client.disconnected)
                      _EndedBox(
                          onClose: widget.actions.onCloseEnded,
                          closingIn: widget.endedClosingIn)
                    else if (!client.authorized)
                      _request(client)
                    else ...[
                      if (widget.waiting != null && widget.waiting!.id != client.id)
                        _request(widget.waiting!),
                      _ConnectedBox(
                        whoLine: widget.whoLine,
                        connectionsLine: widget.connectionsLine,
                        onEnd: widget.actions.onEnd,
                      ),
                    ],
                    if (live && c.phase == SenseCallPhase.incoming) ...[
                      SenseIncomingCallBox(
                        text: SenseChatLabels.host.incomingCall,
                        keyPrefix: 'sense-host',
                        onAnswer: widget.actions.onAnswerCall,
                      ),
                      const SizedBox(height: SenseHostCardSize.boxGap),
                    ],
                    if (live) ...[
                      SenseCallTicker(
                        controller: c,
                        builder: (context, elapsed) => SenseCallRow(
                          phase: c.phase,
                          elapsed: elapsed,
                          onlineText: SenseChatLabels.host.peerOnline,
                          onCall: widget.canCall ? c.startCall : null,
                          onEnd: c.endCall,
                        ),
                      ),
                      if (inCall) ...[
                        const SizedBox(height: SenseHostCardSize.boxGap),
                        SenseMicButton(call: c.call),
                      ],
                    ],
                  ],
                ),
              ),
              Expanded(child: live ? _messages() : const SizedBox.shrink()),
              if (live) ...[
                Container(height: 1, color: SenseColors.line),
                SenseChatComposer(
                  onSend: c.send,
                  onAttach: widget.pickFiles == null ? null : _attach,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _request(Client who) => _RequestBox(
        name: who.name,
        canAccept: widget.canAccept,
        onAccept: widget.actions.onAccept,
        onReject: widget.actions.onReject,
      );

  Widget _messages() {
    final rows = <Widget>[
      for (final e in c.entries.reversed) _row(e),
      const SenseChatWipeNote(),
    ];
    return RawScrollbar(
      controller: _scroll,
      thickness: SenseSizes.scrollbarThumb,
      radius: const Radius.circular(SenseSizes.scrollbarThumb),
      thumbColor: SenseColors.lineStrong,
      crossAxisMargin: (SenseSizes.scrollbarArea - SenseSizes.scrollbarThumb) / 2,
      child: ListView(
        key: const Key('sense-host-messages'),
        controller: _scroll,
        reverse: true,
        primary: false,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        children: rows,
      ),
    );
  }

  Widget _row(SenseChatEntry e) {
    final author = e.mine ? SenseChatStrings.me : SenseChatLabels.host.peer;
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
          onRetry: c.canRetry(job.id) ? () => c.retry(job.id) : null, // #122
        );
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onMinimize, this.onDragStart});

  final VoidCallback onMinimize;
  final VoidCallback? onDragStart;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('sense-host-header'),
        behavior: HitTestBehavior.opaque,
        onTap: onMinimize,
        onPanStart: onDragStart == null ? null : (_) => onDragStart!(),
        child: Padding(
          padding: SenseHostCardSize.headPadding,
          child: Row(children: [
            Text(
              SenseHostLiveStrings.brand,
              style: SenseTextStyles.of(
                  size: SenseFontSize.popupTitle, weight: SenseFontWeight.bold),
            ),
            const SizedBox(width: SenseHostCardSize.titleGap),
            Expanded(
              child: Text(
                SenseHostLiveStrings.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SenseTextStyles.of(
                  size: SenseFontSize.popupSubtitle,
                  weight: SenseFontWeight.thin,
                  color: SenseColors.textMuted,
                ),
              ),
            ),
            SensePopupIconButton(
              key: const Key('sense-host-minimize'),
              glyph: '–',
              tooltip: SenseHostLiveStrings.minimize,
              onPressed: onMinimize,
            ),
          ]),
        ),
      ),
    );
  }
}

/// `.recbar`: red frame, blinking red dot, "Bu bağlantı kaydediliyor · 01:15".
class _RecordingStrip extends StatelessWidget {
  const _RecordingStrip({required this.elapsed});

  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('sense-host-recording'),
      margin: const EdgeInsets.only(bottom: SenseHostCardSize.boxGap),
      padding: SenseHostCardSize.recPadding,
      decoration: BoxDecoration(
        color: SenseColors.hot.withOpacity(SenseHostCardSize.recFillOpacity),
        border: Border.all(color: SenseColors.hot.withOpacity(SenseHostCardSize.recBorderOpacity)),
        borderRadius: BorderRadius.circular(SenseRadii.category),
      ),
      child: Row(children: [
        const SenseStatusDot(
            color: SenseColors.hot, size: SenseHostCardSize.recDot, blinking: true),
        const SizedBox(width: SenseHostCardSize.titleGap),
        Expanded(
          child: Text(
            SenseHostLiveStrings.recording(senseCallClock(elapsed)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SenseTextStyles.of(
                size: SenseFontSize.hintLarge, color: SenseColors.dangerTextSoft),
          ),
        ),
      ]),
    );
  }
}

/// `.ov` frame used by the who / request / ended boxes.
class _Box extends StatelessWidget {
  const _Box({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: SenseHostCardSize.boxGap),
      padding: SenseHostCardSize.boxPadding,
      decoration: BoxDecoration(
        color: SenseColors.bg,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
      ),
      child: child,
    );
  }
}

class _BoxText extends StatelessWidget {
  const _BoxText({
    required this.title,
    this.titleColor = SenseColors.text,
    this.meta,
    this.extra,
  });

  final String title;
  final Color titleColor;
  final String? meta;

  /// O6: "2 bağlantı · ekran, terminal" under the who line.
  final String? extra;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SenseTextStyles.of(
              size: SenseFontSize.categoryTitleSmall,
              weight: SenseFontWeight.bold,
              color: titleColor),
        ),
        if (meta != null && meta!.isNotEmpty) ...[
          const SizedBox(height: SenseHostCardSize.metaGap),
          Text(
            meta!,
            key: const Key('sense-host-who'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: SenseTextStyles.hint,
          ),
        ],
        if (extra != null && extra!.isNotEmpty) ...[
          const SizedBox(height: SenseHostCardSize.metaGap),
          Text(
            extra!,
            key: const Key('sense-host-connections'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SenseTextStyles.hint,
          ),
        ],
      ],
    );
  }
}

/// `.ov.ok.hinfo`: "Sense Department bağlı" + who line + red Bağlantıyı bitir
/// (O6: with more than one connection, their count and kinds + Tümünü bitir).
class _ConnectedBox extends StatelessWidget {
  const _ConnectedBox({required this.whoLine, required this.onEnd, this.connectionsLine});

  final String whoLine;
  final String? connectionsLine;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return _Box(
      key: const Key('sense-host-connected'),
      child: Row(children: [
        Expanded(
          child: _BoxText(
            title: SenseHostLiveStrings.connected,
            titleColor: SenseColors.ok,
            meta: whoLine,
            extra: connectionsLine,
          ),
        ),
        const SizedBox(width: SenseHostCardSize.boxGap),
        SenseButton(
          key: const Key('sense-host-end'),
          label: connectionsLine == null
              ? SenseHostLiveStrings.endConnection
              : SenseHostLiveStrings.endAll,
          kind: SenseButtonKind.danger,
          onPressed: onEnd,
        ),
      ]),
    );
  }
}

/// A peer waits for an answer (approve mode "click").
class _RequestBox extends StatelessWidget {
  const _RequestBox({
    required this.name,
    required this.canAccept,
    required this.onAccept,
    required this.onReject,
  });

  final String name;
  final bool canAccept;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return _Box(
      key: const Key('sense-host-request'),
      child: Row(children: [
        Expanded(child: _BoxText(title: SenseHostLiveStrings.wantsToConnect(name))),
        const SizedBox(width: SenseHostCardSize.boxGap),
        SenseButton(
          key: const Key('sense-host-reject'),
          label: SenseHostLiveStrings.reject,
          onPressed: onReject,
        ),
        if (canAccept) ...[
          const SizedBox(width: SenseHostCardSize.boxGap),
          SenseButton(
            key: const Key('sense-host-accept'),
            label: SenseHostLiveStrings.accept,
            kind: SenseButtonKind.on,
            onPressed: onAccept,
          ),
        ],
      ]),
    );
  }
}

class _EndedBox extends StatelessWidget {
  const _EndedBox({required this.onClose, this.closingIn});

  final VoidCallback onClose;
  final int? closingIn;

  @override
  Widget build(BuildContext context) {
    return _Box(
      key: const Key('sense-host-ended'),
      child: Row(children: [
        Expanded(
          child: _BoxText(
            title: SenseHostLiveStrings.ended,
            titleColor: SenseColors.textMuted,
            meta: closingIn == null ? null : SenseHostLiveStrings.endedClosing(closingIn!),
          ),
        ),
        SenseButton(
          key: const Key('sense-host-close'),
          label: SenseHostLiveStrings.close,
          onPressed: onClose,
        ),
      ]),
    );
  }
}

