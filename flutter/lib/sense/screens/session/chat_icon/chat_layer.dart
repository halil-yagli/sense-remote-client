// Sense Remote: the chat on the Controller window (YH O10, O11 sesli, O12,
// #62). The Sense icon sits at the bottom right of the remote screen and can be
// dragged; a press opens the chat next to it (bottom half: grows up; right
// half: right-aligned to the icon). "–" turns it back into the icon; there is
// no close. Only one popup at a time (T7): opening the chat closes the open
// popup, and any popup opening turns the chat back into the icon.
//
// Pure layout + behaviour; the connection is wired in session_chat.dart.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/chat.dart';
import '../../shared/chat/chat_controller.dart';
import '../../shared/chat/chat_popup.dart';
import '../popups/status/status_widgets.dart' show SenseChatIconPlacement;
import 'chat_icon.dart';
import 'chat_notice.dart';

abstract final class SenseChatLayerSize {
  /// Icon start: 20 px from the bottom-right corner (`.chatico`).
  static const double iconInset = 20;

  /// The icon never goes closer than this to an edge.
  static const double iconEdge = 8;

  /// The popup keeps this gap to the area's edges (`.side`).
  static const double popupEdge = 10;

  /// Notification card gap from the bottom-right corner.
  static const double noticeInset = 20;
}

class SenseChatLayer extends StatefulWidget {
  const SenseChatLayer({
    super.key,
    required this.controller,
    required this.computerName,
    this.labels = SenseChatLabels.controller,
    this.popups,
    this.windowFocused,
    this.onBringToFront,
    this.pickFiles,
    this.dropBuilder,
    this.animate = true,
    this.iconPlacement,
  });

  final SenseChatController controller;

  /// Sense Remote (C1): where the icon is, for the right popups to end above it.
  final ValueNotifier<SenseChatIconPlacement?>? iconPlacement;

  /// Remote computer's name for the notification card.
  final String computerName;
  final SenseChatLabels labels;

  /// The window's popup holder (T7 one popup). Null when the window has none.
  final SensePopupController? popups;

  /// True while the window has focus; the card shows only when it is false.
  /// Null = always focused (no card).
  final ValueListenable<bool>? windowFocused;

  /// Brings the window forward (card press).
  final VoidCallback? onBringToFront;
  final Future<List<String>> Function()? pickFiles;
  final SenseFileDropBuilder? dropBuilder;
  final bool animate;

  @override
  State<SenseChatLayer> createState() => SenseChatLayerState();
}

class SenseChatLayerState extends State<SenseChatLayer> {
  /// Top-left of the icon; null = the default corner.
  Offset? _icon;
  Size _area = Size.zero;
  StreamSubscription<SenseChatIncoming>? _sub;
  SenseChatIncoming? _notice;
  bool _noticeVisible = false;
  Timer? _noticeTimer;

  SenseChatController get c => widget.controller;

  /// Icon position in the layer (tests).
  Offset get iconOffset => _iconAt(_area);
  bool get noticeVisible => _noticeVisible;

  @override
  void initState() {
    super.initState();
    _sub = c.incoming.listen(_onIncoming);
    widget.popups?.addListener(_onPopups);
    c.addListener(_onChat);
  }

  @override
  void didUpdateWidget(SenseChatLayer old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      _sub?.cancel();
      _sub = c.incoming.listen(_onIncoming);
      old.controller.removeListener(_onChat);
      c.addListener(_onChat);
    }
    if (old.popups != widget.popups) {
      old.popups?.removeListener(_onPopups);
      widget.popups?.addListener(_onPopups);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _noticeTimer?.cancel();
    widget.popups?.removeListener(_onPopups);
    c.removeListener(_onChat);
    super.dispose();
  }

  bool _wasOpen = false;

  void _onChat() {
    // Chat opened: close the other popup (one popup at a time).
    if (c.isOpen && !_wasOpen) {
      widget.popups?.close();
      _hideNotice();
    }
    _wasOpen = c.isOpen;
    if (mounted) setState(() {});
  }

  void _onPopups() {
    // Another popup opened: the chat goes back to the icon.
    if (widget.popups?.isOpen == true && c.isOpen) c.minimize();
  }

  bool get _focused => widget.windowFocused?.value ?? true;

