// Sense Remote: building blocks of the Host-side connection icon and card.
// Pure widgets (data + callbacks), covered by widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../widgets/sense_cm_geometry.dart';
import 'sense_cm_style.dart';

class SenseCmMark extends StatelessWidget {
  const SenseCmMark({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.asset('assets/icon.svg', width: size, height: size);
}

/// Collapsed state: the whole window is this icon.
class SenseCmIcon extends StatelessWidget {
  const SenseCmIcon({
    super.key,
    required this.live,
    required this.unread,
    required this.onTap,
    this.onDragStart,
  });

  final bool live;
  final int unread;
  final VoidCallback onTap;
  final VoidCallback? onDragStart;

  @override
  Widget build(BuildContext context) {
    // No tooltip: it would be clipped by the icon-sized window.
    return Semantics(
        button: true,
        label: senseCmText('icon_tooltip'),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey('sense-cm-icon'),
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            onPanStart: onDragStart == null ? null : (_) => onDragStart!(),
            child: Container(
              width: kSenseCmIconSize.width,
              height: kSenseCmIconSize.height,
              decoration: BoxDecoration(
                color: SenseCmTokens.black,
                borderRadius: BorderRadius.circular(SenseCmTokens.radiusCard),
                border: Border.all(color: SenseCmTokens.iconBorder),
              ),
              child: Stack(
                children: [
                  const Center(child: SenseCmMark(size: 26)),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      key: const ValueKey('sense-cm-live'),
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: live ? SenseCmTokens.live : SenseCmTokens.idle,
                        boxShadow: live
                            ? const [
                                BoxShadow(
                                    color: SenseCmTokens.live, blurRadius: 8)
                              ]
                            : null,
                      ),
                    ),
                  ),
                  if (unread > 0)
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Container(
                        key: const ValueKey('sense-cm-unread'),
                        constraints:
                            const BoxConstraints(minWidth: 16, minHeight: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: SenseCmTokens.accent2,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(unread > 9 ? '9+' : '$unread',
                            style: SenseCmTokens.text(
                                size: 9, weight: FontWeight.w600)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
    );
  }
}

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

class SenseCmPill extends StatelessWidget {
  const SenseCmPill({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: SenseCmTokens.border),
      ),
      child: Text(label,
          style: SenseCmTokens.text(size: 10, color: SenseCmTokens.soft)),
    );
  }
}

class SenseCmBadge extends StatelessWidget {
  const SenseCmBadge({super.key, required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: SenseCmTokens.accent2, borderRadius: BorderRadius.circular(8)),
      child: Text(count > 9 ? '9+' : '$count',
          style: SenseCmTokens.text(size: 9, weight: FontWeight.w600)),
    );
  }
}

class SenseCmBubble extends StatelessWidget {
  const SenseCmBubble({super.key, required this.text, required this.mine});
  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 230),
        decoration: BoxDecoration(
          color: mine ? SenseCmTokens.white : SenseCmTokens.field,
          borderRadius: BorderRadius.circular(12),
          border: mine ? null : Border.all(color: SenseCmTokens.line),
        ),
        child: SelectableText(text,
            style: SenseCmTokens.text(
                color: mine ? SenseCmTokens.black : SenseCmTokens.white,
                weight: mine ? FontWeight.w400 : FontWeight.w300)),
      ),
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

