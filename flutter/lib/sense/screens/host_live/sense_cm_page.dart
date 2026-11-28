// Sense Remote: Host-side Sense icon and card (YH H3, H4). Replaces RustDesk's
// connection manager window on Windows and macOS: during a connection only the
// Sense icon is on screen (it cannot be hidden); a press opens the card beside
// it, "–" brings the icon back. Dropped at a screen edge the icon becomes a
// small tab there.
//
// `SenseHostIcon`, `SenseHostEdgeTab` and `SenseHostCard` are pure widgets
// (data + callbacks) so they run in widget tests; `SenseCmRoot` wires them to
// gFFI (ServerModel, ChatModel) and the window (SenseCm).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../../common.dart';
import '../../../models/chat_model.dart';
import '../../../models/platform_model.dart';
import '../../../models/server_model.dart';
import '../../diag_log.dart';
import '../../strings/host_live.dart';
import '../../components/popup_shell.dart' show SensePopupFrom;
import '../shared/chat/chat_controller.dart';
import 'data/call.dart';
import 'data/chat.dart';
import 'data/end_summary.dart';
import 'data/files.dart';
import 'data/overlay.dart';
import 'data/peer_state.dart';
import 'sense_cm_geometry.dart';
import 'sense_cm_window.dart';
import 'sense_cm_panel.dart';
import 'sense_cm_style.dart';
import 'sense_cm_widgets.dart';
import '../../../desktop/pages/server_page.dart' show checkClickTime, allowRemoteCMModification;

export 'sense_cm_panel.dart';
export 'sense_cm_style.dart';
export 'sense_cm_widgets.dart';

/// The connection the card (and its chat) shows: one with an incoming voice
/// call, then a live screen connection, then any live one, then one waiting
/// for an answer, then any. O6: a live connection comes before a waiting one,
/// so "Bitir" stays in reach while a second login waits (approve mode
/// "click"); the waiting one gets its own box ([senseCmWaiting]).
Client senseCmPick(List<Client> clients) =>
    clients.firstWhereOrNull((c) => !c.disconnected && c.incomingVoiceCall) ??
    clients.firstWhereOrNull(
        (c) => c.authorized && !c.disconnected && c.type_() == ClientType.remote) ??
    clients.firstWhereOrNull((c) => c.authorized && !c.disconnected) ??
    clients.firstWhereOrNull(senseCmNeedsAttention) ??
    clients.first;

/// O6: a connection waiting for "Kabul et" / "Reddet", if any.
Client? senseCmWaiting(List<Client> clients) =>
    clients.firstWhereOrNull((c) => !c.disconnected && !c.authorized);

/// Connection manager root in icon mode (see `DesktopServerPage`).
class SenseCmRoot extends StatefulWidget {
  const SenseCmRoot({super.key});

  @override
  State<SenseCmRoot> createState() => _SenseCmRootState();
}

class _SenseCmRootState extends State<SenseCmRoot> with WindowListener {
  final RxBool _block = false.obs;
  final SenseHostClock _clock = SenseHostClock();
  final Map<int, SenseChatController> _chats = {};
  final Map<int, int> _fed = {};
  late final SenseHostRecordingWatch _recording;

  // Sürüm 12: what the Controllers asked for (#151, #157) and what the ended card says (FH-A3).
  late final SenseHostPeerWatch _peers;
  SenseHostPeerState _peerState = SenseHostPeerState.none;
  final SenseHostEndTracker _ends = SenseHostEndTracker();

