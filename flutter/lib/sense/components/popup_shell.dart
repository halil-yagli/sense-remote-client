// Sense Remote: the right-side popup frame (YH T3, T4, T7). Same layout as the
// locked design (prototip/onayli/2026-11-22_bilgisayar-durumu_ONAYLI.html,
// `.pane`, `.ph`, `.pb`, `.ic`): surface, 1 px line, 12 px corners, header with
// 13/600 title + 11/300 grey subtitle, "–" and "×" on the right, a fixed header
// and a scrolling body. Opens in 0.14 s ease-out from 6 px and 98.5 % (`pop`).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../strings/common.dart';
import '../tokens/sense_tokens.dart';
import 'popup_host.dart' show sensePopupFromOf;

/// Where the popup grows from: the top ones slide down, the chat slides up.
enum SensePopupFrom { top, bottom }

/// Popup opening (T4): opacity 0 → 1, offset ∓6 px → 0, scale 0.985 → 1.
/// Runs once when first built; no rotation.
class SensePopupEnter extends StatefulWidget {
  const SensePopupEnter({
    super.key,
    required this.child,
    this.from = SensePopupFrom.top,
    this.enabled = true,
  });

  final Widget child;
  final SensePopupFrom from;
  final bool enabled;

  /// Opacity, vertical offset and scale at animation progress [t] (0..1, before the curve).
  static ({double opacity, double dy, double scale}) frameAt(double t, SensePopupFrom from) {
    final v = SenseMotion.popupOpen.curve.transform(t.clamp(0.0, 1.0));
    final sign = from == SensePopupFrom.top ? -1.0 : 1.0;
    return (
      opacity: v,
      dy: sign * SenseMotionParams.popupOffset * (1 - v),
      scale: SenseMotionParams.popupScaleFrom + (1 - SenseMotionParams.popupScaleFrom) * v,
    );
  }

  @override
  State<SensePopupEnter> createState() => _SensePopupEnterState();
}

class _SensePopupEnterState extends State<SensePopupEnter> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: SenseMotion.popupOpen.duration);

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) _c.value = 1;
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
      child: widget.child,
      builder: (context, child) {
        final f = SensePopupEnter.frameAt(_c.value, widget.from);
        return Opacity(
          opacity: f.opacity,
          child: Transform.translate(
            offset: Offset(0, f.dy),
            child: Transform.scale(scale: f.scale, child: child),
          ),
        );
      },
    );
  }
}

/// The popup frame. Give it a bounded height (SensePopupHost does) so the body
/// scrolls under the fixed header.
class SensePopupShell extends StatelessWidget {
  const SensePopupShell({
    super.key,
    required this.title,
    this.subtitle,
    required this.body,
    this.footer,
    this.onClose,
    this.onMinimizedChanged,
    this.minimized = false,
    this.headerTrailing,
    this.from,
    this.animateIn = true,
    this.bodyPadding = const EdgeInsets.fromLTRB(12, 10, 12, 10),
    this.scrollController,
  });

  final String title;

  /// Grey text next to the title ("8 sn önce").
  final String? subtitle;
  final Widget body;

  /// Fixed bar under the body (`.pfoot` / chat composer), hidden when minimized.
  final Widget? footer;

  /// "×". Null hides it.
  final VoidCallback? onClose;

  /// "–" and a tap on the header. Null hides "–" and makes the header inert.
  final ValueChanged<bool>? onMinimizedChanged;
  final bool minimized;

  /// Extra header items before "–" (e.g. a Kopyala button).
  final Widget? headerTrailing;
  /// Growth direction; null takes the host slot's (chat at the bottom grows up).
  final SensePopupFrom? from;
  final bool animateIn;
  final EdgeInsets bodyPadding;
  final ScrollController? scrollController;

  static const double headerIconSize = 26;
  static const double headerIconRadius = 7;
  static const double headerIconGlyph = 15;

  /// `box-shadow:0 24px 70px rgba(0,0,0,.7)`.
  static final List<BoxShadow> shadow = [
    BoxShadow(color: SenseColors.bg.withOpacity(0.7), offset: const Offset(0, 24), blurRadius: 70),
  ];

