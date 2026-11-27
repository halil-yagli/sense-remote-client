// Sense Remote: "Sense hesabı" (YH K2, i01–i02) and "Bu bilgisayarın rolü" (YH K3, i03).

part of 'sense_install_wizard.dart';

/// Google's own "G" (brand colours of the sign-in button, not Sense colours).
const String _googleLogo =
    '<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg">'
    '<path fill="#EA4335" d="M24 9.5c3.5 0 6.6 1.2 9 3.5l6.7-6.7C35.6 2.4 30.2 0 24 0 14.6 0 6.6 5.4 2.6 13.2l7.8 6.1C12.3 13.6 17.6 9.5 24 9.5z"/>'
    '<path fill="#4285F4" d="M46.5 24.5c0-1.6-.1-3.1-.4-4.5H24v9h12.7c-.6 3-2.3 5.5-4.8 7.2l7.5 5.8c4.4-4 7.1-10 7.1-17.5z"/>'
    '<path fill="#FBBC05" d="M10.4 28.7c-.5-1.4-.8-3-.8-4.7s.3-3.3.8-4.7l-7.8-6.1C1 16.5 0 20.1 0 24s1 7.5 2.6 10.8l7.8-6.1z"/>'
    '<path fill="#34A853" d="M24 48c6.2 0 11.6-2 15.4-5.5l-7.5-5.8c-2.1 1.4-4.8 2.3-7.9 2.3-6.4 0-11.7-4.1-13.6-9.8l-7.8 6.1C6.6 42.6 14.6 48 24 48z"/>'
    '</svg>';

