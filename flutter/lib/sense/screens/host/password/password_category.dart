// Sense Remote: "Kalıcı şifre" category (YH H2; prototype `pwBlock`). The page
// that used to open as a window now lives in the category: Değiştir → QR +
// pairing code + "Onay bekleniyor · 2:54" → new password + repeat + live rules
// → Kaydet. The password is never shown and never goes to the panel. The state
// machine is the kept [SensePasswordController] (sense_password_model.dart).
import 'package:flutter/material.dart';

import '../../../sense.dart';
import '../../../strings/host.dart';
import '../host_format.dart';
import '../sense_password_model.dart';
import '../sense_password_strings.dart';
import '../this_computer/widgets.dart';
import 'password_rules.dart';

/// The verification is open for 3 minutes (YH K2, same flow).
const int kSenseVerifySeconds = 180;

DateTime? _changed(SensePasswordStatus s) =>
    s.changedAt == null ? null : DateTime.fromMillisecondsSinceEpoch(s.changedAt! * 1000);

/// Summary on the right of the header ("ayarlı · 12 Kas 2026").
String senseHostPasswordSummary(SensePasswordStatus s) {
  if (!s.supported) return SenseHostStrings.passwordUnsupported;
  if (s.permSet == true) {
    final d = _changed(s);
    return SenseHostStrings.passwordSet(d == null ? null : senseHostDate(d));
  }
  if (s.permSet == false) return SenseHostStrings.passwordNone;
  return SenseHostStrings.passwordLocked;
}

/// Dot of the header: green when set, orange when not set.
SenseLevel? senseHostPasswordLevel(SensePasswordStatus s) {
  if (!s.supported) return null;
  if (s.permSet == true) return SenseLevel.ok;
  if (s.permSet == false) return SenseLevel.warn;
  return null;
}

class SensePasswordCategoryBody extends StatefulWidget {
  const SensePasswordCategoryBody({
    super.key,
    required this.controller,
    required this.deviceId,
    int Function()? now,
  }) : now = now ?? _unixNow;

  final SensePasswordController controller;

  /// For the "Kimliği içermiyor" line (spaces removed).
  final String deviceId;
  final int Function() now;

  static int _unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  State<SensePasswordCategoryBody> createState() => _SensePasswordCategoryBodyState();
}

class _SensePasswordCategoryBodyState extends State<SensePasswordCategoryBody> {
  SensePasswordController get c => widget.controller;
  SensePasswordStage? _last;
  int? _verifyStart;
  int _saved = 0;

  @override
  void initState() {
    super.initState();
    _last = c.stage;
    if (c.stage == SensePasswordStage.verifying) _verifyStart = widget.now();
    c.addListener(_stageChanged);
  }