  void _onIncoming(SenseChatIncoming m) {
    if (_focused) return;
    final author = widget.labels.peer;
    setState(() {
      _notice = SenseChatIncoming(
        text: m.isFile
            ? SenseChatStrings.noticeFile(author, m.text)
            : SenseChatStrings.noticeBody(author, m.text),
        isFile: m.isFile,
        at: m.at,
      );
      _noticeVisible = true;
    });
    _noticeTimer?.cancel();
    _noticeTimer = Timer(SenseChatNoticeSize.hold, _hideNotice);
  }

  void _hideNotice() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    if (_noticeVisible && mounted) setState(() => _noticeVisible = false);
  }

  void _noticeTap() {
    widget.onBringToFront?.call();
    _hideNotice();
    c.open();
  }

  Offset _iconAt(Size area) {
    const s = SenseSizes.chatIcon;
    final def = Offset(area.width - s - SenseChatLayerSize.iconInset,
        area.height - s - SenseChatLayerSize.iconInset);
    final p = _icon ?? def;
    const e = SenseChatLayerSize.iconEdge;
    return Offset(
      p.dx.clamp(e, math.max(e, area.width - s - e)),
      p.dy.clamp(e, math.max(e, area.height - s - e)),
    );
  }

  void _drag(Offset delta) {
    setState(() => _icon = _iconAt(_area) + delta);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      _area = Size(box.maxWidth, box.maxHeight);
      final icon = _iconAt(_area);
      final place = widget.iconPlacement;
      if (place != null) {
        final next = SenseChatIconPlacement(
            icon: icon & const Size.square(SenseSizes.chatIcon), area: _area);
        if (place.value != next) {
          WidgetsBinding.instance.addPostFrameCallback((_) => place.value = next);
        }
      }
      return Stack(clipBehavior: Clip.none, children: [
        if (!c.isOpen)
          Positioned(
            left: icon.dx,
            top: icon.dy,
            child: SenseChatIcon(
              unread: c.unread,
              inCall: c.phase == SenseCallPhase.active || c.phase == SenseCallPhase.calling,
              transferring: c.transferring,
              onTap: c.open,
              onDrag: _drag,
            ),
          ),
        if (c.isOpen) _popup(context, icon),
        if (_notice != null)
          Positioned(
            right: SenseChatLayerSize.noticeInset,
            bottom: SenseChatLayerSize.noticeInset + SenseSizes.chatIcon,
            child: SenseChatNoticeSlide(
              visible: _noticeVisible,
              child: SenseChatNotice(
                computer: widget.computerName,
                line: _notice!.text,
                onTap: _noticeTap,
              ),
            ),
          ),
      ]);
    });
  }

  Widget _popup(BuildContext context, Offset icon) {
    const s = SenseSizes.chatIcon;
    const edge = SenseChatLayerSize.popupEdge;
    final w = _area.width;
    final h = _area.height;
    final windowWidth = MediaQuery.maybeSizeOf(context)?.width ?? w;
    final width = math.min(SenseLayout.popupWidth(windowWidth), math.max(0.0, w - 2 * edge));
    final rightHalf = icon.dx + s / 2 > w / 2;
    final bottomHalf = icon.dy + s / 2 > h / 2;
    final right = math.max(edge, w - (icon.dx + s));
    final left = math.max(edge, icon.dx);
    final bottom = math.max(edge, h - (icon.dy + s));
    final top = math.max(edge, icon.dy);
    final maxHeight = math.max(0.0, bottomHalf ? h - bottom - edge : h - top - edge);
    return Positioned(
      key: const Key('sense-chat-slot'),
      left: rightHalf ? null : math.min(left, math.max(edge, w - width - edge)),
      right: rightHalf ? math.min(right, math.max(edge, w - width - edge)) : null,
      top: bottomHalf ? null : top,
      bottom: bottomHalf ? bottom : null,
      width: width,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SenseChatPopup(
          controller: c,
          labels: widget.labels,
          onMinimize: c.minimize,
          pickFiles: widget.pickFiles,
          dropBuilder: widget.dropBuilder,
          from: bottomHalf ? SensePopupFrom.bottom : SensePopupFrom.top,
          animateIn: widget.animate,
        ),
      ),
    );
  }
}
