// Sense Remote: the Host-side Sense icon (YH H3; prototype `#hico`,
// `.chatico`, `.hedge`) and the edge tab. Pure widgets (data + callbacks),
// covered by widget tests; `SenseCmRoot` wires them to the window.
//
// The old card building blocks below the icon (SenseCmAvatar, SenseCmButton,
// SenseCmTextButton) stay only for screens that still import them
// (host/sense_password_page, host/sense_home_mac, session/*); the Host card no
// longer uses them.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../sense.dart';
import '../../strings/host_live.dart';
import 'sense_cm_geometry.dart';
import 'sense_cm_style.dart';

/// Measures of the icon (`.chatico`, `.chatico .live`, `.chatico b`,
/// `.chatico.recing::after`, `.chatico.incall::before`).
abstract final class SenseHostIconSize {
  static const double dot = 10;
  static const double dotRight = 6;
  static const double dotTop = 8;
  static const double recDot = 9;
  static const double recLeft = 6;
  static const double recBottom = 8;
  static const double ringEdge = 2;
  static const double badge = 18;
  static const double badgeLeft = 2;
  static const double badgeTop = 4;
  static const double badgePadH = 5;
  static const double callRingInset = 4;
  static const double callRingWidth = 2;
  static const double hoverScale = 1.06;
  static const double shadowBlur = 3;
  static const Offset shadowOffset = Offset(0, 2);
  static const double shadowOpacity = 0.85;
}

/// Collapsed state (H3): the transparent logo in a 64 × 64 area, no plate and
/// no frame (#4). Green "connected" dot top right (white and blinking while a
/// file moves), white unread count top left, green ring while a call rings or
/// runs, red blinking dot bottom left while the Controller records.
class SenseHostIcon extends StatefulWidget {
  const SenseHostIcon({
    super.key,
    required this.onTap,
    this.onDragStart,
    this.unread = 0,
    this.inCall = false,
    this.transferring = false,
    this.recording = false,
  });

  final VoidCallback onTap;

  /// The window follows the mouse from here (system drag).
  final VoidCallback? onDragStart;
  final int unread;
  final bool inCall;
  final bool transferring;
  final bool recording;

  @override
  State<SenseHostIcon> createState() => _SenseHostIconState();
}

