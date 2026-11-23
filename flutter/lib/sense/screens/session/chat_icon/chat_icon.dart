// Sense Remote: the Sense icon at the bottom right of the Controller window
// (YH O10: H3 look; onaylı `.chatico`). No plate, no frame: the white mark with
// a dark drop shadow, green "connected" dot (white and blinking while a file
// moves), unread count on the top left, a green ring while in a call. It is
// dragged anywhere; a press without a move opens the chat.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../sense.dart';
import '../../../strings/chat.dart';

abstract final class SenseChatIconSize {
  static const double dot = 10;
  static const double dotRight = 6;
  static const double dotTop = 8;
  static const double ringEdge = 2;
  static const double badge = 18;
  static const double badgeLeft = 2;
  static const double badgeTop = 4;
  static const double callRingInset = 4;
  static const double callRingWidth = 2;
  static const double hoverScale = 1.06;
  static const double dragScale = 1.1;
  static const double shadowBlur = 3;
  static const Offset shadowOffset = Offset(0, 2);

  /// A press that moves more than this is a drag, not a tap.
  static const double dragSlop = 4;
}

class SenseChatIcon extends StatefulWidget {
  const SenseChatIcon({
    super.key,
    required this.onTap,
    required this.onDrag,
    this.onDragEnd,
    this.unread = 0,
    this.inCall = false,
    this.transferring = false,
  });

  final VoidCallback onTap;

  /// Pointer moved by this much (logical px) while dragging.
  final ValueChanged<Offset> onDrag;
  final VoidCallback? onDragEnd;
  final int unread;
  final bool inCall;
  final bool transferring;

  @override
  State<SenseChatIcon> createState() => _SenseChatIconState();
}

class _SenseChatIconState extends State<SenseChatIcon> {
  bool _hover = false;
  bool _dragging = false;
  Offset _moved = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final scale = _dragging
        ? SenseChatIconSize.dragScale
        : (_hover ? SenseChatIconSize.hoverScale : 1.0);
    final mark = Stack(alignment: Alignment.center, children: [
      // drop-shadow(0 2px 6px rgba(0,0,0,.85)): a blurred black copy.
      Transform.translate(
        offset: SenseChatIconSize.shadowOffset,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(
              sigmaX: SenseChatIconSize.shadowBlur, sigmaY: SenseChatIconSize.shadowBlur),
          child: SenseMark(
            width: SenseSizes.chatIconLogoWidth,
            height: SenseSizes.chatIconLogoHeight,
            color: SenseColors.bg.withOpacity(0.85),
          ),
        ),
      ),
      const SenseMark(
        width: SenseSizes.chatIconLogoWidth,
        height: SenseSizes.chatIconLogoHeight,
      ),
    ]);

    return Semantics(
      button: true,
      label: SenseChatStrings.title,
      value: widget.unread > 0 ? '${widget.unread}' : null,
      onTap: widget.onTap,
      child: Tooltip(
        message: SenseChatStrings.iconTooltip,
        child: MouseRegion(
          cursor: _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            key: const Key('sense-chat-icon'),
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _moved = Offset.zero,
            onPanUpdate: (d) {
              _moved += d.delta;
              if (!_dragging && _moved.distance > SenseChatIconSize.dragSlop) {
                setState(() => _dragging = true);
                widget.onDrag(_moved);
              } else if (_dragging) {
                widget.onDrag(d.delta);
              }
            },
            onPanEnd: (_) {
              if (_dragging) {
                setState(() => _dragging = false);
                widget.onDragEnd?.call();
              } else {
                widget.onTap();
              }
            },
            onTap: widget.onTap,
            child: SizedBox(
              width: SenseSizes.chatIcon,
              height: SenseSizes.chatIcon,
              child: Stack(clipBehavior: Clip.none, children: [
                if (widget.inCall) const Positioned.fill(child: _CallRing()),
                Center(child: Transform.scale(scale: scale, child: mark)),
                Positioned(
                  right: SenseChatIconSize.dotRight,
                  top: SenseChatIconSize.dotTop,
                  child: _LiveDot(busy: widget.transferring),
                ),
                if (widget.unread > 0)
                  Positioned(
                    left: SenseChatIconSize.badgeLeft,
                    top: SenseChatIconSize.badgeTop,
                    child: _Badge(count: widget.unread),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      key: Key(busy ? 'sense-chat-icon-busy' : 'sense-chat-icon-live'),
      width: SenseChatIconSize.dot,
      height: SenseChatIconSize.dot,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: busy ? SenseColors.text : SenseColors.ok,
        boxShadow: const [
          BoxShadow(color: SenseColors.bg, spreadRadius: SenseChatIconSize.ringEdge),
        ],
      ),
    );
    return busy ? SenseBlink(spec: SenseMotion.blinkFast, child: dot) : dot;
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('sense-chat-icon-badge'),
      constraints: const BoxConstraints(
        minWidth: SenseChatIconSize.badge,
        minHeight: SenseChatIconSize.badge,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SenseColors.text,
        borderRadius: BorderRadius.circular(SenseChatIconSize.badge / 2),
        boxShadow: const [
          BoxShadow(color: SenseColors.bg, spreadRadius: SenseChatIconSize.ringEdge),
        ],
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          fontFamily: SenseFont.family,
          fontSize: SenseFontSize.hintSmall,
          fontWeight: SenseFontWeight.bold,
          height: 1,
          color: SenseColors.bg,
        ),
      ),
    );
  }
}

/// Green ring growing out of the icon while in a call (`@keyframes ring`).
class _CallRing extends StatefulWidget {
  const _CallRing();

  @override
  State<_CallRing> createState() => _CallRingState();
}

class _CallRingState extends State<_CallRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: SenseMotion.callRing.duration);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = SenseMotion.callRing.curve.transform(_c.value);
        final scale = SenseMotionParams.callRingScaleFrom +
            (SenseMotionParams.callRingScaleTo - SenseMotionParams.callRingScaleFrom) * t;
        final opacity = SenseMotionParams.callRingOpacityFrom * (1 - t);
        return Padding(
          padding: const EdgeInsets.all(SenseChatIconSize.callRingInset),
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Container(
                key: const Key('sense-chat-icon-ring'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: SenseColors.ok, width: SenseChatIconSize.callRingWidth),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
