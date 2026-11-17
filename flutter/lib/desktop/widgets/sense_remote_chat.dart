// Sense Remote: two-way chat of the connection window, as a right-hand panel
// (prototype Calisma/prototip/uygulama.html, screen 4 .chat). Messages are
// RustDesk's existing chat (ChatModel); the Host side answers from its
// connection icon card (sense_cm_panel.dart). Pure widget: data + callbacks.

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';

import '../pages/sense_cm_style.dart';
import '../pages/sense_cm_widgets.dart' show SenseCmAvatar, SenseCmTextButton;
import 'sense_remote_strings.dart';

const double kSenseRemoteChatWidth = 300;

/// "17:10"
String senseChatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class SenseRemoteChatPanel extends StatelessWidget {
  const SenseRemoteChatPanel({
    super.key,
    required this.peerName,
    required this.messages,
    required this.myUserId,
    required this.controller,
    required this.onSend,
    required this.onClose,
    this.focusNode,
    this.onVoice,
  });

  /// Name of the remote computer as RustDesk shows it.
  final String peerName;

  /// Newest first (ChatModel order).
  final List<ChatMessage> messages;
  final String myUserId;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onSend;
  final VoidCallback onClose;

  /// Voice call request; null hides the button.
  final VoidCallback? onVoice;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('sense-remote-chat'),
      width: kSenseRemoteChatWidth,
      decoration: const BoxDecoration(
        color: SenseCmTokens.black,
        border: Border(left: BorderSide(color: SenseCmTokens.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(child: _messages()),
          _input(),
        ],
      ),
    );
  }

  Widget _header() {
    final title = peerName.trim().isEmpty
        ? senseRemoteText('chat_title_suffix')
        : '${peerName.trim()} · ${senseRemoteText('chat_title_suffix')}';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: SenseCmTokens.line))),
      child: Row(
        children: [
          SenseCmAvatar(name: peerName.trim().isEmpty ? '?' : peerName, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: SenseCmTokens.text(size: 12, weight: FontWeight.w600)),
                Text(senseRemoteText('chat_sub'),
                    style: SenseCmTokens.text(
                        size: 10, color: SenseCmTokens.muted)),
              ],
            ),
          ),
          if (onVoice != null)
            _iconButton(const ValueKey('sense-remote-chat-voice'),
                Icons.mic_none_rounded, senseRemoteText('voice'), onVoice!),
          _iconButton(const ValueKey('sense-remote-chat-close'),
              Icons.close_rounded, senseRemoteText('close'), onClose),
        ],
      ),
    );
  }

  static Widget _iconButton(
      Key key, IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 16, color: SenseCmTokens.muted),
        ),
      ),
    );
  }

  Widget _messages() {
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(senseRemoteText('chat_empty'),
              textAlign: TextAlign.center,
              style: SenseCmTokens.text(size: 11, color: SenseCmTokens.muted)),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('sense-remote-messages'),
      reverse: true,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      itemCount: messages.length,
      itemBuilder: (_, i) {
        final m = messages[i];
        return SenseRemoteBubble(
            text: m.text,
            time: senseChatTime(m.createdAt),
            mine: m.user.id == myUserId);
      },
    );
  }

  Widget _input() {
    void send() {
      final text = controller.text.trim();
      if (text.isEmpty) return;
      onSend(text);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: SenseCmTokens.line))),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('sense-remote-chat-input'),
              controller: controller,
              focusNode: focusNode,
              style: SenseCmTokens.text(),
              cursorColor: SenseCmTokens.white,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => send(),
              decoration: InputDecoration(
                isDense: true,
                hintText: senseRemoteText('chat_hint'),
                hintStyle: SenseCmTokens.text(color: SenseCmTokens.muted),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          SenseCmTextButton(
            key: const ValueKey('sense-remote-chat-send'),
            label: senseRemoteText('send'),
            strong: true,
            onTap: send,
          ),
        ],
      ),
    );
  }
}

/// Own messages on the navy→purple accent, the other side on a dark card
/// (prototype .m.me / .m.them).
class SenseRemoteBubble extends StatelessWidget {
  const SenseRemoteBubble(
      {super.key, required this.text, required this.time, required this.mine});
  final String text;
  final String time;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(12);
    const tail = Radius.circular(4);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(11, 8, 11, 6),
        constraints: const BoxConstraints(maxWidth: 228),
        decoration: BoxDecoration(
          gradient: mine ? SenseCmTokens.gradient : null,
          color: mine ? null : const Color(0xFF15151B),
          border: mine ? null : Border.all(color: const Color(0xFF23232C)),
          borderRadius: BorderRadius.only(
            topLeft: r,
            topRight: r,
            bottomLeft: mine ? r : tail,
            bottomRight: mine ? tail : r,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(text, style: SenseCmTokens.text()),
            const SizedBox(height: 3),
            Text(time,
                style: SenseCmTokens.text(size: 9, color: SenseCmTokens.soft)),
          ],
        ),
      ),
    );
  }
}