  /// Stands in while the shown connection has ended (its chat is dropped).
  late final SenseChatController _idleChat = senseHostChatController(-1);
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Sense Remote: what ConnectionManagerState does for the RustDesk window.
    gFFI.chatModel.isConnManager = true;
    gFFI.serverModel.updateClientState();
    gFFI.chatModel.addListener(_onChatModel);
    windowManager.addListener(this);
    _recording = SenseHostRecordingWatch(
        onRecording: gFFI.serverModel.senseUpdateRecording)
      ..start();
    _peers = SenseHostPeerWatch(onState: (state) {
      if (mounted && state != _peerState) setState(() => _peerState = state);
    })
      ..start();
    // The card's times and the recording strip tick every second.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && (SenseCm.open.value || _anyRecording())) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _recording.stop();
    _peers.stop();
    gFFI.chatModel.removeListener(_onChatModel);
    windowManager.removeListener(this);
    for (final chat in _chats.values) {
      chat.clear();
      chat.dispose();
    }
    _chats.clear();
    _idleChat.dispose();
    super.dispose();
  }

  bool _anyRecording() => gFFI.serverModel.clients.any((c) => c.senseRecording);

  @override
  void onWindowMoved() {
    SenseCm.onMoved();
  }

  /// One shared chat controller per connection; a gone connection's chat is
  /// dropped (S12).
  void _syncChats(List<Client> clients) {
    final ids = clients.where((c) => !c.disconnected).map((c) => c.id).toSet();
    for (final id in _chats.keys.toList()) {
      if (!ids.contains(id)) {
        final chat = _chats.remove(id)!;
        _fed.remove(id);
        SenseHostChatCall.callEnded(id); // O8
        // After this frame: the card may still listen to it until rebuilt.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          chat.clear();
          chat.dispose();
        });
      }
    }
    for (final id in ids) {
      _chats.putIfAbsent(id, () {
        final chat = senseHostChatController(id);
        if (SenseHostChatFiles.available) chat.startPolling();
        return chat;
      });
    }
  }

  /// New messages from the Controller (ChatModel.receive) go to the card.
  void _onChatModel() {
    final model = gFFI.chatModel;
    for (final client in gFFI.serverModel.clients) {
      final chat = _chats[client.id];
      if (chat == null) continue;
      final key = MessageKey(client.peerId, client.id);
      final list = model.messages[key]?.chatMessages ?? const [];
      _fed[client.id] =
          senseHostFeedMessages(chat, list, model.me.id, _fed[client.id] ?? 0);
    }
  }

  /// RustDesk's voice call flags → the chat's call phase; the card's open
  /// state → the chat's (unread count).
  void _syncState(Client selected, SenseChatController? chat, bool open) {
    if (chat == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || chat != _chats[selected.id]) return;
      chat.setPhase(senseHostCallPhase(
          inCall: selected.inVoiceCall,
          incoming: selected.incomingVoiceCall,
          current: chat.phase));
      // O8: no call (ended on either side) → the next one starts unmuted,
      // as the core does.
      if (chat.phase == SenseCallPhase.idle) SenseHostChatCall.callEnded(selected.id);
      if (open) {
        chat.open();
        if (selected.unreadChatMessageCount.value > 0) {
          selected.unreadChatMessageCount.value = 0;
        }
      } else {
        chat.minimize();
      }
      if (SenseCm.selected.value != selected.id) {
        SenseCm.selected.value = selected.id;
      }
    });
  }

  /// A peer waiting for an answer (access, voice call) opens the card.
  void _autoOpen(List<Client> clients) {
    if (!clients.any(senseCmNeedsAttention) || SenseCm.open.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || SenseCm.open.value) return;
      SenseCm.openPanel();
    });
  }

  void _guarded(Client c, VoidCallback action) => checkClickTime(c.id, action);

  /// Karar #103: the button's name into the record, then the action.
  VoidCallback _logged(String name, VoidCallback action) => () {
        senseUiButton(name, where: 'host.card');
        action();
      };

  Future<void> _closeEnded(Client c) async {
    await bind.cmRemoveDisconnectedConnection(connId: c.id);
    if (await bind.cmGetClientsLength() == 0) {
      windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    Provider.of<ChatModel>(context);
    final clients = serverModel.clients.toList();
    _clock.update(clients);
    // FH-A3: the figures of the ended card are read now, while the chat is still in memory.
    for (final c in clients) {
      _ends.observe(c.id,
          live: c.authorized && !c.disconnected,
          connectedFor: _clock.connectedFor(c.id),
          chat: _chats[c.id]?.entries);
    }
    _ends.forget({for (final c in clients) c.id});
    _syncChats(clients);
    return Obx(() {
      final open = SenseCm.open.value;
      final edge = SenseCm.edge.value;
      final endedAt = SenseCm.endedAt.value; // #101: rebuild when it starts / stops
      if (clients.isEmpty) {
        return const ColoredBox(color: Colors.transparent);
      }
      final selected = senseCmPick(clients);
      final waiting = senseCmWaiting(clients);
      final asked = waiting ?? selected;
      final live = senseHostLive(clients);
      final chat = _chats[selected.id];
      _syncState(selected, chat, open);
      _autoOpen(clients);
      return ListenableBuilder(
        listenable: chat ?? _idleChat,
        builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
          // The window is resized before the card is shown and after it is
          // hidden; in between, never draw the card into the icon's window.
          final fits = constraints.maxWidth >= kSenseCmPanelSize.width * 0.6 &&
              constraints.maxHeight >= kSenseCmPanelSize.height * 0.4;
          if (edge != null && !open) {
            return Container(
              key: const ValueKey('sense-cm-edge-root'),
              color: Colors.transparent,
              alignment: Alignment.center,
              child: SenseHostEdgeTab(edge: edge, onTap: SenseCm.restoreFromEdge),
            );
          }
          if (!open || !fits) {
            // The window behind the icon stays transparent (window options
            // use a transparent background): no plate, no frame (#4).
            return Container(
              key: const ValueKey('sense-cm-icon-root'),
              color: Colors.transparent,
              alignment: Alignment.center,
              child: SenseHostIcon(
                unread: chat?.unread ?? 0,
                inCall: selected.inVoiceCall || selected.incomingVoiceCall,
                transferring: chat?.transferring ?? false,
                recording: selected.senseRecording && !selected.disconnected,
                onTap: SenseCm.openPanel,
                onDragStart: windowManager.startDragging,
              ),
            );
          }
          final card = SenseHostCard(
            client: selected,
            chat: chat ?? _idleChat,
            whoLine: senseHostWhoLine(selected, _clock.connectedFor(selected.id)),
            connectionsLine: senseHostConnectionsLine(live),
            waiting: waiting,
            recording: selected.senseRecording ? _clock.recordingFor(selected.id) : null,
            canAccept: serverModel.approveMode != 'password',
            canCall: SenseHostChatCall.canStart,
            // Ataç and drop: main_sense_host_offer_files (D3d2).
            pickFiles: SenseHostChatFiles.available ? senseHostPickFiles : null,
            from: SenseCm.anchor.bottom ? SensePopupFrom.bottom : SensePopupFrom.top,
            endedInfo: selected.disconnected ? _ends.infoFor(selected.id) : null,
            chatVisible: _peerState.chatShown,
            adminLine: _peerState.adminLine,
            endedClosingIn: selected.disconnected && endedAt != null
                ? SenseCm.endedSecondsLeft(DateTime.now())
                : null,
            actions: SenseHostCardActions(
              onMinimize: _logged(SenseHostLiveStrings.minimize, SenseCm.closePanel),
              onDragStart: windowManager.startDragging,
              // O6: every connection that is on (screen, terminal, tunnel).
              onEnd: _logged(
                  live.length > 1
                      ? SenseHostLiveStrings.endAll
                      : SenseHostLiveStrings.endConnection,
                  () => senseHostEndAll(live, selected, (c) {
                        _guarded(c, () {
                          _ends.markEndedByHost(c.id);
                          bind.cmCloseConnection(connId: c.id);
                        });
                      })),
              onAccept: _logged(
                  SenseHostLiveStrings.accept,
                  () => _guarded(asked,
                      () => serverModel.sendLoginResponse(asked, true))),
              onReject: _logged(
                  SenseHostLiveStrings.reject,
                  () => _guarded(asked,
                      () => serverModel.sendLoginResponse(asked, false))),
              onCloseEnded: _logged(SenseHostLiveStrings.close,
                  () => _guarded(selected, () => _closeEnded(selected))),
              onAnswerCall: (accept) {
                senseUiButton(accept ? 'call.accept' : 'call.reject', where: 'host.card');
                _guarded(selected,
                    () => SenseHostChatCall(connId: selected.id).answer(accept));
              },
            ),
          );
          // A peer that controls this computer must not use the card unless
          // that is allowed (same rule as the RustDesk window).
          return allowRemoteCMModification()
              ? card
              : buildRemoteBlock(child: card, block: _block, mask: false);
        }),
      );
    });
  }
}
