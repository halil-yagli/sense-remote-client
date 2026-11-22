// Sense Remote: Host-side connection icon and card (prototype
// Calisma/prototip/uygulama.html, screen 5). Replaces RustDesk's connection
// manager window on Windows: during a connection only a small, draggable
// Sense icon is on screen; clicking it opens a card with who is connected,
// the permissions, chat, "Bağlantıyı bitir" and "Gizle". The icon itself
// cannot be hidden while a connection is active.
//
// `SenseCmPanel` and `SenseCmIcon` are pure widgets (data + callbacks) so they
// run in widget tests; `SenseCmRoot` wires them to gFFI.

import 'dart:async';

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../../common.dart';
import '../../../models/chat_model.dart';
import '../../../models/platform_model.dart';
import '../../../models/server_model.dart';
import 'sense_cm_geometry.dart';
import 'sense_cm_window.dart';
import 'sense_cm_panel.dart';
import 'sense_cm_style.dart';
import 'sense_cm_widgets.dart';
import '../../../desktop/pages/server_page.dart' show checkClickTime, allowRemoteCMModification;

export 'sense_cm_panel.dart';
export 'sense_cm_style.dart';
export 'sense_cm_widgets.dart';

/// Connection manager root in icon mode (see `DesktopServerPage`).
class SenseCmRoot extends StatefulWidget {
  const SenseCmRoot({super.key});

  @override
  State<SenseCmRoot> createState() => _SenseCmRootState();
}

class _SenseCmRootState extends State<SenseCmRoot> with WindowListener {
  final RxBool _block = false.obs;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Sense Remote: what ConnectionManagerState does for the RustDesk window.
    gFFI.chatModel.isConnManager = true;
    gFFI.serverModel.updateClientState();
    windowManager.addListener(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && SenseCm.open.value) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMoved() {
    SenseCm.onMoved();
  }

  void _track(List<Client> clients) {
    final now = DateTime.now();
    final ids = clients.map((c) => c.id).toSet();
    SenseCm.connectedSince.removeWhere((id, _) => !ids.contains(id));
    for (final c in clients) {
      if (c.authorized && !c.disconnected) {
        SenseCm.connectedSince.putIfAbsent(c.id, () => now);
      }
    }
  }

  Client _selected(List<Client> clients, int selectedId) {
    final attention = clients.firstWhereOrNull(senseCmNeedsAttention);
    return clients.firstWhereOrNull((c) => c.id == selectedId) ??
        attention ??
        clients.first;
  }

  /// A peer waiting for an answer (access, voice call) opens the card.
  void _autoOpen(List<Client> clients) {
    final attention = clients.firstWhereOrNull(senseCmNeedsAttention);
    if (attention == null || SenseCm.open.value) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || SenseCm.open.value) return;
      SenseCm.selected.value = attention.id;
      SenseCm.openPanel();
    });
  }

  /// The chat model follows the connection shown in the card.
  void _syncChat(Client selected) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !SenseCm.open.value) return;
      if (SenseCm.selected.value != selected.id) {
        SenseCm.selected.value = selected.id;
      }
      final key = MessageKey(selected.peerId, selected.id);
      if (gFFI.chatModel.currentKey != key ||
          gFFI.chatModel.currentKey.connId != selected.id) {
        gFFI.chatModel.changeCurrentKey(key);
      }
      if (selected.unreadChatMessageCount.value > 0) {
        selected.unreadChatMessageCount.value = 0;
      }
    });
  }

  void _guarded(Client c, VoidCallback action) =>
      checkClickTime(c.id, action);

  Future<void> _closeEnded(Client c) async {
    await bind.cmRemoveDisconnectedConnection(connId: c.id);
    if (await bind.cmGetClientsLength() == 0) {
      windowManager.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    final chatModel = Provider.of<ChatModel>(context);
    final clients = serverModel.clients.toList();
    _track(clients);
    return Obx(() {
      final open = SenseCm.open.value;
      // Read here so a selection change rebuilds the card.
      final selectedId = SenseCm.selected.value;
      final unread = clients.fold<int>(
          0, (sum, c) => sum + c.unreadChatMessageCount.value);
      final live = clients.any((c) => c.authorized && !c.disconnected);
      _autoOpen(clients);
      return LayoutBuilder(builder: (context, constraints) {
        // The window is resized before the card is shown and after it is
        // hidden; in between, never draw the card into the icon's window.
        final fits = constraints.maxWidth >= kSenseCmPanelSize.width * 0.6 &&
            constraints.maxHeight >= kSenseCmPanelSize.height * 0.6;
        if (clients.isEmpty || !open || !fits) {
          // Sense Remote: the window behind the rounded icon stays transparent
          // (window options use a transparent background), so no black square
          // shows around it on the desktop (design review T3-4).
          return Container(
            key: const ValueKey('sense-cm-icon-root'),
            color: Colors.transparent,
            alignment: Alignment.center,
            child: SenseCmIcon(
              live: live,
              unread: unread,
              onTap: SenseCm.openPanel,
              onDragStart: windowManager.startDragging,
            ),
          );
        }
        final selected = _selected(clients, selectedId);
        _syncChat(selected);
        final key = MessageKey(selected.peerId, selected.id);
        final panel = SenseCmPanel(
          clients: clients,
          selected: selected,
          connectedFor: (c) {
            final since = SenseCm.connectedSince[c.id];
            return since == null ? null : DateTime.now().difference(since);
          },
          messages: chatModel.messages[key]?.chatMessages ?? const [],
          myUserId: chatModel.me.id,
          canAccept: serverModel.approveMode != 'password',
          chatController: chatModel.textController,
          chatFocus: chatModel.inputNode,
          actions: SenseCmActions(
            onHide: SenseCm.closePanel,
            onDragStart: windowManager.startDragging,
            onSelect: (c) => SenseCm.selected.value = c.id,
            onEnd: (c) => _guarded(
                c, () => bind.cmCloseConnection(connId: c.id)),
            onAccept: (c) =>
                _guarded(c, () => serverModel.sendLoginResponse(c, true)),
            onReject: (c) =>
                _guarded(c, () => serverModel.sendLoginResponse(c, false)),
            onCloseEnded: (c) => _guarded(c, () => _closeEnded(c)),
            onVoice: (c, accept) => _guarded(
                c,
                () => bind.cmHandleIncomingVoiceCall(
                    id: c.id, accept: accept)),
            onVoiceEnd: (c) =>
                _guarded(c, () => bind.cmCloseVoiceCall(id: c.id)),
            onSend: (c, text) {
              if (chatModel.currentKey != key) chatModel.changeCurrentKey(key);
              chatModel.send(ChatMessage(
                  text: text, user: chatModel.me, createdAt: DateTime.now()));
              chatModel.textController.clear();
            },
          ),
        );
        // A peer that controls this computer must not use the card unless
        // that is allowed (same rule as the RustDesk window).
        return allowRemoteCMModification()
            ? panel
            : buildRemoteBlock(child: panel, block: _block, mask: false);
      });
    });
  }
}
