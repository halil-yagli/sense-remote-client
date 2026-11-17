// Sense Remote: glue between the connection window (remote_page.dart,
// remote_toolbar.dart) and the Sense parts — display map, display info,
// status box, chat panel, ghost mode. Keeps the stock files to a few call
// lines; everything Sense-specific lives here and in sense_remote_*.dart.

import 'dart:async';

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart' show openMonitorInNewTabOrWindow, openMonitorInTheSameTab;
import '../../common/sense_peer_status.dart';
import '../../common/shared_state.dart';
import '../../common/widgets/toolbar.dart'
    show TToggleMenu, allowDisplaySwitchInPrivacyMode, toolbarPrivacyMode;
import '../../consts.dart' show kAllDisplayValue;
import '../../models/chat_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../pages/sense_cm_style.dart';
import 'sense_remote_chat.dart';
import 'sense_remote_display_info.dart';
import 'sense_remote_map.dart';
import 'sense_remote_status.dart';
import 'sense_remote_strings.dart';

/// Panel data older than this is read again when a box opens.
const Duration kSensePeerStatusMaxAge = Duration(seconds: 20);

/// While the status box or the info card is open the data is refreshed at
/// this pace (panel limit: 60 requests per minute per key).
const Duration kSensePeerStatusRefresh = Duration(seconds: 30);

/// State of the Sense parts of one connection window.
class SenseRemoteSession extends ChangeNotifier {
  SenseRemoteSession({
    required this.peerId,
    SensePeerStatusClient? client,
    DateTime Function()? now,
  })  : _client = client ?? SensePeerStatusClient(),
        _now = now ?? DateTime.now;

  static final Map<String, SenseRemoteSession> _byId = {};

  /// One session per connection tab (the tab key is the peer id).
  static SenseRemoteSession of(String id) =>
      _byId.putIfAbsent(id, () => SenseRemoteSession(peerId: id));

  /// Called when the connection page closes.
  static void remove(String id) {
    _byId.remove(id)?.dispose();
  }

  final String peerId;
  final SensePeerStatusClient _client;
  final DateTime Function() _now;

  bool _infoOpen = false;
  bool _statusOpen = false;
  bool _chatOpen = false;
  bool _loading = false;
  bool _disposed = false;
  SensePeerStatusResult? _result;
  DateTime? _fetchedAt;
  Timer? _timer;

  bool get infoOpen => _infoOpen;
  bool get statusOpen => _statusOpen;
  bool get chatOpen => _chatOpen;
  bool get loading => _loading;
  SensePeerStatusResult? get result => _result;
  int get nowS => _now().millisecondsSinceEpoch ~/ 1000;

  void toggleInfo() {
    _infoOpen = !_infoOpen;
    _afterBoxChange();
  }

  void toggleStatus() {
    _statusOpen = !_statusOpen;
    _afterBoxChange();
  }

  void setChatOpen(bool open) {
    if (_chatOpen == open) return;
    _chatOpen = open;
    _notify();
  }

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    _notify();
    final r = await _client.fetch(peerId);
    if (_disposed) return;
    _result = r;
    _fetchedAt = _now();
    _loading = false;
    _notify();
  }

  void _afterBoxChange() {
    _notify();
    final open = _infoOpen || _statusOpen;
    if (!open) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final at = _fetchedAt;
    if (at == null || _now().difference(at) > kSensePeerStatusMaxAge) {
      refresh();
    }
    _timer ??= Timer.periodic(kSensePeerStatusRefresh, (_) => refresh());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// RustDesk displays of the peer, in RustDesk index order.
List<SenseMapDisplay> senseMapDisplays(PeerInfo pi) => [
      for (var i = 0; i < pi.displays.length; i++)
        SenseMapDisplay(
          index: i,
          x: pi.displays[i].x,
          y: pi.displays[i].y,
          width: pi.displays[i].width,
          height: pi.displays[i].height,
          primary: pi.primaryDisplay == i,
        ),
    ];

/// Same behaviour as the stock monitor buttons (_MonitorMenu.onPressed).
void senseOpenDisplay(int i, String id, FFI ffi) {
  final pi = ffi.ffiModel.pi;
  if (CurrentDisplayState.find(id).value == i) return;
  final individual = pi.isSupportMultiDisplay &&
      bind.sessionGetDisplaysAsIndividualWindows(sessionId: ffi.sessionId) ==
          'Y';
  if (individual && i != kAllDisplayValue) {
    openMonitorInNewTabOrWindow(i, ffi.id, pi);
  } else {
    openMonitorInTheSameTab(i, ffi, pi);
  }
}

/// Toolbar: display map + "Tümü". Shown under the same rule as the stock
/// monitor menu in privacy mode.
class SenseRemoteToolbarMap extends StatelessWidget {
  const SenseRemoteToolbarMap(
      {super.key, required this.id, required this.ffi, this.vertical = false});
  final String id;
  final FFI ffi;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final pi = ffi.ffiModel.pi;
      final privacy = PrivacyModeState.find(id);
      final count = pi.displaysCount.value;
      final current = CurrentDisplayState.find(id).value;
      if (count < 1 ||
          !(privacy.isEmpty ||
              allowDisplaySwitchInPrivacyMode(pi, privacy.value))) {
        return const Offstage();
      }
      final displays = senseMapDisplays(pi);
      return SenseRemoteMapBar(
        displays: displays,
        current: current,
        vertical: vertical,
        // Same rule as the stock "All monitors" button.
        allowAll: pi.isSupportMultiDisplay,
        onPick: (i) => senseOpenDisplay(i, id, ffi),
      );
    });
  }
}