class _SenseHostIconState extends State<SenseHostIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final mark = Stack(alignment: Alignment.center, children: [
      // drop-shadow(0 2px 6px rgba(0,0,0,.85)): a blurred black copy.
      Transform.translate(
        offset: SenseHostIconSize.shadowOffset,
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(
              sigmaX: SenseHostIconSize.shadowBlur, sigmaY: SenseHostIconSize.shadowBlur),
          child: SenseMark(
            width: SenseSizes.chatIconLogoWidth,
            height: SenseSizes.chatIconLogoHeight,
            color: SenseColors.bg.withOpacity(SenseHostIconSize.shadowOpacity),
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
      label: SenseHostLiveStrings.iconLabel,
      value: widget.unread > 0 ? '${widget.unread}' : null,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: const Key('sense-host-icon'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onPanStart: widget.onDragStart == null ? null : (_) => widget.onDragStart!(),
          child: SizedBox.fromSize(
            size: kSenseCmIconSize,
            child: Stack(clipBehavior: Clip.none, children: [
              if (widget.inCall) const Positioned.fill(child: _CallRing()),
              Center(
                child: Transform.scale(
                    scale: _hover ? SenseHostIconSize.hoverScale : 1.0, child: mark),
              ),
              Positioned(
                right: SenseHostIconSize.dotRight,
                top: SenseHostIconSize.dotTop,
                child: _LiveDot(busy: widget.transferring),
              ),
              if (widget.recording)
                const Positioned(
                  left: SenseHostIconSize.recLeft,
                  bottom: SenseHostIconSize.recBottom,
                  child: _RecDot(),
                ),
              if (widget.unread > 0)
                Positioned(
                  left: SenseHostIconSize.badgeLeft,
                  top: SenseHostIconSize.badgeTop,
                  child: _Badge(count: widget.unread),
                ),
            ]),
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
      key: Key(busy ? 'sense-host-icon-busy' : 'sense-host-icon-live'),
      width: SenseHostIconSize.dot,
      height: SenseHostIconSize.dot,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: busy ? SenseColors.text : SenseColors.ok,
        boxShadow: const [
          BoxShadow(color: SenseColors.bg, spreadRadius: SenseHostIconSize.ringEdge),
        ],
      ),
    );
    return busy ? SenseBlink(spec: SenseMotion.blinkFast, child: dot) : dot;
  }
}

/// `.chatico.recing::after`: red, black edge, red glow, blinking 1,2 s.
class _RecDot extends StatelessWidget {
  const _RecDot();

  @override
  Widget build(BuildContext context) {
    return SenseBlink(
      spec: SenseMotion.blink,
      child: Container(
        key: const Key('sense-host-icon-rec'),
        width: SenseHostIconSize.recDot,
        height: SenseHostIconSize.recDot,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: SenseColors.hot,
          boxShadow: [
            BoxShadow(color: SenseColors.bg, spreadRadius: SenseHostIconSize.ringEdge),
            BoxShadow(color: SenseColors.hot, blurRadius: SenseHostIconSize.recDot),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('sense-host-icon-badge'),
      constraints: const BoxConstraints(
        minWidth: SenseHostIconSize.badge,
        minHeight: SenseHostIconSize.badge,
      ),
      padding: const EdgeInsets.symmetric(horizontal: SenseHostIconSize.badgePadH),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SenseColors.text,
        borderRadius: BorderRadius.circular(SenseHostIconSize.badge / 2),
        boxShadow: const [
          BoxShadow(color: SenseColors.bg, spreadRadius: SenseHostIconSize.ringEdge),
        ],
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: SenseTextStyles.of(
          size: SenseFontSize.hintSmall,
          weight: SenseFontWeight.bold,
          color: SenseColors.bg,
          height: 1,
        ),
      ),
    );
  }
}

/// Green ring growing out of the icon (`@keyframes ring`, 1,6 s).
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
          padding: const EdgeInsets.all(SenseHostIconSize.callRingInset),
          child: Opacity(
            opacity: opacity,
            child: Transform.scale(
              scale: scale,
              child: Container(
                key: const Key('sense-host-icon-ring'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: SenseColors.ok, width: SenseHostIconSize.callRingWidth),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Measures of the edge tab (`.hedge`).
abstract final class SenseHostEdgeSize {
  static const double radius = 10;
  static const double markWidth = 10;
  static const double markHeight = 14;
  static const double dot = 6;
  static const double dotTop = 5;
  static const Offset shadowOffset = Offset(0, 6);
  static const double shadowBlur = 16;
  static const double shadowOpacity = 0.5;
}

/// The icon hidden at a screen edge (H3 "Kenara saklı"): an 18 × 52 tab with
/// half the logo and the green dot, 24 wide under the mouse; a press brings
/// the icon back. It hugs [edge]; the window is the hover width.
class SenseHostEdgeTab extends StatefulWidget {
  const SenseHostEdgeTab({super.key, required this.edge, required this.onTap});

  final SenseCmEdge edge;
  final VoidCallback onTap;

  @override
  State<SenseHostEdgeTab> createState() => _SenseHostEdgeTabState();
}

class _SenseHostEdgeTabState extends State<SenseHostEdgeTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final right = widget.edge == SenseCmEdge.right;
    const r = Radius.circular(SenseHostEdgeSize.radius);
    const side = BorderSide(color: SenseColors.line);
    final tab = AnimatedContainer(
      key: const Key('sense-host-edge'),
      duration: SenseMotion.popupOpen.duration,
      curve: SenseMotion.popupOpen.curve,
      width: _hover ? kSenseCmEdgeSize.width : kSenseCmEdgeTabWidth,
      height: kSenseCmEdgeSize.height,
      decoration: BoxDecoration(
        color: SenseColors.bg,
        borderRadius: right
            ? const BorderRadius.horizontal(left: r)
            : const BorderRadius.horizontal(right: r),
        border: Border(
          top: side,
          bottom: side,
          left: right ? side : BorderSide.none,
          right: right ? BorderSide.none : side,
        ),
        boxShadow: [
          BoxShadow(
            color: SenseColors.bg.withOpacity(SenseHostEdgeSize.shadowOpacity),
            offset: SenseHostEdgeSize.shadowOffset,
            blurRadius: SenseHostEdgeSize.shadowBlur,
          ),
        ],
      ),
      child: Stack(alignment: Alignment.center, children: [
        Transform.flip(
          flipX: !right,
          child: const SenseMark(
            width: SenseHostEdgeSize.markWidth,
            height: SenseHostEdgeSize.markHeight,
            shape: SenseMarkShape.half,
          ),
        ),
        const Positioned(
          top: SenseHostEdgeSize.dotTop,
          child: SenseStatusDot(color: SenseColors.ok, size: SenseHostEdgeSize.dot),
        ),
      ]),
    );
    return Semantics(
      button: true,
      label: SenseHostLiveStrings.edgeTooltip,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: SizedBox.fromSize(
            size: kSenseCmEdgeSize,
            child: Align(
              alignment: right ? Alignment.centerRight : Alignment.centerLeft,
              child: tab,
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Old card blocks, kept for the screens listed at the top ----

class SenseCmAvatar extends StatelessWidget {
  const SenseCmAvatar({super.key, required this.name, required this.size});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: SenseCmTokens.gradient,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Text(senseCmInitials(name),
          style: SenseCmTokens.text(
              size: size * 0.36, weight: FontWeight.w600)),
    );
  }
}

class SenseCmButton extends StatelessWidget {
  const SenseCmButton({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final bg = danger
        ? SenseCmTokens.danger
        : primary
            ? SenseCmTokens.white
            : Colors.transparent;
    final fg = primary && !danger ? SenseCmTokens.black : SenseCmTokens.white;
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SenseCmTokens.radius),
        side: primary || danger
            ? BorderSide.none
            : const BorderSide(color: SenseCmTokens.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(SenseCmTokens.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Center(
            child: Text(label,
                style: SenseCmTokens.text(
                    size: 12, weight: FontWeight.w600, color: fg)),
          ),
        ),
      ),
    );
  }
}

class SenseCmTextButton extends StatelessWidget {
  const SenseCmTextButton(
      {super.key, required this.label, required this.onTap, this.strong = false});
  final String label;
  final VoidCallback onTap;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(label,
            style: SenseCmTokens.text(
                size: 11,
                weight: strong ? FontWeight.w600 : FontWeight.w300,
                color: strong ? SenseCmTokens.white : SenseCmTokens.muted)),
      ),
    );
  }
}

