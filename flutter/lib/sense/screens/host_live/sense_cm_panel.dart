// Sense Remote: the open card of the Host-side connection icon: who is
// connected, permissions, chat, "Bağlantıyı bitir" and "Gizle". Pure widget
// (data + callbacks), covered by widget tests; `SenseCmRoot` wires it.

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';

import '../../../models/server_model.dart';
import 'sense_cm_geometry.dart';
import 'sense_cm_style.dart';
import 'sense_cm_widgets.dart';

/// Actions of the card; the root wires them to the connection manager.
class SenseCmActions {
  const SenseCmActions({
    required this.onHide,
    required this.onSelect,
    required this.onEnd,
    required this.onAccept,
    required this.onReject,
    required this.onCloseEnded,
    required this.onVoice,
    required this.onVoiceEnd,
    required this.onSend,
    this.onDragStart,
  });

  final VoidCallback onHide;
  final ValueChanged<Client> onSelect;
  final ValueChanged<Client> onEnd;
  final ValueChanged<Client> onAccept;
  final ValueChanged<Client> onReject;
  final ValueChanged<Client> onCloseEnded;
  final void Function(Client client, bool accept) onVoice;
  final ValueChanged<Client> onVoiceEnd;
  final void Function(Client client, String text) onSend;
  final VoidCallback? onDragStart;
}

/// Open state: the card.
class SenseCmPanel extends StatelessWidget {
  const SenseCmPanel({
    super.key,
    required this.clients,
    required this.selected,
    required this.connectedFor,
    required this.messages,
    required this.myUserId,
    required this.canAccept,
    required this.chatController,
    required this.chatFocus,
    required this.actions,
  });

  final List<Client> clients;
  final Client selected;
  final Duration? Function(Client client) connectedFor;
  final List<ChatMessage> messages; // newest first, as ChatModel keeps them
  final String myUserId;
  final bool canAccept; // false when the approve mode is "password"
  final TextEditingController chatController;
  final FocusNode chatFocus;
  final SenseCmActions actions;

