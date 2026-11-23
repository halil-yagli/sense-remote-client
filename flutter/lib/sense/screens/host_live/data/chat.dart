// Sense Remote: the Host card's chat (YH H4) on top of RustDesk's CM chat.
// Messages from the Controller arrive in ChatModel (`chat_model.dart receive`,
// keyed by MessageKey(peerId, connId)); they are handed to the shared
// [SenseChatController]. The Host's own messages go out with `cm_send_chat`.
// S12 (#56): kept in memory only; the controller is cleared when the
// connection ends.

import 'package:dash_chat_2/dash_chat_2.dart';

import '../../../../models/platform_model.dart';
import '../../shared/chat/chat_controller.dart';
import 'call.dart';
import 'files.dart';

/// The chat controller of one CM connection.
SenseChatController senseHostChatController(int connId) => SenseChatController(
      sendText: (t) => bind.cmSendChat(connId: connId, msg: t),
      files: SenseHostChatFiles(connId: connId),
      call: SenseHostChatCall(connId: connId),
    );

/// Feeds the other side's messages of [messages] (any order) that were not
/// handed over yet. [fed] is how many were handed over before; returns the
/// new count.
int senseHostFeedMessages(
    SenseChatController chat, List<ChatMessage> messages, String myId, int fed) {
  final theirs = messages.where((m) => m.user.id != myId).toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  for (var i = fed; i < theirs.length; i++) {
    chat.receiveText(theirs[i].text, at: theirs[i].createdAt);
  }
  return theirs.length > fed ? theirs.length : fed;
}

/// Call phase of the card from the CM client flags.
SenseCallPhase senseHostCallPhase(
    {required bool inCall, required bool incoming, required SenseCallPhase current}) {
  if (inCall) return SenseCallPhase.active;
  if (incoming) return SenseCallPhase.incoming;
  // A call started here keeps "Aranıyor…" until the other side answers.
  if (current == SenseCallPhase.calling) return SenseCallPhase.calling;
  return SenseCallPhase.idle;
}
