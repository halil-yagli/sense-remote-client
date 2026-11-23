// Sense Remote: drop-down list (YH T7 "Açılır liste", #43; prototype `.pick`,
// `.pickbtn`, `.dm`, `.it`, `.radio`). A button with a dark list under it and
// round radio marks. Never the operating system's or Material's menu.
// Closes on choice, on a tap outside and on Esc.
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../strings/common.dart';
import '../tokens/sense_tokens.dart';
import 'caret.dart';

class SenseSelectOption<T> {
  const SenseSelectOption({
    required this.value,
    required this.label,
    this.description,
    this.danger = false,
    this.enabled = true,
  });

  final T value;
  final String label;

  /// Small grey text on the right (`.it .s`).
  final String? description;

  /// Red option, e.g. "Kapalı" (`.offit`).
  final bool danger;
  final bool enabled;
}

class SenseSelect<T> extends StatefulWidget {
  const SenseSelect({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.label,
    this.placeholder = SenseCommonStrings.choose,
    this.header,
    this.enabled = true,
    this.menuMinWidth = 220,
    this.menuMaxHeight = 320,
  });

  final List<SenseSelectOption<T>> options;
  final T? value;
  final ValueChanged<T> onChanged;

  /// Grey text before the value inside the button ("Proje").
  final String? label;

  /// Shown when [value] matches no option.
  final String placeholder;

  /// Small caps heading at the top of the list (`.dm-h`).
  final String? header;
  final bool enabled;
  final double menuMinWidth;
  final double menuMaxHeight;

  /// Gap between the button and the list (`top: calc(100% + 6px)`).
  static const double menuGap = 6;
  static const double radioSize = 14;

  @override
  State<SenseSelect<T>> createState() => _SenseSelectState<T>();
}

