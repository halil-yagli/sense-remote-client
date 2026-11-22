// Sense Remote: button and the shared interaction base of the library (YH T3, T7;
// prototype `.btn`, `.btn.pri`, `.btn.end`, `.btn.on`, `.btn.sm`).
// Every clickable part of the library is built on [SenseInteractive]: mouse, Enter /
// Space and a visible keyboard focus ring behave the same everywhere.
import 'package:flutter/material.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';

/// What the pointer and keyboard are doing to a control right now.
@immutable
class SenseInteractionState {
  const SenseInteractionState({
    this.hovered = false,
    this.pressed = false,
    this.focused = false,
    this.enabled = true,
  });

  final bool hovered;
  final bool pressed;

  /// Keyboard focus that must be drawn (only in keyboard mode, like `:focus-visible`).
  final bool focused;
  final bool enabled;
}

typedef SenseInteractiveBuilder = Widget Function(
    BuildContext context, SenseInteractionState state);

/// Hover, press, keyboard focus and activation for any library control.
/// [onTap] null = disabled: not focusable, not clickable, "not allowed" cursor.
class SenseInteractive extends StatefulWidget {
  const SenseInteractive({
    super.key,
    required this.builder,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.semanticLabel,
    this.tooltip,
    this.button = true,
    this.toggled,
    this.selected,
    this.mouseCursor,
  });

  final SenseInteractiveBuilder builder;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? semanticLabel;
  final String? tooltip;
  final bool button;
  final bool? toggled;
  final bool? selected;
  final MouseCursor? mouseCursor;

  @override
  State<SenseInteractive> createState() => _SenseInteractiveState();
}

class _SenseInteractiveState extends State<SenseInteractive> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onTap != null;

  void _activate() => widget.onTap?.call();

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    final state = SenseInteractionState(
      hovered: enabled && _hovered,
      pressed: enabled && _pressed,
      focused: enabled && _focused,
      enabled: enabled,
    );
    Widget child = FocusableActionDetector(
      enabled: enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: widget.mouseCursor ??
          (enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          _activate();
          return null;
        }),
      },
      onShowHoverHighlight: (v) {
        if (_hovered != v) setState(() => _hovered = v);
      },
      onShowFocusHighlight: (v) {
        if (_focused != v) setState(() => _focused = v);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: enabled ? _activate : null,
        child: widget.builder(context, state),
      ),
    );
    child = Semantics(
      button: widget.button,
      enabled: enabled,
      toggled: widget.toggled,
      selected: widget.selected,
      label: widget.semanticLabel,
      onTap: enabled ? _activate : null,
      child: child,
    );
    final tooltip = widget.tooltip;
    if (tooltip != null && tooltip.isNotEmpty) {
      child = Tooltip(message: tooltip, child: child);
    }
    return child;
  }
}

/// White ring just outside a control while it has keyboard focus. It is painted
/// outside the box, so focusing never moves the layout.
class SenseFocusRing extends StatelessWidget {
  const SenseFocusRing({
    super.key,
    required this.visible,
    required this.child,
    this.radius = SenseRadii.button,
  });

  final bool visible;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => CustomPaint(
        foregroundPainter: visible ? _FocusRingPainter(radius) : null,
        child: child,
      );
}

class _FocusRingPainter extends CustomPainter {
  _FocusRingPainter(this.radius);

  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    const out = SenseUi.focusRingGap + SenseUi.focusRingWidth / 2;
    final rect = (Offset.zero & size).inflate(out);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius + out)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = SenseUi.focusRingWidth
        ..color = SenseColors.text,
    );
  }

  @override
  bool shouldRepaint(_FocusRingPainter old) => old.radius != radius;
}

/// `.btn` (normal), `.btn.pri` (primary, white), `.btn.end` (danger, red),
/// `.btn.on` (switched on: white, e.g. Kayıt açık).
enum SenseButtonKind { normal, primary, danger, on }

/// `.btn` (6×11, 12 px) and `.btn.sm` (5×10, 11,5 px).
enum SenseButtonSize { regular, small }

/// The library button. [onPressed] null = not available: drawn faded (a primary
/// button whose condition is not met is faded, not hidden).
class SenseButton extends StatelessWidget {
  const SenseButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = SenseButtonKind.normal,
    this.size = SenseButtonSize.regular,
    this.leading,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final SenseButtonKind kind;
  final SenseButtonSize size;

  /// Small icon before the label (12–14 px).
  final Widget? leading;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Full width (setup steps, popup footers).
  final bool expand;

  /// Horizontal padding of a regular button: 11, or 9 at or under 1500 px (T9).
  static double paddingH(double windowWidth, SenseButtonSize size) {
    if (size == SenseButtonSize.small) return SenseSizes.buttonSmallPadH;
    return windowWidth <= SenseBreakpoints.medium
        ? SenseUi.buttonPadHMedium
        : SenseSizes.buttonPadH;
  }

  ({Color bg, Color border, Color fg}) _colors(SenseInteractionState s) {
    switch (kind) {
      case SenseButtonKind.normal:
        final bg = s.pressed
            ? SenseColors.raised
            : s.hovered
                ? SenseColors.hover
                : SenseColors.bg;
        return (bg: bg, border: s.hovered ? SenseColors.lineStrong : SenseColors.line, fg: SenseColors.text);
      case SenseButtonKind.primary:
      case SenseButtonKind.on:
        // `.btn.pri:hover` #E6E6EA: white at 90 % on black.
        final bg = s.pressed
            ? SenseColors.textSecondary
            : s.hovered
                ? Color.alphaBlend(SenseColors.text.withOpacity(0.9), SenseColors.bg)
                : SenseColors.text;
        return (bg: bg, border: bg, fg: SenseColors.bg);
      case SenseButtonKind.danger:
        final bg = s.hovered || s.pressed ? SenseColors.dangerHover : SenseColors.danger;
        return (bg: bg, border: bg, fg: SenseColors.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.maybeSizeOf(context)?.width ?? double.infinity;
    final small = size == SenseButtonSize.small;
    final padding = EdgeInsets.symmetric(
      horizontal: paddingH(width, size),
      vertical: small ? SenseSizes.buttonSmallPadV : SenseSizes.buttonPadV,
    );
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : SenseUi.disabledOpacity,
      child: SenseInteractive(
        onTap: onPressed,
        focusNode: focusNode,
        autofocus: autofocus,
        tooltip: tooltip,
        builder: (context, s) {
          final c = _colors(s);
          final text = Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: (small ? SenseTextStyles.buttonSmall : SenseTextStyles.button)
                .copyWith(color: c.fg),
          );
          return SenseFocusRing(
            visible: s.focused,
            child: Container(
              width: expand ? double.infinity : null,
              padding: padding,
              decoration: BoxDecoration(
                color: c.bg,
                border: Border.all(color: c.border),
                borderRadius: BorderRadius.circular(SenseRadii.button),
              ),
              child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (leading != null) ...[
                    IconTheme.merge(
                      data: IconThemeData(color: c.fg, size: SenseFontSize.categoryTitle),
                      child: leading!,
                    ),
                    const SizedBox(width: SenseUi.iconGap),
                  ],
                  Flexible(child: text),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
