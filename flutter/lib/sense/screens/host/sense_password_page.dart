// Sense Remote: "Kalıcı şifre" page (permanent password plan 2026-11-21, §4,
// package U13). Locked by default; "Kilidi aç" verifies a Sense employee with
// the same pairing code + QR sign-in as the setup wizard; for 5 minutes the
// password can then be set or changed. The Settings › Güvenlik row opens the
// in-place body (password/password_about_row.dart, T7); this panel is kept for its tests.
//
// [SensePasswordPanel] is the view of a [SensePasswordController]; the
// controller talks to the app through [SensePasswordBackend], so tests drive
// every state with a fake.

import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../host_live/sense_cm_style.dart';
import '../host_live/sense_cm_widgets.dart';
import '../install/sense_install_strings.dart'
    show formatSensePairingCode, spokenSensePairingCode;
import 'sense_password_model.dart';
import 'sense_password_strings.dart';
import 'data/password.dart';

export 'data/password.dart';

typedef _T = SenseCmTokens;

String _t(String key, [Map<String, String> args = const {}]) =>
    sensePasswordText(key, args);

DateTime? _changed(SensePasswordStatus s) => s.changedAt == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(s.changedAt! * 1000);

/// View of the controller: one block per stage (§4 table).
class SensePasswordPanel extends StatelessWidget {
  const SensePasswordPanel({super.key, required this.controller, this.onClose});
  final SensePasswordController controller;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final c = controller;
    final body = <Widget>[];
    void text(String value, {Key? key, Color color = _T.soft}) =>
        body.add(Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(value, key: key, style: _T.text(size: 12, color: color)),
        ));
    switch (c.stage) {
      case SensePasswordStage.loading:
        text('…');
      case SensePasswordStage.unsupported:
        text(_t('unsupported'), key: const Key('sense-pw-unsupported'));
      case SensePasswordStage.controller:
        text(_t('controller'), key: const Key('sense-pw-controller'));
      case SensePasswordStage.locked:
        text(sensePasswordLockedText(c.status, _changed(c.status)),
            key: const Key('sense-pw-text'));
      case SensePasswordStage.expired:
        text(_t('expired'), key: const Key('sense-pw-text'));
      case SensePasswordStage.verifying:
        body.addAll(_verifying(c));
      case SensePasswordStage.unlocked:
        body.addAll(_unlocked(c));
      case SensePasswordStage.done:
        text(_t('done'), key: const Key('sense-pw-text'));
    }
    if (c.message != null) {
      body.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(c.message!,
            key: const Key('sense-pw-message'),
            style: _T.text(size: 12, weight: FontWeight.w500)),
      ));
    }
    final actions = sensePasswordActions(c.stage, c.status,
        hasUrl: sensePasswordSafeUrl(c.login.url) != null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Icon(Icons.lock_outline, size: 16, color: _T.soft),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_t('title'),
                style: _T.text(size: 15, weight: FontWeight.w600)),
          ),
          if (onClose != null)
            SenseCmTextButton(
                key: const Key('sense-pw-close'),
                label: senseCmText('close'),
                onTap: onClose!),
        ]),
        const SizedBox(height: 14),
        ...body,
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < actions.length; i++)
                _button(actions[i], primary: i == 0),
            ],
          ),
        ],
        if (c.stage == SensePasswordStage.verifying &&
            !c.status.browserFirst &&
            actions.contains(SensePasswordAction.openBrowser))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_t('open_here_note'),
                style: _T.text(size: 11, color: _T.muted)),
          ),
      ],
    );
  }

  Widget _button(SensePasswordAction a, {required bool primary}) {
    final c = controller;
    String label;
    VoidCallback tap;
    switch (a) {
      case SensePasswordAction.unlock:
        label = _t('unlock');
        tap = c.unlockPressed;
      case SensePasswordAction.copyLink:
        label = _t('copy_link');
        tap = c.copyLink;
      case SensePasswordAction.openBrowser:
        label = c.status.browserFirst ? _t('open_browser') : _t('open_here');
        tap = c.openBrowser;
      case SensePasswordAction.cancel:
        label = _t('cancel');
        tap = c.cancelPressed;
      case SensePasswordAction.save:
        label = _t('save');
        tap = c.save;
      case SensePasswordAction.ok:
        label = _t('ok');
        tap = c.okPressed;
    }
    return SizedBox(
      width: primary ? 150 : null,
      child: primary
          ? SenseCmButton(
              key: Key('sense-pw-${a.name}'),
              label: label,
              primary: true,
              onTap: c.busy ? () {} : tap)
          : SenseCmTextButton(
              key: Key('sense-pw-${a.name}'), label: label, onTap: tap),
    );
  }

  List<Widget> _verifying(SensePasswordController c) {
    final code = c.login.pairingCode;
    final url = sensePasswordSafeUrl(c.login.url);
    if (!c.login.isWaiting || code.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(_t('requesting'),
              key: const Key('sense-pw-requesting'),
              style: _T.text(size: 12, color: _T.soft)),
        ),
      ];
    }
    final codeBox = Column(
      children: [
        Text(_t('pairing_label'),
            style: _T.text(size: 10, color: _T.muted).copyWith(letterSpacing: 1.2)),
        const SizedBox(height: 4),
        Semantics(
          container: true,
          label: _t('pairing_spoken') + spokenSensePairingCode(code),
          excludeSemantics: true,
          child: Text(formatSensePairingCode(code),
              key: const Key('sense-pw-code'),
              style: _T.text(size: 34, weight: FontWeight.w600).copyWith(
                  letterSpacing: 4,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ],
    );
    final qr = url == null
        ? null
        : Semantics(
            label: _t('qr_label'),
            image: true,
            child: Container(
              key: const Key('sense-pw-qr'),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                  color: _T.white, borderRadius: BorderRadius.circular(8)),
              child: QrImageView(
                data: url,
                version: QrVersions.auto,
                // Host: the QR is the first way (§2.2 B2), so it is larger.
                size: c.status.browserFirst ? 96 : 128,
                padding: EdgeInsets.zero,
                backgroundColor: _T.white,
                gapless: true,
              ),
            ),
          );
    return [
      Container(
        key: const Key('sense-pw-pairing'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_T.radiusCard),
          border: Border.all(color: _T.border),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_T.accent1.withAlpha(90), _T.accent2.withAlpha(45)],
          ),
        ),
        // The small Host window gets code and QR under each other.
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 330 || qr == null
              ? Column(children: [
                  codeBox,
                  if (qr != null) ...[const SizedBox(height: 10), qr],
                ])
              : Row(children: [Expanded(child: codeBox), qr]),
        ),
      ),
      const SizedBox(height: 10),
      Text(_t('verifying_hint'), style: _T.text(size: 12, color: _T.soft)),
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          const Icon(Icons.schedule, size: 13, color: _T.muted),
          const SizedBox(width: 6),
          Expanded(
              child: Text(_t('verifying_wait'),
                  style: _T.text(size: 11, color: _T.muted))),
        ]),
      ),
    ];
  }

  List<Widget> _unlocked(SensePasswordController c) => [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
              _t('unlocked', {
                'name': c.user.isEmpty ? '—' : c.user,
                'time': senseCountdown(c.remaining),
              }),
              key: const Key('sense-pw-text'),
              style: _T.text(size: 12, color: _T.soft)),
        ),
        _field(c.password, _t('new_password'), const Key('sense-pw-new'),
            autofocus: true),
        const SizedBox(height: 8),
        _field(c.repeat, _t('repeat_password'), const Key('sense-pw-repeat'),
            onSubmitted: (_) => c.save()),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(_t('rules'), style: _T.text(size: 11, color: _T.muted)),
        ),
      ];

  /// No "show", no selection, no copy (§2.2 B4).
  Widget _field(TextEditingController controller, String label, Key key,
          {bool autofocus = false, ValueChanged<String>? onSubmitted}) =>
      TextField(
        key: key,
        controller: controller,
        autofocus: autofocus,
        obscureText: true,
        enableInteractiveSelection: false,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        contextMenuBuilder: null,
        onSubmitted: onSubmitted,
        maxLength: 64,
        style: _T.text(size: 13),
        cursorColor: _T.white,
        decoration: InputDecoration(
          labelText: label,
          counterText: '',
          isDense: true,
          labelStyle: _T.text(size: 12, color: _T.muted),
          filled: true,
          fillColor: _T.field,
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_T.radius),
              borderSide: const BorderSide(color: _T.border)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(_T.radius),
              borderSide: const BorderSide(color: _T.soft)),
        ),
      );
}

