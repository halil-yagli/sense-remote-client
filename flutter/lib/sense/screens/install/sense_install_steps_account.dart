// Sense Remote: step 1 (Sense sign-in) of the Sense setup wizard (part of sense_install_wizard.dart,
// code review K3-6; behaviour unchanged).

part of 'sense_install_wizard.dart';

const String _googleLogo =
    '<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg">'
    '<path fill="#4285F4" d="M45 24.5c0-1.6-.1-3.1-.4-4.5H24v8.5h11.8c-.5 2.7-2 5-4.4 6.6v5.5h7.1c4.1-3.8 6.5-9.4 6.5-16.1z"/>'
    '<path fill="#34A853" d="M24 46c5.9 0 10.9-2 14.5-5.3l-7.1-5.5c-2 1.3-4.5 2.1-7.4 2.1-5.7 0-10.5-3.8-12.2-9H4.5v5.7C8.1 41.1 15.5 46 24 46z"/>'
    '<path fill="#FBBC05" d="M11.8 28.3c-.4-1.3-.7-2.7-.7-4.3s.3-3 .7-4.3V14H4.5C3 17 2.2 20.4 2.2 24s.8 7 2.3 10l7.3-5.7z"/>'
    '<path fill="#EA4335" d="M24 10.7c3.2 0 6.1 1.1 8.4 3.3l6.3-6.3C34.9 4.2 29.9 2 24 2 15.5 2 8.1 6.9 4.5 14l7.3 5.7c1.7-5.2 6.5-9 12.2-9z"/>'
    '</svg>';

extension _SenseInstallAccountStep on _SenseInstallWizardState {
  // ---- Step 1: Sense sign-in ----

  Widget _accountPage() {
    final s = _login;
    final content = <Widget>[
      _heading(_t('account-title-a'), _t('account-title-b'), boldFirst: true),
      _lead(_t('account-lead')),
    ];
    if (s.isDone) {
      content.add(_accountRow(s));
    } else if (s.isWaiting) {
      content.add(_pairingPanel(s));
    } else if (s.isRequesting) {
      // A still icon (no endless animation): the wizard waits at most a few seconds here.
      content.add(_statusLine(Icons.sync, _t('requesting'),
          key: const Key('sense-login-requesting')));
    } else {
      if (s.isFailed) {
        final text = s.error == 'timeout'
            ? _t('login-timeout')
            : [_t('login-failed'), if (s.detail.isNotEmpty) s.detail]
                .join('\n');
        content.add(Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _errorRow(text, key: const Key('sense-login-error')),
        ));
      }
      final label = !s.isFailed
          ? _t('google-sign-in')
          : s.error == 'timeout'
              ? _t('new-code')
              : _t('retry');
      content.add(Align(
        alignment: Alignment.centerLeft,
        child: _googleButton(label),
      ));
      content.add(Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(_t('sign-in-note'),
            style: const TextStyle(fontSize: 11, color: SenseTokens.dim)),
      ));
    }
    return _page(content, [
      Expanded(
        child: Text(_t('domain-hint'),
            style: const TextStyle(fontSize: 11, color: SenseTokens.dim)),
      ),
      const SizedBox(width: 12),
      _primaryButton(
          _t('next'),
          !s.isDone
              ? null
              : _installed
                  ? _registerAgain
                  : () => _go(SenseInstallStep.role),
          key: const Key('sense-next')),
    ]);
  }

  Widget _googleButton(String label) {
    return FilledButton.icon(
      key: const Key('sense-login'),
      onPressed: _startLogin,
      icon: SvgPicture.string(_googleLogo, width: 18, height: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: SenseTokens.white,
        foregroundColor: SenseTokens.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SenseTokens.radius)),
        textStyle: const TextStyle(
            fontFamily: SenseTokens.font,
            fontFamilyFallback: SenseTokens.fontFallback,
            fontWeight: FontWeight.w500,
            fontSize: 14),
      ),
    );
  }

  /// The code the panel's approval page also shows (3+3, like `ClientApprove.tsx`). The browser
  /// opens only when asked, so the code is on screen before the approval page.
  Widget _pairingPanel(SenseLoginStatus s) {
    final code = s.pairingCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (code.isNotEmpty)
          Container(
            key: const Key('sense-pairing'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SenseTokens.radiusCard),
              border: Border.all(color: SenseTokens.border),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  SenseTokens.accent1.withAlpha(90),
                  SenseTokens.accent2.withAlpha(45),
                ],
              ),
            ),
            child: Column(
              children: [
                Text(_t('pairing-label'),
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.2,
                        color: SenseTokens.muted)),
                const SizedBox(height: 6),
                Semantics(
                  container: true,
                  label: _t('pairing-spoken') + spokenSensePairingCode(code),
                  excludeSemantics: true,
                  child: Text(
                    formatSensePairingCode(code),
                    key: const Key('sense-pairing-code'),
                    style: const TextStyle(
                      fontSize: 44,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 5,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(_t('pairing-hint'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12, color: SenseTokens.soft)),
              ],
            ),
          ),
        const SizedBox(height: 16),
        // Wrap, not Row: long labels (or a larger system font) move to a second line instead
        // of overflowing.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _primaryButton(
                _t('open-browser'), () => widget.backend.openUrl(s.url),
                key: const Key('sense-open-browser')),
            _textButton(_t('copy-link'), _copyLink,
                key: const Key('sense-copy-link')),
            _textButton(_t('cancel'), _cancelLogin,
                key: const Key('sense-login-cancel')),
          ],
        ),
        const SizedBox(height: 12),
        _statusLine(Icons.schedule, _notice ?? _t('waiting')),
      ],
    );
  }

  Widget _accountRow(SenseLoginStatus s) {
    final source = s.displayName.isNotEmpty ? s.displayName : s.email.split('@').first;
    final initials = source
        .split(RegExp(r'[\s._-]+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part.characters.first.toUpperCase())
        .join();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: const Key('sense-account'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SenseTokens.radius),
            border: Border.all(color: SenseTokens.border),
            color: SenseTokens.field,
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    gradient: SenseTokens.gradient, shape: BoxShape.circle),
                child: Text(initials,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(s.email,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14)),
              ),
              const Icon(Icons.check, size: 14, color: SenseTokens.soft),
              const SizedBox(width: 4),
              Text(_t('verified'),
                  style:
                      const TextStyle(fontSize: 12, color: SenseTokens.soft)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        _textButton(_t('other-account'), _cancelLogin,
            key: const Key('sense-other-account')),
      ],
    );
  }
}