  @override
  void didUpdateWidget(SensePasswordCategoryBody old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_stageChanged);
      widget.controller.addListener(_stageChanged);
    }
  }

  @override
  void dispose() {
    c.removeListener(_stageChanged);
    super.dispose();
  }

  void _stageChanged() {
    final s = c.stage;
    if (s == _last) return;
    _last = s;
    if (s == SensePasswordStage.verifying) _verifyStart = widget.now();
    if (s == SensePasswordStage.done) {
      // Prototype: back to the row with "Kaydedildi" and a toast; no extra step.
      setState(() => _saved++);
      SenseToast.show(context, SenseHostStrings.passwordChangedToast);
      c.okPressed();
    }
  }

  String get _id => widget.deviceId.replaceAll(' ', '');

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([c, c.password, c.repeat]),
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ..._body(),
            if (c.message != null)
              Padding(
                padding: const EdgeInsets.only(top: SenseUi.iconGap),
                child: Text(c.message!,
                    key: const Key('sense-pw-message'),
                    style: SenseTextStyles.of(
                        size: SenseFontSize.hint,
                        color: c.message == sensePasswordText('link_copied')
                            ? SenseColors.textMuted
                            : SenseColors.dangerTextSoft)),
              ),
          ],
        ),
      );

  List<Widget> _body() {
    switch (c.stage) {
      case SensePasswordStage.loading:
        return const [SenseHostWaitLine('…')];
      case SensePasswordStage.unsupported:
        return [SenseSettingRow(label: SenseHostStrings.password, description: sensePasswordText('unsupported'), last: true)];
      case SensePasswordStage.controller:
        return [SenseSettingRow(label: SenseHostStrings.password, description: sensePasswordText('controller'), last: true)];
      case SensePasswordStage.locked:
      case SensePasswordStage.expired:
      case SensePasswordStage.done:
        return [_row()];
      case SensePasswordStage.verifying:
        return _verifying();
      case SensePasswordStage.unlocked:
        return _unlocked();
    }
  }

  Widget _row() {
    final s = c.status;
    final none = s.permSet == false;
    final d = _changed(s);
    final text = c.stage == SensePasswordStage.expired
        ? sensePasswordText('expired')
        : none
            ? SenseHostStrings.passwordRowNone
            : (d == null ? SenseHostStrings.passwordRowSet : SenseHostStrings.passwordRowSetAt(senseHostDate(d)));
    return SenseSettingRow(
      key: const Key('sense-pw-row'),
      label: SenseHostStrings.password,
      description: text,
      savedTrigger: _saved,
      last: true,
      control: SenseButton(
        key: const Key('sense-pw-change'),
        label: none ? SenseHostStrings.set : SenseHostStrings.change,
        size: SenseButtonSize.small,
        kind: none ? SenseButtonKind.primary : SenseButtonKind.normal,
        onPressed: c.busy ? null : c.unlockPressed,
      ),
    );
  }

  Widget _title(String title, String hint) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: SenseTextStyles.of(weight: SenseFontWeight.medium)),
          SenseHostMeta(hint, color: SenseColors.textMuted),
        ],
      );

  List<Widget> _verifying() {
    final code = c.login.pairingCode;
    final out = <Widget>[
      _title(SenseHostStrings.passwordVerifyTitle, SenseHostStrings.passwordVerifyHint),
      const SizedBox(height: SenseUi.rowPadV - 1),
    ];
    final cancel = SenseButton(
        key: const Key('sense-pw-cancel'),
        label: SenseCommonStrings.cancel,
        size: SenseButtonSize.small,
        onPressed: c.cancelPressed);
    if (!c.login.isWaiting || code.isEmpty) {
      return [
        ...out,
        const SenseHostWaitLine(SenseHostStrings.preparing, key: Key('sense-pw-requesting')),
        const SizedBox(height: SenseUi.iconGap),
        SenseHostActions([cancel]),
      ];
    }
    final url = sensePasswordSafeUrl(c.login.url);
    final left = kSenseVerifySeconds - (widget.now() - (_verifyStart ?? widget.now()));
    return [
      ...out,
      SenseHostPairing(
        code: code,
        url: url,
        waiting: SenseHostStrings.waiting(senseHostCountdown(left)),
        actions: [
          if (url != null)
            SenseButton(
                key: const Key('sense-pw-copyLink'),
                label: sensePasswordText('copy_link'),
                size: SenseButtonSize.small,
                onPressed: c.copyLink),
          cancel,
        ],
      ),
    ];
  }

  List<Widget> _unlocked() {
    final ok = sensePasswordRulesMet(c.password.text, c.repeat.text, _id);
    return [
      _title(
          SenseHostStrings.passwordNewTitle,
          SenseHostStrings.passwordUnlocked(
              c.user.isEmpty ? '—' : c.user, senseHostCountdown(c.remaining))),
      const SizedBox(height: SenseUi.rowPadV - 1),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kFieldsMax),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _SensePasswordField(
              key: const Key('sense-pw-new'),
              controller: c.password,
              hint: sensePasswordText('new_password'),
              autofocus: true),
          const SizedBox(height: SenseUi.iconGap + 2),
          _SensePasswordField(
              key: const Key('sense-pw-repeat'),
              controller: c.repeat,
              hint: sensePasswordText('repeat_password'),
              onSubmitted: ok ? (_) => c.save() : null),
        ]),
      ),
      const SizedBox(height: SenseUi.rowPadV - 1),
      for (final l in sensePasswordRuleLines(c.password.text, c.repeat.text, _id))
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _RuleLine(met: l.met, text: l.text),
        ),
      const SizedBox(height: SenseUi.iconGap),
      SenseHostActions([
        SenseButton(
            key: const Key('sense-pw-save'),
            label: sensePasswordText('save'),
            size: SenseButtonSize.small,
            kind: SenseButtonKind.primary,
            onPressed: ok && !c.busy ? c.save : null),
        SenseButton(
            key: const Key('sense-pw-cancel'),
            label: SenseCommonStrings.cancel,
            size: SenseButtonSize.small,
            onPressed: c.cancelPressed),
      ]),
    ];
  }
}

// Prototype `.pwgrid` max 420; `.afield` height 32, corner 9, side padding 10.
const double _kFieldsMax = 420, _kFieldPadH = 10, _kFieldPadV = 8;

/// Password field: no "show", no selection, no copy (password plan §2.2 B4).
class _SensePasswordField extends StatelessWidget {
  const _SensePasswordField({
    super.key,
    required this.controller,
    required this.hint,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
        borderRadius: BorderRadius.circular(SenseRadii.category),
        borderSide: const BorderSide(color: SenseColors.line));
    return Material(
      type: MaterialType.transparency,
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        obscureText: true,
        enableInteractiveSelection: false,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.visiblePassword,
        contextMenuBuilder: null,
        onSubmitted: onSubmitted,
        maxLength: kSensePasswordMax,
        style: SenseTextStyles.bodySmall,
        cursorColor: SenseColors.text,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted),
          counterText: '',
          isDense: true,
          filled: true,
          fillColor: SenseColors.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: _kFieldPadH, vertical: _kFieldPadV),
          enabledBorder: border,
          border: border,
          focusedBorder: border.copyWith(borderSide: const BorderSide(color: SenseColors.textMuted)),
        ),
      ),
    );
  }
}

/// One live password rule: a drawn mark (nothing typed = dot, met = tick, not met = cross) + text.
class _RuleLine extends StatelessWidget {
  const _RuleLine({required this.met, required this.text});
  final bool? met;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = met == null
        ? SenseColors.textMuted
        : (met! ? SenseColors.ok : SenseColors.dangerTextSoft);
    final icon = met == null ? Icons.circle : (met! ? Icons.check : Icons.close);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 1, right: 6),
        child: Icon(icon,
            key: Key('sense-rule-mark-${met == null ? 'none' : (met! ? 'ok' : 'bad')}'),
            size: met == null ? SenseFontSize.capsSmall / 2 : SenseFontSize.hint,
            color: color),
      ),
      Expanded(child: Text(text, style: SenseTextStyles.of(size: SenseFontSize.hint, color: color))),
    ]);
  }
}