/// Toolbar: Ekran bilgisi · Durum · Sohbet · Hayalet mod.
class SenseRemoteToolbarButtons extends StatelessWidget {
  const SenseRemoteToolbarButtons(
      {super.key, required this.id, required this.ffi, this.vertical = false});
  final String id;
  final FFI ffi;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final session = SenseRemoteSession.of(id);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final items = <Widget>[
          SenseRemoteToolButton(
            key: const ValueKey('sense-remote-btn-info'),
            label: senseRemoteText('info'),
            icon: Icons.info_outline_rounded,
            on: session.infoOpen,
            iconOnly: vertical,
            onTap: session.toggleInfo,
          ),
          SenseRemoteToolButton(
            key: const ValueKey('sense-remote-btn-status'),
            label: senseRemoteText('status'),
            icon: Icons.monitor_heart_outlined,
            on: session.statusOpen,
            iconOnly: true,
            onTap: session.toggleStatus,
          ),
          SenseRemoteToolButton(
            key: const ValueKey('sense-remote-btn-chat'),
            label: senseRemoteText('chat'),
            icon: Icons.chat_bubble_outline_rounded,
            on: session.chatOpen,
            iconOnly: vertical,
            onTap: () => senseToggleChat(id, ffi),
          ),
          Obx(() => _ghost(context)),
        ];
        return Flex(
          direction: vertical ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final w in items)
              Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: vertical ? 4 : 2, vertical: vertical ? 2 : 6),
                child: w,
              ),
          ],
        );
      },
    );
  }

  Widget _ghost(BuildContext context) {
    final state = PrivacyModeState.find(id);
    final on = state.value.isNotEmpty;
    final menus = toolbarPrivacyMode(state, context, id, ffi);
    final toggle = senseGhostToggle(menus, on);
    return SenseRemoteToolButton(
      key: const ValueKey('sense-remote-btn-ghost'),
      label: senseRemoteText('ghost'),
      tooltip: toggle == null
          ? senseRemoteText('ghost_unavailable')
          : on
              ? senseRemoteText('ghost_on_tooltip')
              : senseRemoteText('ghost'),
      icon: Icons.visibility_off_outlined,
      on: on,
      filled: true,
      iconOnly: vertical,
      onTap: toggle,
    );
  }
}

/// What the ghost button does: turn the active privacy mode off, or the first
/// available one on. Null when RustDesk offers no privacy mode (no permission,
/// unsupported peer, view only). Pure; covered by tests.
VoidCallback? senseGhostToggle(List<TToggleMenu> menus, bool on) {
  if (menus.isEmpty) return null;
  if (on) {
    for (final m in menus) {
      final change = m.onChanged;
      if (m.value && change != null) return () => change(false);
    }
    final first = menus.first.onChanged;
    return first == null ? null : () => first(false);
  }
  for (final m in menus) {
    final change = m.onChanged;
    if (change != null) return () => change(true);
  }
  return null;
}

/// Opens/closes the Sense chat panel; the stock floating chat stays closed.
void senseToggleChat(String id, FFI ffi) {
  final session = SenseRemoteSession.of(id);
  final open = !session.chatOpen;
  if (open) {
    ffi.chatModel.changeCurrentKey(MessageKey(ffi.id, ChatModel.clientModeID));
    ffi.chatModel.hideChatOverlay();
  }
  session.setChatOpen(open);
}

/// Toolbar button in the prototype's style (.tool / .ghost).
class SenseRemoteToolButton extends StatelessWidget {
  const SenseRemoteToolButton({
    super.key,
    required this.label,
    required this.icon,
    required this.on,
    required this.onTap,
    this.tooltip,
    this.iconOnly = false,
    this.filled = false,
  });

  final String label;
  final String? tooltip;
  final IconData icon;
  final bool on;

  /// Null = disabled.
  final VoidCallback? onTap;
  final bool iconOnly;

