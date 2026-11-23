// Sense Remote: small parts the "Bu bilgisayar" page shares (prototype `.ov`,
// `.qrbox`, `.code`, `.aupd`). Built only from tokens and library components.
import 'dart:ui' show FontFeature;

import 'package:flutter/widgets.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../sense.dart';
import '../host_format.dart';
import '../../../strings/host.dart';

// Prototype `.ov` padding 8×10; `.qrbox` gap 14, QR 96 px in an 8 px white frame.
const double _kBoxPadV = 8, _kBoxPadH = 10, _kQr = 96, _kQrPad = 8, _kQrGap = 14;

/// A framed box inside a category (`.ov`); [level] colours the frame (warn/hot).
class SenseHostBox extends StatelessWidget {
  const SenseHostBox({super.key, required this.child, this.level, this.surface = false});

  final Widget child;
  final SenseLevel? level;

  /// `.aupd`: surface background instead of black.
  final bool surface;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: _kBoxPadV, horizontal: _kBoxPadH),
        decoration: BoxDecoration(
          color: surface ? SenseColors.surface : SenseColors.bg,
          border: Border.all(
              color: level == null ? SenseColors.line : SenseStatusBox.borderColor(level!)),
          borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
        ),
        child: child,
      );
}

/// Bold line of a box (`.ov-h`), in the level colour.
class SenseHostBoxTitle extends StatelessWidget {
  const SenseHostBoxTitle(this.text, {super.key, this.level});
  final String text;
  final SenseLevel? level;

  @override
  Widget build(BuildContext context) => Text(text,
      style: SenseTextStyles.of(
          size: SenseFontSize.categoryTitleSmall,
          weight: SenseFontWeight.bold,
          color: level == null || level == SenseLevel.unknown
              ? SenseColors.text
              : SenseStatusBox.titleColor(level!)));
}

/// Grey small text (`.hmeta`).
class SenseHostMeta extends StatelessWidget {
  const SenseHostMeta(this.text, {super.key, this.color = SenseColors.textMuted});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: SenseTextStyles.of(size: SenseFontSize.hint, color: color));
}

/// Spinner + text on one line ("Onay bekleniyor · 2:54").
class SenseHostWaitLine extends StatelessWidget {
  const SenseHostWaitLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        const SenseSpinner(size: SenseFontSize.hint),
        const SizedBox(width: SenseUi.iconGap),
        Flexible(child: SenseHostMeta(text)),
      ]);
}

/// Buttons side by side (`display:flex;gap:6px`).
class SenseHostActions extends StatelessWidget {
  const SenseHostActions(this.children, {super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(spacing: SenseUi.iconGap, runSpacing: SenseUi.iconGap, children: children);
}

/// QR (when there is a safe link) + pairing code + wait line + buttons (`.qrbox`).
class SenseHostPairing extends StatelessWidget {
  const SenseHostPairing({
    super.key,
    required this.code,
    this.url,
    required this.waiting,
    this.actions = const [],
  });

  final String code;

  /// Already checked with `sensePasswordSafeUrl`; null = no QR.
  final String? url;
  final String waiting;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SenseHostMeta(SenseHostStrings.pairingCode),
        Text(senseHostPairingCode(code),
            key: const Key('sense-host-pairing-code'),
            style: SenseTextStyles.of(
                    size: SenseFontSize.codeSmall,
                    weight: SenseFontWeight.bold,
                    letterSpacingEm: SenseLetterSpacing.code)
                .copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: SenseUi.iconGap),
        SenseHostWaitLine(waiting),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: SenseSizes.buttonPadH - 3),
          SenseHostActions(actions),
        ],
      ],
    );
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      if (url != null) ...[
        Container(
          key: const Key('sense-host-qr'),
          padding: const EdgeInsets.all(_kQrPad),
          decoration: BoxDecoration(
              color: SenseColors.text, borderRadius: BorderRadius.circular(SenseRadii.button)),
          child: QrImageView(
            data: url!,
            version: QrVersions.auto,
            size: _kQr,
            padding: EdgeInsets.zero,
            backgroundColor: SenseColors.text,
            gapless: true,
          ),
        ),
        const SizedBox(width: _kQrGap),
      ],
      Flexible(child: right),
    ]);
  }
}
