// Sense Remote: in-place second step (YH T7 "Yerinde ikinci adım"). For work that cannot
// be undone the button is replaced, in the same place, by the question + Vazgeç + the
// confirm button. No separate confirm window, no "success" window (T7).
//
// Sürüm 12 (#158, plan §2.5 OT): one layout for every in-place question, the prototype's
// `.ask`: two lines — the question (`.ask-q`, 12.5/500 white) and an optional detail
// (`.ask-d`, 11 dim) — and under them the buttons right-aligned (`.ask-b`: Vazgeç + the
// red, or white for a reversible step, action). Nothing slides sideways: long questions
// wrap, the buttons wrap to the next line on a narrow row.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../strings/common.dart';
import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';

/// Text colour of the question before Sürüm 12 (`.confirm2` #ffb3b9). Kept for screens that
/// colour their own strip text with it (update strip).
Color get senseConfirmTextColor => Color.lerp(SenseColors.dangerTextSoft, SenseColors.text, 0.5)!;

/// Gap between the question block and the buttons (`.ask` gap 8 px).
const double kSenseAskGap = 8;

/// Gap between the question and its detail (`.ask-d` margin-top 2 px).
const double kSenseAskDetailGap = 2;

/// Background of a list row while it asks (`.it.asking`: red at 6 %).
Color get senseAskRowColor => SenseColors.hot.withOpacity(0.06);

/// Stateful two-step: shows [builder] (the first button) until it calls `ask`,
/// then the question with Vazgeç / [confirmLabel] in the same place.
class SenseInlineConfirm extends StatefulWidget {
  const SenseInlineConfirm({
    super.key,
    required this.builder,
    required this.question,
    required this.confirmLabel,
    required this.onConfirm,
    this.detail,
    this.confirmKind = SenseButtonKind.danger,
    this.cancelLabel = SenseCommonStrings.cancel,
    this.onCancel,
    this.askingBuilder,
  });

  /// First step; call `ask` to show the question.
  final Widget Function(BuildContext context, VoidCallback ask) builder;

  /// "Uzak bilgisayar yeniden başlatılsın mı?"
  final String question;

  /// Second line under the question ("Bağlantı kopar, açılınca yeniden bağlanır."), or null.
  final String? detail;
  final String confirmLabel;

  /// Red for work that cannot be undone (default); white ([SenseButtonKind.primary]) for a
  /// step the person can take back (prototype "Kilitle": `.btn.pri`).
  final SenseButtonKind confirmKind;
  final VoidCallback onConfirm;
  final String cancelLabel;
  final VoidCallback? onCancel;

  /// Wraps the question (e.g. the list row background `.it.asking`); null = as it is.
  final Widget Function(BuildContext context, Widget strip)? askingBuilder;

  @override
  State<SenseInlineConfirm> createState() => _SenseInlineConfirmState();
}

class _SenseInlineConfirmState extends State<SenseInlineConfirm> {
  bool _asking = false;

  void _ask() {
    setState(() => _asking = true);
    // The question may be taller than the button: keep it in view (prototype scrollIntoView).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_asking || Scrollable.maybeOf(context) == null) return;
      Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    });
  }

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
    final strip = SenseConfirmStrip(
      question: widget.question,
      detail: widget.detail,
      confirmLabel: widget.confirmLabel,
      confirmKind: widget.confirmKind,
      cancelLabel: widget.cancelLabel,
      onConfirm: _confirm,
      onCancel: _cancel,
    );
    return widget.askingBuilder?.call(context, strip) ?? strip;
  }
}

/// The second step alone, for screens that keep the "asking" state themselves
/// (prototype: `PN.rmPc`). Esc cancels; Vazgeç has the focus.
class SenseConfirmStrip extends StatelessWidget {
  const SenseConfirmStrip({
    super.key,
    required this.question,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.detail,
    this.confirmKind = SenseButtonKind.danger,
    this.cancelLabel = SenseCommonStrings.cancel,
  });

  final String question;
  final String? detail;
  final String confirmLabel;
  final SenseButtonKind confirmKind;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    final d = detail;
    final buttons = Wrap(
      alignment: WrapAlignment.end,
      spacing: kSenseAskGap,
      runSpacing: kSenseAskGap,
      children: [
        SenseButton(
          key: const Key('sense-confirm-cancel'),
          label: cancelLabel,
          size: SenseButtonSize.small,
          autofocus: true,
          onPressed: onCancel,
        ),
        SenseButton(
          key: const Key('sense-confirm-ok'),
          label: confirmLabel,
          size: SenseButtonSize.small,
          kind: confirmKind,
          onPressed: onConfirm,
        ),
      ],
    );
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onCancel},
      child: Semantics(
        container: true,
        // No LayoutBuilder: the strip also sits in cards sized by IntrinsicWidth. In a
        // bounded row the Align takes the full width (buttons on the right); unbounded it
        // is as wide as the buttons.
        child: Column(
          key: const Key('sense-confirm'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              question,
              key: const Key('sense-confirm-question'),
              softWrap: true,
              style: SenseTextStyles.of(size: SenseFontSize.body, weight: SenseFontWeight.medium),
            ),
            if (d != null) ...[
              const SizedBox(height: kSenseAskDetailGap),
              Text(
                d,
                key: const Key('sense-confirm-detail'),
                softWrap: true,
                style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textDim),
              ),
            ],
            const SizedBox(height: kSenseAskGap),
            Align(alignment: Alignment.centerRight, child: buttons),
          ],
        ),
      ),
    );
  }
}

/// Small button of the second step before Sürüm 12 (`.btn.sm`, red with [danger]). The
/// strip now uses the library button ([SenseButton]); this one stays for callers outside
/// the library that still draw it.
class SenseSmallButton extends StatelessWidget {
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
  Widget build(BuildContext context) => SenseButton(
        label: label,
        size: SenseButtonSize.small,
        kind: danger ? SenseButtonKind.danger : SenseButtonKind.normal,
        autofocus: autofocus,
        onPressed: onPressed,
      );
}
