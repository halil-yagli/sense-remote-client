// Sense Remote: in-place second step (YH T7 "Yerinde ikinci adım"; prototype
// `.confirm2` + `.btn.sm` + `.btn.sm.end`). For work that cannot be undone the
// button is replaced, in the same place, by "emin misin?" + Vazgeç + a red
// confirm button. No separate confirm window, no "success" window (T7).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../strings/common.dart';
import '../tokens/sense_tokens.dart';

/// Text colour of the question (`.confirm2` #ffb3b9): soft red towards white.
Color get senseConfirmTextColor => Color.lerp(SenseColors.dangerTextSoft, SenseColors.text, 0.5)!;

/// Stateful two-step: shows [builder] (the first button) until it calls `ask`,
/// then the question with Vazgeç / [confirmLabel] in the same place.
class SenseInlineConfirm extends StatefulWidget {
  const SenseInlineConfirm({
    super.key,
    required this.builder,
    required this.question,
    required this.confirmLabel,
    required this.onConfirm,
    this.cancelLabel = SenseCommonStrings.cancel,
    this.onCancel,
  });

  /// First step; call `ask` to show the question.
  final Widget Function(BuildContext context, VoidCallback ask) builder;

  /// "Çıkış yapılsın mı? Açık bağlantı yok."
  final String question;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final String cancelLabel;
  final VoidCallback? onCancel;

  @override
  State<SenseInlineConfirm> createState() => _SenseInlineConfirmState();
}

class _SenseInlineConfirmState extends State<SenseInlineConfirm> {
  bool _asking = false;

  void _ask() => setState(() => _asking = true);

  void _cancel() {
    setState(() => _asking = false);
    widget.onCancel?.call();
  }

  void _confirm() {
    setState(() => _asking = false);
    widget.onConfirm();
  }

  @override
  Widget build(BuildContext context) {
    if (!_asking) return widget.builder(context, _ask);
    return SenseConfirmStrip(
      question: widget.question,
      confirmLabel: widget.confirmLabel,
      cancelLabel: widget.cancelLabel,
      onConfirm: _confirm,
      onCancel: _cancel,
    );
  }
}

/// The second step alone, for screens that keep the "asking" state themselves
/// (prototype: `PN.rmPc`). Esc cancels.
class SenseConfirmStrip extends StatelessWidget {
  const SenseConfirmStrip({
    super.key,
    required this.question,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.cancelLabel = SenseCommonStrings.cancel,
  });

  final String question;
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onCancel},
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            question,
            style: TextStyle(
              fontFamily: SenseFont.family,
              fontSize: SenseFontSize.hintLarge,
              color: senseConfirmTextColor,
            ),
          ),
          SenseSmallButton(
            key: const Key('sense-confirm-cancel'),
            label: cancelLabel,
            onPressed: onCancel,
            autofocus: true,
          ),
          SenseSmallButton(
            key: const Key('sense-confirm-ok'),
            label: confirmLabel,
            onPressed: onConfirm,
            danger: true,
          ),
        ],
      ),
    );
  }
}

/// Small button of the second step (`.btn.sm`, red with [danger]: `.btn.sm.end`).
/// Kept here so the step does not depend on the order the libraries land in;
/// screens use the A2a button for everything else.
class SenseSmallButton extends StatefulWidget {
  const SenseSmallButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool danger;
  final bool autofocus;

  @override
  State<SenseSmallButton> createState() => _SenseSmallButtonState();
}

class _SenseSmallButtonState extends State<SenseSmallButton> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.danger
        ? (_hover ? SenseColors.dangerHover : SenseColors.danger)
        : (_hover ? SenseColors.hover : SenseColors.bg);
    final border = _focus ? SenseColors.text : (widget.danger ? bg : SenseColors.line);
    return Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        autofocus: widget.autofocus,
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
            padding: const EdgeInsets.symmetric(
              horizontal: SenseSizes.buttonSmallPadH,
              vertical: SenseSizes.buttonSmallPadV,
            ),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: border),
              borderRadius: BorderRadius.circular(SenseRadii.button),
            ),
            child: ExcludeSemantics(
              child: Text(
                widget.label,
                style: const TextStyle(
                  fontFamily: SenseFont.family,
                  fontSize: SenseFontSize.hintLarge,
                  fontWeight: SenseFontWeight.medium,
                  color: SenseColors.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
