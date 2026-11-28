// Sense Remote: "Sense hesabınla gir" (YH C1; prototype `loginRender`, image
// a05). Replaces the stock connection page of an unsigned Controller. Google
// sign-in in the browser + pairing code (two-step on the panel); connecting by
// ID stays possible without signing in (in place, no window).
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../sense.dart';
import '../../../strings/controller.dart';
import '../computers/widgets.dart';
import 'login_controller.dart';

// Prototype: column max 440, 60 from the top, gap 12; `.gbtn` 10×16, corner 10,
// logo 18, gap 10; `.lead` line height 1.55.
const double _kWidth = 440, _kTop = 60, _kGap = 12, _kBtnPadV = 10, _kBtnPadH = 16;
const double _kBtnRadius = 10, _kLogo = 18, _kLogoGap = 10, _kLead = 1.55;

class SenseLoginPage extends StatefulWidget {
  const SenseLoginPage({
    super.key,
    required this.controller,
    required this.onConnect,
    this.onConnectRelay,
    this.canConnect = true,
  });

  final SenseLoginController controller;
  final ValueChanged<String> onConnect;

  /// FU-A1: the same box as in the list, with "Aktarma sunucusu üzerinden bağlan".
  final ValueChanged<String>? onConnectRelay;
  final bool canConnect;

  @override
  State<SenseLoginPage> createState() => _SenseLoginPageState();
}

class _SenseLoginPageState extends State<SenseLoginPage> {
  bool _idOpen = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kWidth),
            child: Padding(
              padding: const EdgeInsets.only(top: _kTop),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: _children(),
              ),
            ),
          ),
        ),
      );

  List<Widget> _children() {
    final c = widget.controller;
    final waiting = c.stage == SenseLoginStage.waiting || c.stage == SenseLoginStage.starting;
    return [
      Text.rich(
        TextSpan(children: [
          TextSpan(
              text: SenseControllerStrings.loginTitleBold,
              style: SenseTextStyles.of(size: SenseFontSize.setupTitle, weight: SenseFontWeight.bold)),
          TextSpan(
              text: SenseControllerStrings.loginTitleThin,
              style: SenseTextStyles.of(size: SenseFontSize.setupTitle, weight: SenseFontWeight.thin)),
        ]),
      ),
      const SizedBox(height: _kGap - 4),
      Text(SenseControllerStrings.loginLead,
          style: SenseTextStyles.of(color: SenseColors.textMuted, height: _kLead)),
      const SizedBox(height: _kGap),
      if (waiting) _waiting(c) else _GoogleButton(onTap: c.start),
      if (c.stage == SenseLoginStage.failed) ...[
        const SizedBox(height: _kGap - 4),
        SenseMeta(
          c.error == SenseLoginError.noProvider
              ? SenseControllerStrings.loginNoProvider
              : SenseControllerStrings.loginFailed,
          color: SenseColors.dangerText,
        ),
      ],
      const SizedBox(height: _kGap),
      const SenseHint(SenseControllerStrings.loginSteps),
      const SizedBox(height: _kGap),
      SenseInteractive(
        key: const Key('sense-login-id'),
        onTap: () => setState(() => _idOpen = !_idOpen),
        builder: (_, s) => SenseFocusRing(
          visible: s.focused,
          child: Text(SenseControllerStrings.loginWithoutAccount,
              style: SenseTextStyles.of(
                size: SenseFontSize.hintSmall,
                color: s.hovered ? SenseColors.textSecondary : SenseColors.textMuted,
              ).copyWith(decoration: s.hovered ? TextDecoration.underline : TextDecoration.none)),
        ),
      ),
      if (_idOpen) ...[
        const SizedBox(height: _kGap),
        SenseConnectByIdBox(
            onConnect: widget.onConnect, onConnectRelay: widget.onConnectRelay, enabled: widget.canConnect),
      ],
    ];
  }

  Widget _waiting(SenseLoginController c) => SenseBox(
        key: const Key('sense-login-waiting'),
        children: [
          if (c.code.isNotEmpty) ...[
            const SenseMeta(SenseControllerStrings.loginPairingLabel),
            Text(SenseControllerStrings.pairingCode(c.code),
                key: const Key('sense-login-code'),
                style: SenseTextStyles.of(
                    size: SenseFontSize.codeSmall,
                    weight: SenseFontWeight.bold,
                    letterSpacingEm: SenseLetterSpacing.code)),
            const SenseMeta(SenseControllerStrings.loginPairingHint),
          ],
          const SizedBox(height: SenseUi.rowPadV - 1),
          Wrap(
            spacing: SenseUi.iconGap,
            runSpacing: SenseUi.iconGap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SenseButton(
                key: const Key('sense-login-cancel'),
                label: SenseCommonStrings.cancel,
                size: SenseButtonSize.small,
                onPressed: c.cancel,
              ),
              if (c.url.isNotEmpty)
                SenseButton(
                  key: const Key('sense-login-copy'),
                  label: SenseControllerStrings.loginCopyLink,
                  size: SenseButtonSize.small,
                  onPressed: () async {
                    await c.copyLink();
                    if (!mounted) return;
                    SenseToast.show(context, SenseControllerStrings.loginLinkCopied);
                  },
                ),
            ],
          ),
          const SizedBox(height: SenseUi.iconGap),
          Row(children: [
            const SenseSpinner(size: 11),
            const SizedBox(width: SenseUi.iconGap),
            Flexible(
              child: SenseMeta(c.url.isEmpty && c.code.isEmpty
                  ? SenseControllerStrings.loginOpening
                  : SenseControllerStrings.loginWaiting),
            ),
          ]),
        ],
      );
}

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: SenseInteractive(
          key: const Key('sense-login-google'),
          onTap: onTap,
          semanticLabel: SenseControllerStrings.loginGoogle,
          builder: (_, s) => SenseFocusRing(
            visible: s.focused,
            radius: _kBtnRadius,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: _kBtnPadV, horizontal: _kBtnPadH),
              decoration: BoxDecoration(
                color: s.hovered ? Color.alphaBlend(SenseColors.text.withOpacity(0.9), SenseColors.bg) : SenseColors.text,
                borderRadius: BorderRadius.circular(_kBtnRadius),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SvgPicture.asset('assets/auth-google.svg', width: _kLogo, height: _kLogo),
                const SizedBox(width: _kLogoGap),
                Text(SenseControllerStrings.loginGoogle,
                    style: SenseTextStyles.of(
                        size: SenseFontSize.categoryTitle, weight: SenseFontWeight.bold, color: SenseColors.bg)),
              ]),
            ),
          ),
        ),
      );
}