  /// "on" fills white (ghost mode) instead of a white outline.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = !enabled
        ? SenseCmTokens.idle
        : on && filled
            ? SenseCmTokens.black
            : on
                ? SenseCmTokens.white
                : SenseCmTokens.soft;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: fg),
        if (!iconOnly) ...[
          const SizedBox(width: 6),
          Text(label,
              style: SenseCmTokens.text(
                  size: 11,
                  weight: on && filled ? FontWeight.w600 : FontWeight.w400,
                  color: fg)),
        ],
      ],
    );
    return Tooltip(
      message: tooltip ?? label,
      child: Semantics(
        button: true,
        toggled: on,
        label: label,
        child: Material(
          color: on && filled ? SenseCmTokens.white : SenseCmTokens.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
                color: on ? SenseCmTokens.white : const Color(0xFF23232C)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: SizedBox(
              height: 30,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: iconOnly ? 7 : 10),
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Layer above the remote image: ghost-mode strip, status box, display info
/// card, chat panel. Empty areas let the pointer through to the remote image.
class SenseRemoteOverlay extends StatefulWidget {
  const SenseRemoteOverlay({super.key, required this.id, required this.ffi});
  final String id;
  final FFI ffi;

  @override
  State<SenseRemoteOverlay> createState() => _SenseRemoteOverlayState();
}

class _SenseRemoteOverlayState extends State<SenseRemoteOverlay> {
  late final SenseRemoteSession _session = SenseRemoteSession.of(widget.id);

  @override
  void initState() {
    super.initState();
    widget.ffi.chatModel.addListener(_onChat);
  }

  @override
  void dispose() {
    widget.ffi.chatModel.removeListener(_onChat);
    super.dispose();
  }

  /// An incoming message opens RustDesk's floating chat; show it in the
  /// Sense panel instead (same messages, same ChatModel).
  void _onChat() {
    final chat = widget.ffi.chatModel;
    if (chat.chatWindowOverlayEntry == null) return;
    scheduleMicrotask(() {
      if (!mounted) return;
      chat.hideChatOverlay();
      if (!_session.chatOpen) {
        chat.changeCurrentKey(
            MessageKey(widget.ffi.id, ChatModel.clientModeID));
        _session.setChatOpen(true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final chatOpen = _session.chatOpen;
        final right = chatOpen ? kSenseRemoteChatWidth + 14 : 14.0;
        return Stack(
          children: [
            Positioned(
              top: 64,
              left: 0,
              right: chatOpen ? kSenseRemoteChatWidth : 0,
              child: Obx(() => PrivacyModeState.find(widget.id).value.isEmpty
                  ? const SizedBox.shrink()
                  : const Center(child: SenseGhostBar())),
            ),
            if (_session.statusOpen || _session.infoOpen)
              Positioned(
                top: 98,
                right: right,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_session.statusOpen)
                      SenseStatusPopup(
                        result: _session.result,
                        loading: _session.loading,
                        nowS: _session.nowS,
                        onRetry: _session.refresh,
                      ),
                    if (_session.statusOpen && _session.infoOpen)
                      const SizedBox(height: 10),
                    if (_session.infoOpen)
                      Obx(() {
                        final pi = widget.ffi.ffiModel.pi;
                        pi.displaysCount.value; // rebuild on display changes
                        return SenseDisplayInfoPanel(
                          displays: senseMapDisplays(pi),
                          current: CurrentDisplayState.find(widget.id).value,
                          result: _session.result,
                          loading: _session.loading,
                          onRetry: _session.refresh,
                        );
                      }),
                  ],
                ),
              ),
            if (chatOpen)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                child: ListenableBuilder(
                  listenable: widget.ffi.chatModel,
                  builder: (context, _) => _chat(),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _chat() {
    final chat = widget.ffi.chatModel;
    final key = MessageKey(widget.ffi.id, ChatModel.clientModeID);
    final List<ChatMessage> messages =
        chat.messages[key]?.chatMessages ?? const [];
    return SenseRemoteChatPanel(
      peerName: widget.ffi.ffiModel.pi.hostname,
      messages: messages,
      myUserId: chat.me.id,
      controller: chat.textController,
      focusNode: chat.inputNode,
      onSend: (text) {
        if (chat.currentKey != key) chat.changeCurrentKey(key);
        chat.send(ChatMessage(text: text, user: chat.me, createdAt: DateTime.now()));
        chat.textController.clear();
      },
      onClose: () => _session.setChatOpen(false),
      onVoice: () =>
          bind.sessionRequestVoiceCall(sessionId: widget.ffi.sessionId),
    );
  }
}

/// "Hayalet mod açık — …" strip under the toolbar (prototype .gbar).
class SenseGhostBar extends StatelessWidget {
  const SenseGhostBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('sense-remote-ghost-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: SenseCmTokens.black.withOpacity(0.85),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: SenseCmTokens.border),
      ),
      child: Text(senseRemoteText('ghost_bar'),
          style: SenseCmTokens.text(size: 11)),
    );
  }
}
