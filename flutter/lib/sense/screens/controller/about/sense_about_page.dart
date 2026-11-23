// Sense Remote: About (YH C4; prototype `aboutView2`; image a04). Header
// "Sense Remote · Sürüm N"; status box "Güncel" + Denetle or "Yeni sürüm hazır"
// + Güncelle (macOS: in-place second step, T7); tiles Bu bilgisayar, Panel,
// Hesap, Kimlik (Controller), Parmak izi; "Açık kaynak lisansları" is a closable
// category (no window, AGPL notice + public source); © line.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../../common.dart' show gFFI;
import '../../../../common/formatter/id_formatter.dart' show formatID;
import '../../../../models/platform_model.dart';
import '../../../sense.dart';
import '../../../strings/about.dart';
import '../../../strings/update.dart';
import '../sense_home_strings.dart'
    show SenseHomeRole, senseHomeRoleFrom, senseRoleLabel, kSenseSourceUrl, kSenseLicenseUrl;
import '../settings/sense_settings_page.dart' show kSensePagePadding;
import '../settings/widgets.dart';
import '../update/sense_update_model.dart';
import '../update/sense_update_view.dart' show SenseUpdateBackend, SenseUpdateBridge;

/// What About reads; tests pass a fake.
abstract class SenseAboutBackend {
  int? version();
  SenseHomeRole role();

  /// Signed-in Sense account name; '' when none.
  String account();
  Future<String> myId();
  Future<String> fingerprint();

  /// Version of the open source base (licenses category).
  Future<String> baseVersion();
  void openUrl(String url);
  SenseUpdateBackend get update;
}

class SenseAboutBridge implements SenseAboutBackend {
  SenseAboutBridge();

  @override
  final SenseUpdateBackend update = SenseUpdateBridge();

  @override
  int? version() => senseAppVersion();

  @override
  SenseHomeRole role() => senseHomeRoleFrom(
      incomingOnly: bind.isIncomingOnly(),
      outgoingOnly: bind.isOutgoingOnly(),
      settingsDisabled: bind.isDisableSettings());

  @override
  String account() => gFFI.userModel.displayNameOrUserName;

  @override
  Future<String> myId() => bind.mainGetMyId();

  @override
  Future<String> fingerprint() => bind.mainGetFingerprint();

  @override
  Future<String> baseVersion() => bind.mainGetVersion();

  @override
  void openUrl(String url) => launchUrlString(url);
}

/// Pure: "3F2A · 91C0 · …" (first 8 characters; the full value stays in the core).
String senseFingerprintShort(String raw) {
  final s = raw.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
  if (s.isEmpty) return '';
  if (s.length <= 4) return s;
  final second = s.length >= 8 ? s.substring(4, 8) : s.substring(4);
  return s.length > 8 ? '${s.substring(0, 4)} · $second · …' : '${s.substring(0, 4)} · $second';
}

/// Pure: panel tile value.
String senseAboutPanelValue(SenseHomeRole role, String account) {
  if (account.trim().isNotEmpty) return SenseAboutStrings.panelSignedIn(account.trim());
  if (role == SenseHomeRole.host || role == SenseHomeRole.both) return SenseAboutStrings.panelManaged;
  return SenseAboutStrings.panelSignedOut;
}

/// Binds the page to the app.
class SenseAboutPage extends StatelessWidget {
  const SenseAboutPage({super.key});

  @override
  Widget build(BuildContext context) => SenseAboutView(backend: SenseAboutBridge());
}

class SenseAboutView extends StatefulWidget {
  const SenseAboutView({super.key, required this.backend, this.year, this.now, this.licensesOpen = false});

  final SenseAboutBackend backend;

  /// © year; null = this year.
  final int? year;

  /// Unix seconds for "Son denetim"; null = the clock.
  final int Function()? now;

  final bool licensesOpen;

  @override
  State<SenseAboutView> createState() => _SenseAboutViewState();
}

class _SenseAboutViewState extends State<SenseAboutView> {
  SenseUpdateStatus _status = SenseUpdateStatus.none;
  String _id = '';
  String _fingerprint = '';
  String _base = '';
  String? _answer;
  bool _checking = false;
  int _checkedTrigger = 0;
  late bool _licOpen = widget.licensesOpen;

  SenseAboutBackend get _b => widget.backend;

  int _now() => widget.now?.call() ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Future<String> safe(Future<String> Function() f) async {
      try {
        return await f();
      } catch (_) {
        return '';
      }
    }