extension _SenseInstallAccountStep on _SenseInstallWizardState {
  (List<Widget>, List<Widget>) _accountPage() {
    final s = _login;
    final Widget box;
    if (s.isWaiting && s.pairingCode.isNotEmpty) {
      box = _codeBox(s);
    } else if (s.isDone && !senseCompanyEmail(s.email)) {
      box = _statusBox(SenseLevel.hot, _t('login-domain'), [
        _meta(_t('login-domain-hint')),
        _boxActions([
          _button(_t('other-account'), _startLogin,
              primary: true, key: const Key('sense-login-other')),
        ]),
      ], key: const Key('sense-login-domain'));
    } else if (s.isDone) {
      box = _signedInBox(s);
    } else if (s.isFailed && s.error == 'timeout') {
      box = _statusBox(SenseLevel.hot, _t('login-timeout'), [
        _meta(_t('login-timeout-hint')),
        _boxActions([
          _button(_t('new-code'), _startLogin, primary: true, key: const Key('sense-login-new-code')),
        ]),
      ], key: const Key('sense-login-timeout'));
    } else if (s.isFailed) {
      box = _statusBox(SenseLevel.hot, _t('login-failed'), [
        _meta(s.detail.isNotEmpty ? s.detail : _t('login-failed-hint')),
        _boxActions([
          _button(_t('retry'), _startLogin, primary: true, key: const Key('sense-login-retry')),
        ]),
      ], key: const Key('sense-login-failed'));
    } else {
      // Idle, or asking the panel for a code.
      final requesting = s.isRequesting || (s.isWaiting && s.pairingCode.isEmpty);
      box = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _googleButton(requesting ? null : _startLogin),
          const SizedBox(height: 8),
          if (requesting)
            Row(children: [
              const SenseSpinner(size: 11),
              const SizedBox(width: SenseUi.iconGap),
              _hint(_t('requesting'), key: const Key('sense-login-requesting')),
            ])
          else
            _hint(_t('sign-in-note')),
        ],
      );
    }
    return (
      [
        _header([(_t('account-title-a'), true), (_t('account-title-b'), false)], _t('account-lead')),
        box,
      ],
      [
        _footNote(_t('domain-note')),
        _button(_t('next'), _loginAccepted ? _accountNext : null,
            primary: true, key: const Key('sense-account-next')),
      ],
    );
  }

  Widget _googleButton(VoidCallback? onTap) => Opacity(
        opacity: onTap == null ? SenseUi.disabledOpacity : 1,
        child: SenseInteractive(
          key: const Key('sense-google'),
          onTap: onTap,
          semanticLabel: _t('google-sign-in'),
          builder: (_, s) => SenseFocusRing(
            visible: s.focused,
            radius: _L.boxRadius,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              decoration: BoxDecoration(
                color: s.hovered ? SenseColors.textSecondary : SenseColors.text,
                borderRadius: BorderRadius.circular(_L.boxRadius),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SvgPicture.string(_googleLogo, width: 18, height: 18),
                const SizedBox(width: _L.gap),
                Text(_t('google-sign-in'),
                    style: SenseTextStyles.of(
                        size: SenseFontSize.categoryTitle,
                        weight: SenseFontWeight.bold,
                        color: SenseColors.bg)),
              ]),
            ),
          ),
        ),
      );

  /// K2 "Kod": the 6-digit code the panel's approval page also shows (phishing defence G-2).
  Widget _codeBox(SenseLoginStatus s) => _box(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _meta(_t('pairing-label')),
            Semantics(
              container: true,
              label: _t('pairing-spoken') + spokenSensePairingCode(s.pairingCode),
              excludeSemantics: true,
              child: Text(
                formatSensePairingCode(s.pairingCode),
                key: const Key('sense-pairing-code'),
                style: SenseTextStyles.of(
                  size: SenseFontSize.code,
                  weight: SenseFontWeight.bold,
                  letterSpacingEm: SenseLetterSpacing.code,
                ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            _meta(_t('pairing-hint')),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(spacing: 6, runSpacing: 6, children: [
                _button(_t('open-browser'),
                    s.url.isEmpty ? null : () => widget.backend.openUrl(s.url),
                    primary: true, key: const Key('sense-login-open')),
                _button(_t(_copied ? 'link-copied' : 'copy-link'),
                    s.url.isEmpty ? null : _copyLink,
                    key: const Key('sense-login-copy')),
                _button(_t('cancel'), _cancelLogin, key: const Key('sense-login-cancel')),
              ]),
            ),
            const SizedBox(height: 8),
            Row(children: [
              const SenseSpinner(size: 11),
              const SizedBox(width: SenseUi.iconGap),
              Expanded(child: _meta(_t('waiting'), key: const Key('sense-login-waiting'))),
            ]),
          ],
        ),
        key: const Key('sense-login-code'),
      );

  /// K2 "Tamam": the verified company account.
  Widget _signedInBox(SenseLoginStatus s) {
    final name = s.displayName.trim().isNotEmpty ? s.displayName.trim() : s.email;
    final initials = name
        .split(RegExp(r'[\s.@_-]+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => senseUpperTr(w.characters.first))
        .join();
    // YH K2 "Tamam": green frame.
    return _box(
      Row(children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: SenseColors.raised,
            border: Border.all(color: SenseColors.line),
          ),
          child: Text(initials,
              style: SenseTextStyles.of(size: SenseFontSize.hint, weight: SenseFontWeight.bold)),
        ),
        const SizedBox(width: _L.gap),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.email,
                key: const Key('sense-login-email'),
                style: SenseTextStyles.of(
                    size: SenseFontSize.categoryTitleSmall,
                    weight: SenseFontWeight.bold,
                    color: SenseColors.ok)),
            _meta(_t('verified')),
          ]),
        ),
        if (!_busy)
          _button(_t('other-account'), _cancelLogin, key: const Key('sense-login-other')),
      ]),
      border: SenseColors.ok.withOpacity(0.5),
      key: const Key('sense-login-done'),
    );
  }

  // ---- Role (K3) ----

  (List<Widget>, List<Widget>) _rolePage() {
    final summary = _host && _controller
        ? 'role-sum-both'
        : _host
            ? 'role-sum-host'
            : _controller
                ? 'role-sum-controller'
                : 'role-none';
    return (
      [
        _header([(_t('role-title-a'), false), (_t('role-title-b'), true)], _t('role-lead')),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
                child: _roleCard(_t('host'), _t('host-desc'), _host,
                    () => _update(() => _host = !_host),
                    key: const Key('sense-role-host'))),
            const SizedBox(width: _L.gap),
            Expanded(
                child: _roleCard(_t('controller'), _t('controller-desc'), _controller,
                    () => _update(() => _controller = !_controller),
                    key: const Key('sense-role-controller'))),
          ]),
        ),
        _box(_meta(_t(summary), color: SenseColors.textSecondary, key: const Key('sense-role-summary'))),
      ],
      [
        _button(_t('back'), () => _go(SenseInstallStep.account), key: const Key('sense-back')),
        const Spacer(),
        _button(_t('next'), _host || _controller ? () => _go(SenseInstallStep.info) : null,
            primary: true, key: const Key('sense-role-next')),
      ],
    );
  }

  Widget _roleCard(String title, String description, bool selected, VoidCallback onTap,
          {Key? key}) =>
      SenseInteractive(
        key: key,
        onTap: onTap,
        toggled: selected,
        semanticLabel: title,
        builder: (_, s) => SenseFocusRing(
          visible: s.focused,
          radius: _L.cardRadius,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: selected ? SenseColors.bg : SenseColors.surface,
              border: Border.all(
                  color: selected
                      ? SenseColors.text
                      : s.hovered
                          ? SenseColors.lineStrong
                          : SenseColors.line),
              borderRadius: BorderRadius.circular(_L.cardRadius),
            ),
            child: Stack(children: [
              Padding(
                padding: const EdgeInsets.only(right: 24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      style: SenseTextStyles.of(
                          size: SenseFontSize.categoryTitle, weight: SenseFontWeight.bold)),
                  const SizedBox(height: 6),
                  Text(description,
                      style: SenseTextStyles.of(
                          size: SenseFontSize.hintLarge,
                          color: SenseColors.textMuted,
                          height: 1.5)),
                ]),
              ),
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: selected ? SenseColors.text : null,
                    border: Border.all(
                        color: selected ? SenseColors.text : SenseColors.lineStrong),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: selected
                      ? const Icon(Icons.check, size: SenseFontSize.bodySmall, color: SenseColors.bg)
                      : null,
                ),
              ),
            ]),
          ),
        ),
      );
}