  @override
  Widget build(BuildContext context) {
    final header = _Header(
      title: title,
      subtitle: subtitle,
      minimized: minimized,
      onToggle: onMinimizedChanged == null ? null : () => onMinimizedChanged!(!minimized),
      onClose: onClose,
      trailing: headerTrailing,
    );

    final pane = Container(
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.popup),
        boxShadow: shadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SenseRadii.popup - 1),
        child: LayoutBuilder(builder: (context, c) {
          final bounded = c.maxHeight.isFinite;
          final scroll = _PopupBody(
            controller: scrollController,
            padding: bodyPadding,
            child: body,
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (!minimized) ...[
                Container(height: 1, color: SenseColors.line),
                if (bounded) Flexible(child: scroll) else scroll,
                if (footer != null) ...[
                  Container(height: 1, color: SenseColors.line),
                  footer!,
                ],
              ],
            ],
          );
        }),
      ),
    );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: title,
      child: animateIn ? SensePopupEnter(from: from ?? sensePopupFromOf(context), child: pane) : pane,
    );
  }
}

/// Scrolling body with the thin Sense scrollbar (T3: 10 px area, 4 px thumb).
/// Owns its controller when none is given, so it never borrows the primary one.
class _PopupBody extends StatefulWidget {
  const _PopupBody({required this.controller, required this.padding, required this.child});

  final ScrollController? controller;
  final EdgeInsets padding;
  final Widget child;

  @override
  State<_PopupBody> createState() => _PopupBodyState();
}

class _PopupBodyState extends State<_PopupBody> {
  ScrollController? _own;

  ScrollController get _controller => widget.controller ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return RawScrollbar(
      controller: controller,
      thickness: SenseSizes.scrollbarThumb,
      radius: const Radius.circular(SenseSizes.scrollbarThumb),
      thumbColor: SenseColors.lineStrong,
      crossAxisMargin: (SenseSizes.scrollbarArea - SenseSizes.scrollbarThumb) / 2,
      child: SingleChildScrollView(
        controller: controller,
        primary: false,
        padding: widget.padding,
        child: widget.child,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.minimized,
    required this.onToggle,
    required this.onClose,
    required this.trailing,
  });

  final String title;
  final String? subtitle;
  final bool minimized;
  final VoidCallback? onToggle;
  final VoidCallback? onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      child: Row(children: [
        Expanded(
          child: Row(children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: SenseFont.family,
                  fontSize: SenseFontSize.popupTitle,
                  fontWeight: SenseFontWeight.bold,
                  color: SenseColors.text,
                ),
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: SenseFont.family,
                    fontSize: SenseFontSize.popupSubtitle,
                    fontWeight: SenseFontWeight.thin,
                    color: SenseColors.textMuted,
                  ),
                ),
              ),
            ],
          ]),
        ),
        if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
        if (onToggle != null)
          SensePopupIconButton(
            key: const Key('sense-popup-minimize'),
            glyph: minimized ? '+' : '–',
            tooltip: minimized ? SenseCommonStrings.expand : SenseCommonStrings.minimize,
            onPressed: onToggle!,
          ),
        if (onClose != null) ...[
          const SizedBox(width: 8),
          SensePopupIconButton(
            key: const Key('sense-popup-close'),
            glyph: '×',
            tooltip: SenseCommonStrings.close,
            onPressed: onClose!,
          ),
        ],
      ]),
    );
    if (onToggle == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('sense-popup-header'),
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: row,
      ),
    );
  }
}

/// 26 × 26 header icon (`.ic`): grey glyph, on hover/focus white with a hover
/// background and line border; a keyboard focus shows a white border.
class SensePopupIconButton extends StatefulWidget {
  const SensePopupIconButton({
    super.key,
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
  });

  final String glyph;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<SensePopupIconButton> createState() => _SensePopupIconButtonState();
}

class _SensePopupIconButtonState extends State<SensePopupIconButton> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final lit = _hover || _focus;
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onPressed();
            return null;
          }),
        },
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: SensePopupShell.headerIconSize,
            height: SensePopupShell.headerIconSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: lit ? SenseColors.hover : null,
              border: Border.all(
                color: _focus
                    ? SenseColors.text
                    : (lit ? SenseColors.line : SenseColors.line.withOpacity(0)),
              ),
              borderRadius: BorderRadius.circular(SensePopupShell.headerIconRadius),
            ),
            child: ExcludeSemantics(
              child: Text(
                widget.glyph,
                style: TextStyle(
                  fontFamily: SenseFont.family,
                  fontSize: SensePopupShell.headerIconGlyph,
                  height: 1,
                  color: lit ? SenseColors.text : SenseColors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