  String _status(Client c) {
    if (c.disconnected) return senseCmText('ended');
    if (!c.authorized) return senseCmText('waiting');
    final d = connectedFor(c);
    return d == null
        ? senseCmText('connected')
        : '${senseCmText('connected')} · ${formatSenseCmDuration(d)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = selected;
    final showChat = c.authorized && !c.disconnected;
    return Material(
      color: SenseCmTokens.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SenseCmTokens.radiusCard + 2),
        side: const BorderSide(color: SenseCmTokens.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: DefaultTextStyle(
        style: SenseCmTokens.text(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(c),
            if (clients.length > 1) _list(),
            _who(c),
            _permissions(c),
            if (!c.disconnected && !c.authorized) _request(c),
            if (!c.disconnected && c.incomingVoiceCall) _voiceRequest(c),
            if (!c.disconnected && c.inVoiceCall) _voiceOn(c),
            if (showChat)
              Expanded(child: _chat(c))
            else
              Expanded(
                child: c.disconnected
                    ? Center(
                        child: Text(senseCmText('disconnected'),
                            style: SenseCmTokens.text(
                                color: SenseCmTokens.muted)))
                    : const SizedBox.shrink(),
              ),
            _footer(c),
          ],
        ),
      ),
    );
  }

  Widget _header(Client c) {
    final live = c.authorized && !c.disconnected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: actions.onDragStart == null
          ? null
          : (_) => actions.onDragStart!(),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: SenseCmTokens.line))),
        child: Row(
          children: [
            const SenseCmMark(size: 18),
            const SizedBox(width: 8),
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: senseCmText('brand_bold'),
                  style:
                      SenseCmTokens.text(size: 13, weight: FontWeight.w700)),
              TextSpan(
                  text: senseCmText('brand_light'),
                  style:
                      SenseCmTokens.text(size: 13, weight: FontWeight.w200)),
            ])),
            const SizedBox(width: 8),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: live ? SenseCmTokens.live : SenseCmTokens.idle),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(_status(c),
                        key: const ValueKey('sense-cm-status'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SenseCmTokens.text(
                            size: 11,
                            color: live
                                ? SenseCmTokens.live
                                : SenseCmTokens.muted)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            SenseCmTextButton(
              key: const ValueKey('sense-cm-hide'),
              label: senseCmText('hide'),
              onTap: actions.onHide,
            ),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 132),
      child: Container(
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: SenseCmTokens.line))),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          shrinkWrap: true,
          children: [
            for (final client in clients)
              InkWell(
                key: ValueKey('sense-cm-row-${client.id}'),
                onTap: () => actions.onSelect(client),
                child: Container(
                  color: client.id == selected.id
                      ? SenseCmTokens.field
                      : Colors.transparent,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Row(
                    children: [
                      SenseCmAvatar(name: client.name, size: 24),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(client.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SenseCmTokens.text(
                                weight: client.id == selected.id
                                    ? FontWeight.w600
                                    : FontWeight.w300)),
                      ),
                      Text(_status(client),
                          style: SenseCmTokens.text(
                              size: 10, color: SenseCmTokens.muted)),
                      if (client.unreadChatMessageCount.value > 0) ...[
                        const SizedBox(width: 6),
                        SenseCmBadge(count: client.unreadChatMessageCount.value),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _who(Client c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Row(
        children: [
          SenseCmAvatar(name: c.name, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.name,
                    key: const ValueKey('sense-cm-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SenseCmTokens.text(
                        size: 13, weight: FontWeight.w600)),
                Text(senseCmKindText(c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SenseCmTokens.text(
                        size: 11, color: SenseCmTokens.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissions(Client c) {
    final perms = senseCmPermissions(c);
    if (perms.isEmpty || c.disconnected) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final p in perms) SenseCmPill(label: p)],
      ),
    );
  }

  Widget _request(Client c) {
    return _notice(
      senseCmText('request'),
      [
        if (canAccept)
          SenseCmButton(
              key: const ValueKey('sense-cm-accept'),
              label: senseCmText('accept'),
              primary: true,
              onTap: () => actions.onAccept(c)),
        SenseCmButton(
            key: const ValueKey('sense-cm-reject'),
            label: senseCmText('reject'),
            onTap: () => actions.onReject(c)),
      ],
    );
  }

  Widget _voiceRequest(Client c) => _notice(senseCmText('voice_request'), [
        SenseCmButton(
            label: senseCmText('accept'),
            primary: true,
            onTap: () => actions.onVoice(c, true)),
        SenseCmButton(
            label: senseCmText('reject'),
            onTap: () => actions.onVoice(c, false)),
      ]);

  Widget _voiceOn(Client c) => _notice(senseCmText('voice_on'), [
        SenseCmButton(
            label: senseCmText('voice_end'), onTap: () => actions.onVoiceEnd(c)),
      ]);

  Widget _notice(String text, List<Widget> buttons) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SenseCmTokens.field,
        borderRadius: BorderRadius.circular(SenseCmTokens.radius),
        border: Border.all(color: SenseCmTokens.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text, style: SenseCmTokens.text(color: SenseCmTokens.soft)),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: buttons[i]),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _chat(Client c) {
    void send() {
      final text = chatController.text.trim();
      if (text.isEmpty) return;
      actions.onSend(c, text);
    }

    return Container(
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: SenseCmTokens.line))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(senseCmText('chat_empty'),
                          textAlign: TextAlign.center,
                          style: SenseCmTokens.text(
                              size: 11, color: SenseCmTokens.muted)),
                    ),
                  )
                : ListView.builder(
                    key: const ValueKey('sense-cm-messages'),
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    itemCount: messages.length,
                    itemBuilder: (_, i) {
                      final m = messages[i];
                      return SenseCmBubble(
                          text: m.text, mine: m.user.id == myUserId);
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: SenseCmTokens.line))),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('sense-cm-input'),
                    controller: chatController,
                    focusNode: chatFocus,
                    style: SenseCmTokens.text(),
                    cursorColor: SenseCmTokens.white,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => send(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: senseCmText('chat_hint'),
                      hintStyle:
                          SenseCmTokens.text(color: SenseCmTokens.muted),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                SenseCmTextButton(
                  key: const ValueKey('sense-cm-send'),
                  label: senseCmText('send'),
                  strong: true,
                  onTap: send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(Client c) {
    // A waiting peer is answered with "Reddet" above; no second button.
    if (!c.authorized && !c.disconnected) return const SizedBox(height: 12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: c.disconnected
          ? SenseCmButton(
              key: const ValueKey('sense-cm-close'),
              label: senseCmText('close'),
              onTap: () => actions.onCloseEnded(c))
          : SenseCmButton(
              key: const ValueKey('sense-cm-end'),
              label: senseCmText('end'),
              danger: true,
              onTap: () => actions.onEnd(c)),
    );
  }
}