/// Host home: one line with a lock; a tap opens About (where the page is).
class SensePasswordHostLine extends StatelessWidget {
  const SensePasswordHostLine(
      {super.key, required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: InkWell(
          key: const Key('sense-pw-host-line'),
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              const Icon(Icons.key_outlined, size: 14, color: _T.muted),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(text, style: _T.text(size: 11, color: _T.soft))),
              const Icon(Icons.chevron_right, size: 14, color: _T.muted),
            ]),
          ),
        ),
      );
}

/// Reads the status for the Host line (on start and every minute).
class SensePasswordHostWatch extends StatefulWidget {
  const SensePasswordHostWatch(
      {super.key,
      required this.builder,
      this.backend = const SensePasswordBridge(),
      this.onChanged});
  final Widget Function(BuildContext, String? line) builder;
  final SensePasswordBackend backend;

  /// The line appeared, went or changed (the Host window follows its content).
  final VoidCallback? onChanged;

  @override
  State<SensePasswordHostWatch> createState() => _SensePasswordHostWatchState();
}

class _SensePasswordHostWatchState extends State<SensePasswordHostWatch> {
  String? _line;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _load());
    _load();
  }

  Future<void> _load() async {
    final line =
        sensePasswordHostLine(SensePasswordStatus.parse(await widget.backend.status()));
    if (!mounted || line == _line) return;
    setState(() => _line = line);
    widget.onChanged?.call();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _line);
}