class _SenseSelectState<T> extends State<SenseSelect<T>> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  final Object _tapGroup = Object();
  bool _hover = false;
  bool _focus = false;
  double _buttonWidth = 0;

  bool get _open => _portal.isShowing;

  void _toggle() {
    if (!widget.enabled) return;
    setState(() {
      if (_open) {
        _portal.hide();
      } else {
        _portal.show();
      }
    });
  }

  void _close() {
    if (_open) setState(_portal.hide);
  }

  void _choose(SenseSelectOption<T> o) {
    if (!o.enabled) return;
    _close();
    widget.onChanged(o.value);
  }

  SenseSelectOption<T>? get _selected {
    for (final o in widget.options) {
      if (o.value == widget.value) return o;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selected;
    final open = _open;
    final button = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: _hover && widget.enabled ? SenseColors.hover : SenseColors.bg,
        border: Border.all(color: open || _focus ? SenseColors.text : SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.category),
      ),
      child: Row(children: [
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: const TextStyle(
              fontFamily: SenseFont.family,
              fontSize: SenseFontSize.hint,
              color: SenseColors.textMuted,
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            sel?.label ?? widget.placeholder,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: SenseFont.family,
              fontSize: SenseFontSize.bodySmall,
              fontWeight: SenseFontWeight.bold,
              color: sel == null
                  ? SenseColors.textMuted
                  : (sel.danger ? SenseColors.dangerTextSoft : SenseColors.text),
            ),
          ),
        ),
        const SizedBox(width: 8),
        const SenseCaret(direction: SenseCaretDirection.down, small: true),
      ]),
    );

    return TapRegion(
      groupId: _tapGroup,
      onTapOutside: (_) => _close(),
      child: CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _menu,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.5,
            child: Semantics(
              button: true,
              expanded: open,
              enabled: widget.enabled,
              label: widget.label,
              value: sel?.label,
              child: FocusableActionDetector(
                enabled: widget.enabled,
                mouseCursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
                onShowHoverHighlight: (v) => setState(() => _hover = v),
                onShowFocusHighlight: (v) => setState(() => _focus = v),
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
                },
                actions: {
                  ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
                    _toggle();
                    return null;
                  }),
                  DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) {
                    _close();
                    return null;
                  }),
                },
                child: GestureDetector(
                  key: const Key('sense-select-button'),
                  onTap: _toggle,
                  child: LayoutBuilder(builder: (context, c) {
                    if (c.maxWidth.isFinite) _buttonWidth = c.maxWidth;
                    return button;
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final width = math.max(_buttonWidth, widget.menuMinWidth);
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, SenseSelect.menuGap),
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.topLeft,
        child: TapRegion(
          groupId: _tapGroup,
          child: CallbackShortcuts(
            bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
            child: FocusScope(
              autofocus: true,
              child: Container(
                key: const Key('sense-select-menu'),
                width: width,
                constraints: BoxConstraints(maxHeight: widget.menuMaxHeight),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: SenseColors.surface,
                  border: Border.all(color: SenseColors.line),
                  borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
                  boxShadow: [
                    BoxShadow(
                      color: SenseColors.bg.withOpacity(0.7),
                      offset: const Offset(0, 18),
                      blurRadius: 50,
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  primary: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.header != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                          child: Text(
                            senseUpperTr(widget.header!),
                            style: TextStyle(
                              fontFamily: SenseFont.family,
                              fontSize: SenseFontSize.caps,
                              color: SenseColors.textDim,
                              letterSpacing: senseLetterSpacing(SenseLetterSpacing.caps, SenseFontSize.caps),
                            ),
                          ),
                        ),
                      for (var i = 0; i < widget.options.length; i++)
                        _SelectItem<T>(
                          key: Key('sense-select-item-$i'),
                          option: widget.options[i],
                          selected: widget.options[i].value == widget.value,
                          autofocus: widget.options[i].value == widget.value,
                          onTap: () => _choose(widget.options[i]),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectItem<T> extends StatefulWidget {
  const _SelectItem({
    super.key,
    required this.option,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  final SenseSelectOption<T> option;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  State<_SelectItem<T>> createState() => _SelectItemState<T>();
}

class _SelectItemState<T> extends State<_SelectItem<T>> {
  bool _lit = false;

  @override
  Widget build(BuildContext context) {
    final o = widget.option;
    final accent = o.danger ? SenseColors.dangerTextSoft : SenseColors.text;
    return Semantics(
      button: true,
      selected: widget.selected,
      enabled: o.enabled,
      child: FocusableActionDetector(
        enabled: o.enabled,
        autofocus: widget.autofocus,
        mouseCursor: o.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowHoverHighlight: (v) => setState(() => _lit = v),
        onShowFocusHighlight: (v) => setState(() => _lit = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap();
            return null;
          }),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Opacity(
            opacity: o.enabled ? 1 : 0.5,
            child: Container(
              color: _lit ? SenseColors.hover : null,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                _Radio(selected: widget.selected, color: accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    o.label,
                    style: TextStyle(
                      fontFamily: SenseFont.family,
                      fontSize: SenseFontSize.body,
                      color: o.danger ? SenseColors.dangerTextSoft : SenseColors.text,
                    ),
                  ),
                ),
                if (o.description != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    o.description!,
                    style: const TextStyle(
                      fontFamily: SenseFont.family,
                      fontSize: SenseFontSize.hint,
                      color: SenseColors.textMuted,
                    ),
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.radio`: 14 px ring, 1.5 px; selected: ring and 2.5 px-inset dot in [color].
class _Radio extends StatelessWidget {
  const _Radio({required this.selected, required this.color});

  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: SenseSelect.radioSize,
      height: SenseSelect.radioSize,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? color : SenseColors.textDim, width: 1.5),
      ),
      child: selected
          ? DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: color))
          : null,
    );
  }
}

/// Turkish capitals for caps labels ("Görüntü kodeği" → "GÖRÜNTÜ KODEĞİ"):
/// Dart's toUpperCase turns i into I, not İ.
String senseUpperTr(String s) => s.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();
