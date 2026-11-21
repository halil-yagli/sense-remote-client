// Sense Remote: window frame, sidebar and shared building blocks of the Sense setup wizard (part of sense_install_wizard.dart,
// code review K3-6; behaviour unchanged).

part of 'sense_install_wizard.dart';

/// Sense Remote: visible keyboard focus on black (2 px white ring like the panel; the white
/// primary button gets the accent instead). Design review T3-13.
MaterialStateProperty<BorderSide?> _senseFocusSide(BorderSide? normal,
        {Color color = SenseTokens.white, double width = 2}) =>
    MaterialStateProperty.resolveWith((states) =>
        states.contains(MaterialState.focused)
            ? BorderSide(color: color, width: width)
            : normal);

extension _SenseInstallLayout on _SenseInstallWizardState {
  Widget _titleBar() {
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: SenseTokens.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => widget.onDragStart?.call(),
              child: Center(
                child: Text(_t('window-title'),
                    style: const TextStyle(
                        fontSize: 11, color: SenseTokens.muted)),
              ),
            ),
          ),
          // Sense Remote (Mac M3): macOS keeps its own window buttons (top left), so the
          // wizard draws no second close button there.
          if (!widget.mac)
          Tooltip(
            message: _t('close'),
            child: InkWell(
              key: const Key('sense-window-close'),
              onTap: _busy ? null : _close,
              child: const SizedBox(
                width: 46,
                height: 34,
                child: Icon(Icons.close, size: 16, color: SenseTokens.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar() {
    final steps = [
      SenseInstallStep.account,
      SenseInstallStep.role,
      SenseInstallStep.info,
      SenseInstallStep.summary,
      // Sense Remote (Mac M3): the permissions are a step of their own on macOS.
      if (widget.mac) SenseInstallStep.permissions,
    ];
    final labels = [
      'step-account',
      'step-role',
      'step-info',
      'step-summary',
      if (widget.mac) 'step-permissions',
    ];
    return Container(
      width: 230,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: SenseTokens.line)),
      ),
      child: ClipRect(
        child: Stack(
          children: [
            // Light accent at the bottom, like the prototype's blurred glow.
            Positioned(
              left: -60,
              right: -60,
              bottom: -120,
              height: 260,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        SenseTokens.accent1.withAlpha(190),
                        SenseTokens.accent2.withAlpha(70),
                        SenseTokens.black.withAlpha(0),
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: widget.icon ??
                            SvgPicture.asset('assets/icon.svg',
                                width: 24, height: 24),
                      ),
                      const SizedBox(width: 10),
                      // Sense Remote: dar kenar çubuğunda (185 px) taşmasın.
                      const Flexible(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                                text: 'Sense',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                            TextSpan(
                                text: ' Remote',
                                style: TextStyle(fontWeight: FontWeight.w200)),
                          ]),
                          style: TextStyle(fontSize: 16),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 34),
                  for (var i = 0; i < steps.length; i++)
                    _stepItem(i + 1, _t(labels[i]), steps[i]),
                  const Spacer(),
                  // Sense Remote: muted, not dim: this line sits on the light accent.
                  if (widget.version.trim().isNotEmpty)
                    Text('${_t('version')} ${widget.version.trim()}',
                        key: const Key('sense-version'),
                        style: const TextStyle(
                            fontSize: 11, color: SenseTokens.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepItem(int number, String label, SenseInstallStep step) {
    final current = step == _step;
    final done = step.index < _step.index;
    final Color textColor = current
        ? SenseTokens.white
        : done
            ? SenseTokens.soft
            : SenseTokens.muted;
    final BoxDecoration circle = current
        ? const BoxDecoration(color: SenseTokens.white, shape: BoxShape.circle)
        : done
            ? const BoxDecoration(
                gradient: SenseTokens.gradient, shape: BoxShape.circle)
            : BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF2F2F38)));
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: current ? SenseTokens.white.withAlpha(10) : null,
        borderRadius: BorderRadius.circular(SenseTokens.radius),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: circle,
            child: done
                ? const Icon(Icons.check, size: 13, color: SenseTokens.white)
                : Text('$number',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w300,
                        color:
                            current ? SenseTokens.black : SenseTokens.muted)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, color: textColor)),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final Widget page;
    switch (_step) {
      case SenseInstallStep.applications:
        page = _applicationsPage();
        break;
      case SenseInstallStep.permissions:
        page = _permissionsPage();
        break;
      case SenseInstallStep.account:
        page = _accountPage();
        break;
      case SenseInstallStep.role:
        page = _rolePage();
        break;
      case SenseInstallStep.info:
        page = _infoPage();
        break;
      case SenseInstallStep.summary:
        page = _summaryPage();
        break;
      case SenseInstallStep.register:
        page = _registerPage();
        break;
      case SenseInstallStep.done:
        page = _donePage();
        break;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 24, 34, 24),
      child: page,
    );
  }

  Widget _heading(String a, String b, {bool boldFirst = false}) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(
            text: a,
            style: TextStyle(
                fontWeight: boldFirst ? FontWeight.w700 : FontWeight.w200)),
        TextSpan(
            text: b,
            style: TextStyle(
                fontWeight: boldFirst ? FontWeight.w200 : FontWeight.w700)),
      ]),
      style: const TextStyle(fontSize: 24, letterSpacing: -0.4),
    );
  }

  Widget _lead(String text) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 20),
        child: Text(text,
            style: const TextStyle(fontSize: 13, color: SenseTokens.muted)),
      );

  /// Page layout: scrollable content with the buttons pinned at the bottom.
  Widget _page(List<Widget> content, List<Widget> footer) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: content,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: footer),
      ],
    );
  }

  Widget _primaryButton(String label, VoidCallback? onPressed, {Key? key}) {
    return FilledButton(
      key: key,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: SenseTokens.white,
        foregroundColor: SenseTokens.black,
        disabledBackgroundColor: SenseTokens.white.withAlpha(77),
        disabledForegroundColor: SenseTokens.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SenseTokens.radius)),
        textStyle: const TextStyle(
            fontFamily: SenseTokens.font,
            fontFamilyFallback: SenseTokens.fontFallback,
            fontWeight: FontWeight.w600,
            fontSize: 14),
      ).copyWith(
          side: _senseFocusSide(null, color: SenseTokens.accent2, width: 3)),
      child: Text(label),
    );
  }

  Widget _secondaryButton(String label, VoidCallback? onPressed, {Key? key}) {
    return OutlinedButton(
      key: key,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: SenseTokens.soft,
        side: const BorderSide(color: SenseTokens.border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SenseTokens.radius)),
        textStyle: const TextStyle(
            fontFamily: SenseTokens.font,
            fontFamilyFallback: SenseTokens.fontFallback,
            fontWeight: FontWeight.w400,
            fontSize: 14),
      ).copyWith(
          side: _senseFocusSide(const BorderSide(color: SenseTokens.border))),
      child: Text(label),
    );
  }

  Widget _textButton(String label, VoidCallback? onPressed, {Key? key}) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: SenseTokens.soft,
        textStyle: const TextStyle(
            fontFamily: SenseTokens.font,
            fontFamilyFallback: SenseTokens.fontFallback,
            fontWeight: FontWeight.w400,
            fontSize: 13),
      ).copyWith(side: _senseFocusSide(null)),
      child: Text(label),
    );
  }

  Widget _errorRow(String text, {Key? key}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 16, color: SenseTokens.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              key: key,
              style: const TextStyle(fontSize: 12, color: SenseTokens.error)),
        ),
      ],
    );
  }

  Widget _statusLine(IconData icon, String text, {Key? key}) {
    return Row(
      children: [
        Icon(icon, size: 14, color: SenseTokens.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              key: key,
              style: const TextStyle(fontSize: 12, color: SenseTokens.muted)),
        ),
      ],
    );
  }

  Widget _progress(String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(
            minHeight: 2,
            color: SenseTokens.white,
            backgroundColor: SenseTokens.border),
        const SizedBox(height: 8),
        Text(text,
            style: const TextStyle(fontSize: 12, color: SenseTokens.soft)),
      ],
    );
  }
}