    final id = await safe(_b.myId);
    final fp = await safe(_b.fingerprint);
    final base = await safe(_b.baseVersion);
    if (!mounted) return;
    setState(() {
      _id = id;
      _fingerprint = fp;
      _base = base;
    });
    await _poll();
  }

  Future<void> _poll() async {
    SenseUpdateStatus next;
    try {
      next = SenseUpdateStatus.parse(await _b.update.status());
    } catch (_) {
      next = SenseUpdateStatus.none;
    }
    if (mounted) setState(() => _status = next);
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    await _poll();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _answer = null;
      _checkedTrigger++;
    });
  }

  Future<void> _install() async {
    final version = senseUpdateRequestVersion(_status);
    if (version == null) return;
    String answer;
    try {
      answer = await _b.update.install(version);
    } catch (_) {
      answer = 'ipc_failed';
    }
    if (!mounted) return;
    setState(() => _answer = senseInstallAnswerText(answer));
    await _poll();
  }

  Widget _boxButton(SenseAboutUpdateBox box) {
    if (box.action == SenseAboutUpdateAction.check) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        _CheckedNote(trigger: box.current ? _checkedTrigger : 0),
        const SizedBox(width: SenseUi.iconGap),
        SenseButton(
          key: const Key('sense-about-check'),
          label: senseUpdateText('check'),
          size: SenseButtonSize.small,
          onPressed: _checking ? null : _check,
        ),
      ]);
    }
    final update = (VoidCallback ask) => SenseButton(
          key: const Key('sense-about-update'),
          label: senseUpdateText('update'),
          kind: SenseButtonKind.primary,
          size: SenseButtonSize.small,
          onPressed: ask,
        );
    if (!_status.macPermissionWarning) return update(_install);
    return SenseInlineConfirm(
      key: const Key('sense-about-mac-step'),
      builder: (_, ask) => update(ask),
      question: senseUpdateText('mac_short'),
      confirmLabel: senseUpdateText('mac_go'),
      onConfirm: _install,
    );
  }

  @override
  Widget build(BuildContext context) {
    final role = _b.role();
    final version = _b.version();
    final host = role == SenseHomeRole.host;
    final box = senseAboutUpdateBox(_status, _now(), host: host);
    final account = _b.account().trim();
    final controller = role == SenseHomeRole.controller || role == SenseHomeRole.both || role == SenseHomeRole.none;
    final fp = senseFingerprintShort(_fingerprint);
    final tiles = <Widget>[
      SenseStatTile(key: const Key('sense-about-role'), label: SenseAboutStrings.role, value: senseRoleLabel(role)),
      SenseStatTile(
          key: const Key('sense-about-panel'),
          label: SenseAboutStrings.panel,
          value: senseAboutPanelValue(role, account)),
      SenseStatTile(
          key: const Key('sense-about-account'),
          label: SenseAboutStrings.account,
          value: account.isEmpty ? SenseAboutStrings.accountNone : SenseAboutStrings.accountValue(account)),
      if (controller)
        SenseStatTile(
            key: const Key('sense-about-id'), label: SenseAboutStrings.id, value: _id.isEmpty ? null : formatID(_id)),
      SenseStatTile(key: const Key('sense-about-fingerprint'), label: SenseAboutStrings.fingerprint, value: fp.isEmpty ? null : fp),
    ];

    return ColoredBox(
      color: SenseColors.bg,
      child: SingleChildScrollView(
        padding: kSensePagePadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SensePageHead(
              title: SenseAboutStrings.titleBold,
              titleThin: SenseAboutStrings.titleThin,
              note: version == null ? null : SenseAboutStrings.version(version),
            ),
            const SizedBox(height: kSensePageGap),
            SenseOverviewBox(
              key: const Key('sense-about-update-box'),
              title: box.title,
              body: _answer ?? box.body,
              level: box.ready ? SenseLevel.warn : (box.current ? SenseLevel.ok : null),
              trailing: _boxButton(box),
            ),
            const SizedBox(height: kSensePageGap),
            SenseOverviewBox(child: SenseStatGrid(children: tiles)),
            const SizedBox(height: kSensePageGap),
            SenseCategory(
              key: const Key('sense-acc-licenses'),
              title: SenseAboutStrings.licenses,
              summary: SenseAboutStrings.licensesSummary,
              level: SenseLevel.ok,
              density: SenseAccordionDensity.page,
              open: _licOpen,
              onToggle: () => setState(() => _licOpen = !_licOpen),
              builder: (_) => _Licenses(base: _base, onOpenUrl: _b.openUrl),
            ),
            const SizedBox(height: kSensePageGap),
            Text(SenseAboutStrings.copyright(widget.year ?? DateTime.now().year),
                key: const Key('sense-about-copyright'),
                style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim)),
          ],
        ),
      ),
    );
  }
}

/// Green "Sense Remote güncel" after Denetle (fades like "Kaydedildi").
class _CheckedNote extends StatefulWidget {
  const _CheckedNote({required this.trigger});

  final int trigger;

  @override
  State<_CheckedNote> createState() => _CheckedNoteState();
}

class _CheckedNoteState extends State<_CheckedNote> {
  bool _on = false;
  Timer? _timer;

  @override
  void didUpdateWidget(_CheckedNote old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger && widget.trigger > 0) {
      _timer?.cancel();
      setState(() => _on = true);
      _timer = Timer(SenseMotion.savedFadeIn.duration + SenseMotion.savedHoldLong.duration, () {
        if (mounted) setState(() => _on = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: _on ? 1 : 0,
        duration: SenseMotion.savedFadeIn.duration,
        child: Text(senseUpdateText('checked_current'),
            key: const Key('sense-about-checked'),
            style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.ok)),
      );
}

class _Licenses extends StatelessWidget {
  const _Licenses({required this.base, required this.onOpenUrl});

  final String base;
  final void Function(String url) onOpenUrl;

  Widget _link(String label, String url, Key key) => SenseSettingRow(
        label: label,
        description: url,
        control: SenseButton(
          key: key,
          label: SenseAboutStrings.open,
          size: SenseButtonSize.small,
          onPressed: () => onOpenUrl(url),
        ),
      );

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(SenseAboutStrings.licensesBody,
              key: const Key('sense-about-licenses-body'),
              style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted)),
          _link(SenseAboutStrings.source, kSenseSourceUrl, const Key('sense-licenses-source')),
          _link(SenseAboutStrings.licenseText, kSenseLicenseUrl, const Key('sense-licenses-text')),
          if (base.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: SenseUi.iconGap),
              child: Text(SenseAboutStrings.base(base.trim()),
                  style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted)),
            ),
        ],
      );
}

/// Router entry (A2c `SenseEntry.about`, C4; the Host reaches only this).
Widget senseAboutScreen() => const SenseAboutPage();
