// Sense Remote: the update strip on top of the home screens (update plan
// 2026-11-21, §6; YH C4; prototype `updStrip`, `.aupd`). One line above the
// content, no window: "Yeni sürüm hazır" + Güncelle → indiriliyor %N (+ Vazgeç,
// bottom progress line) → doğrulanıyor (imza + SHA-256) → açılış ekranı →
// "Güncellendi: Sürüm N" + Tamam. During a connection: "bağlantı bitince
// kurulacak". Failed: red + Tekrar dene. macOS: the permission warning is the
// strip's own second step (T7), not a separate window.
// [SenseUpdateStripView] is pure (data + callbacks); [SenseUpdateWatch] binds it
// to the app (GuiStatus every 5 s, `main_sense_update_install` on Güncelle).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../../models/platform_model.dart';
import '../../../sense.dart';
import '../../../strings/update.dart';
import 'sense_update_model.dart';

/// Prototype `.aupd .pbar`: 2 px line along the bottom edge.
const double _kProgressLine = 2;

/// Local option keeping the "updated" notice closed across starts.
const kSenseUpdateSeenOption = 'sense-update-seen';

/// What the strip needs from the app; tests pass a fake.
abstract class SenseUpdateBackend {
  Future<String> status();
  Future<String> install(int version);
  String seenInstalled();
  Future<void> setSeenInstalled(String key);
  void openUrl(String url);

  /// The backend can stop a running download (Vazgeç).
  bool get canCancel => false;

  /// Stops the running download.
  Future<void> cancel() async {}

  /// #134: "Kapat ve kur": install now, closing the open connections (the
  /// user confirmed in the strip). Same answers as [install].
  Future<String> installNow(int version) => install(version);

  /// #134: "Denetle": ask the panel at once; `""` when asked.
  Future<String> checkNow() async => '';
}

class SenseUpdateBridge extends SenseUpdateBackend {
  SenseUpdateBridge();

  @override
  Future<String> status() => bind.mainSenseUpdateStatus();

  @override
  Future<String> install(int version) => bind.mainSenseUpdateInstall(version: version);

  @override
  String seenInstalled() => bind.mainGetLocalOption(key: kSenseUpdateSeenOption);

  @override
  Future<void> setSeenInstalled(String key) =>
      bind.mainSetLocalOption(key: kSenseUpdateSeenOption, value: key);

  @override
  void openUrl(String url) => launchUrlString(url);

  // D3e (#68): `main_sense_update_cancel` stops the user's own download; on
  // macOS the agent hands it to the daemon that holds the download (D3f).
  @override
  bool get canCancel => Platform.isWindows || Platform.isMacOS;

  @override
  Future<void> cancel() async {
    await bind.mainSenseUpdateCancel();
  }

  @override
  Future<String> installNow(int version) => bind.mainSenseUpdateInstallNow(version: version);

  @override
  Future<String> checkNow() => bind.mainSenseUpdateCheck();
}

/// Binds the strip: asks GuiStatus every 5 s and hands the strip (or null)
/// to [builder]. [onLayoutChanged] runs when the strip appears, goes or
/// changes its text (the Host window follows its content). While the new
/// version installs, the splash covers the screen ("Sürüm N kuruluyor").
class SenseUpdateWatch extends StatefulWidget {
  SenseUpdateWatch({
    super.key,
    required this.builder,
    this.onLayoutChanged,
    this.onStatus,
    SenseUpdateBackend? backend,
    this.interval = const Duration(seconds: 5),
    this.showSplash = true,
  }) : backend = backend ?? SenseUpdateBridge();

  final Widget Function(BuildContext context, Widget? strip) builder;
  final VoidCallback? onLayoutChanged;

  /// Each new GuiStatus (FU-A3: the Controller menu's dot next to Hakkında follows it). Runs
  /// from the poll, never while building.
  final ValueChanged<SenseUpdateStatus>? onStatus;
  final SenseUpdateBackend backend;
  final Duration interval;

  /// Cover the screen with the splash while installing (off in small tests).
  final bool showSplash;

  @override
  State<SenseUpdateWatch> createState() => _SenseUpdateWatchState();
}

class _SenseUpdateWatchState extends State<SenseUpdateWatch> {
  SenseUpdateStatus _status = SenseUpdateStatus.none;
  SenseUpdateUiState _ui = const SenseUpdateUiState();
  Timer? _timer;
  String? _lastText;
  bool _sending = false;

  /// #134: the macOS step was opened by "Şimdi kur"; its "Yine de güncelle"
  /// goes on to the connection question instead of a plain request.
  bool _nowAfterMac = false;

  @override
  void initState() {
    super.initState();
    String seen = '';
    try {
      seen = widget.backend.seenInstalled();
    } catch (_) {}
    _ui = SenseUpdateUiState(
        seenInstalled: seen.isEmpty ? null : seen, canCancel: widget.backend.canCancel);
    _poll();
    _timer = Timer.periodic(widget.interval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    SenseUpdateStatus next;
    try {
      next = SenseUpdateStatus.parse(await widget.backend.status());
    } catch (_) {
      next = SenseUpdateStatus.none;
    }
    if (!mounted) return;
    setState(() {
      // A new state or target ends what the last button press said.
      if (next.state != _status.state || next.target != _status.target) {
        _ui = SenseUpdateUiState(
            supported: _ui.supported, seenInstalled: _ui.seenInstalled, canCancel: _ui.canCancel);
      }
      _status = next;
    });
    widget.onStatus?.call(next);
  }

  void _askOrInstall() {
    if (senseUpdateRequestVersion(_status) == null || _sending) return;
    if (_status.macPermissionWarning) {
      setState(() => _ui = _ui.copyWith(askingMac: true));
      return;
    }
    _install();
  }

  /// [now]: "Kapat ve kur" (#134), after the user confirmed in the strip.
  Future<void> _install({bool now = false}) async {
    final version = senseUpdateRequestVersion(_status);
    if (version == null || _sending) return;
    _sending = true;
    String answer;
    try {
      answer = now ? await widget.backend.installNow(version) : await widget.backend.install(version);
    } catch (_) {
      answer = 'ipc_failed';
    } finally {
      _sending = false;
    }
    if (!mounted) return;
    setState(() => _ui = SenseUpdateUiState(
          supported: _ui.supported && answer != 'unsupported',
          requested: answer.isEmpty,
          answer: senseInstallAnswerText(answer),
          seenInstalled: _ui.seenInstalled,
          canCancel: _ui.canCancel,
        ));
    await _poll();
  }

  void _close() {
    final key = senseInstalledNoticeKey(_status);
    if (key == null) return;
    setState(() => _ui = _ui.copyWith(seenInstalled: key));
    widget.backend.setSeenInstalled(key).catchError((_) {});
  }

  Future<void> _cancel() async {
    try {
      await widget.backend.cancel();
    } catch (_) {}
    await _poll();
  }

  void _on(SenseUpdateAction action) {
    switch (action) {
      case SenseUpdateAction.update:
      case SenseUpdateAction.updateNow:
      case SenseUpdateAction.retry:
        _askOrInstall();
        break;
      case SenseUpdateAction.macGo:
        // After "Şimdi kur" the next step is the connection question (#134).
        if (_nowAfterMac) {
          _nowAfterMac = false;
          setState(() => _ui = _ui.copyWith(askingMac: false, askingNow: true));
          break;
        }
        setState(() => _ui = _ui.copyWith(askingMac: false));
        _install();
        break;
      case SenseUpdateAction.macCancel:
        _nowAfterMac = false;
        setState(() => _ui = _ui.copyWith(askingMac: false));
        break;
      case SenseUpdateAction.installNow:
        // macOS asks about the permissions first, as for Güncelle.
        if (_status.macPermissionWarning) {
          _nowAfterMac = true;
          setState(() => _ui = _ui.copyWith(askingMac: true));
        } else {
          setState(() => _ui = _ui.copyWith(askingNow: true));
        }
        break;
      case SenseUpdateAction.nowGo:
        setState(() => _ui = _ui.copyWith(askingNow: false));
        _install(now: true);
        break;
      case SenseUpdateAction.nowCancel:
        setState(() => _ui = _ui.copyWith(askingNow: false));
        break;
      case SenseUpdateAction.notes:
        final url = _status.notesUrl;
        if (url != null) widget.backend.openUrl(url);
        break;
      case SenseUpdateAction.close:
        _close();
        break;
      case SenseUpdateAction.cancel:
        _cancel();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final strip = senseUpdateStrip(_status, _ui);
    if (strip?.text != _lastText) {
      _lastText = strip?.text;
      final cb = widget.onLayoutChanged;
      if (cb != null) WidgetsBinding.instance.addPostFrameCallback((_) => cb());
    }
    final child = widget.builder(
        context,
        strip == null
            ? null
            : SenseUpdateStripView(
                strip: strip,
                progressPct:
                    _status.state == SenseUpdateState.downloading ? _status.progressPct : null,
                onAction: _on));
    final installing = _status.state == SenseUpdateState.installing && _status.target != null;
    if (!widget.showSplash || !installing) return child;
    return Stack(children: [
      child,
      Positioned.fill(child: SenseSplash(updatingToVersion: _status.target)),
    ]);
  }
}

/// Pure strip (`.aupd`): text on the left, buttons on the right; text above
/// the buttons when narrow (the Host window is 280 px wide). Download progress
/// is a 2 px white line along the bottom edge.
class SenseUpdateStripView extends StatelessWidget {
  const SenseUpdateStripView({super.key, required this.strip, required this.onAction, this.progressPct});

  final SenseUpdateStrip strip;
  final void Function(SenseUpdateAction action) onAction;
  final int? progressPct;

  /// Under this width the buttons go under the text.
  static const double narrowWidth = 460;

  static String label(SenseUpdateAction a) {
    switch (a) {
      case SenseUpdateAction.update:
        return senseUpdateText('update');
      case SenseUpdateAction.updateNow:
        return senseUpdateText('update_now');
      case SenseUpdateAction.installNow:
        return senseUpdateText('install_now');
      case SenseUpdateAction.nowGo:
        return senseUpdateText('now_go');
      case SenseUpdateAction.nowCancel:
        return senseUpdateText('cancel');
      case SenseUpdateAction.retry:
        return senseUpdateText('retry');
      case SenseUpdateAction.notes:
        return senseUpdateText('notes');
      case SenseUpdateAction.close:
        return senseUpdateText('close');
      case SenseUpdateAction.cancel:
      case SenseUpdateAction.macCancel:
        return senseUpdateText('cancel');
      case SenseUpdateAction.macGo:
        return senseUpdateText('mac_go');
    }
  }

  static SenseButtonKind _kind(SenseUpdateAction a) {
    switch (a) {
      case SenseUpdateAction.update:
      case SenseUpdateAction.updateNow:
      case SenseUpdateAction.retry:
      case SenseUpdateAction.installNow:
        return SenseButtonKind.primary;
      case SenseUpdateAction.macGo:
      case SenseUpdateAction.nowGo:
        return SenseButtonKind.danger;
      case SenseUpdateAction.notes:
      case SenseUpdateAction.close:
      case SenseUpdateAction.cancel:
      case SenseUpdateAction.macCancel:
      case SenseUpdateAction.nowCancel:
        return SenseButtonKind.normal;
    }
  }

  Color _border() {
    if (strip.problem) return SenseColors.hot.withOpacity(0.55);
    if (strip.done) return SenseColors.ok.withOpacity(0.4);
    if (strip.asking) return SenseColors.warn.withOpacity(0.5);
    return SenseColors.line;
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = SenseTextStyles.of(
      size: SenseFontSize.bodySmall,
      weight: strip.done || strip.actions.contains(SenseUpdateAction.update)
          ? SenseFontWeight.bold
          : SenseFontWeight.regular,
      color: strip.asking ? senseConfirmTextColor : SenseColors.text,
    );
    // #166: "· Neler yeni: …" follows the bold line, regular and muted (prototype `updStrip`).
    final detail = strip.detail;
    final text = detail == null
        ? Text(strip.text, key: const Key('sense-update-text'), style: textStyle)
        : Text.rich(
            TextSpan(children: [
              TextSpan(text: strip.text, style: textStyle),
              TextSpan(
                  text: ' · $detail',
                  style: SenseTextStyles.of(
                      size: SenseFontSize.bodySmall,
                      weight: SenseFontWeight.regular,
                      color: SenseColors.textSecondary)),
            ]),
            key: const Key('sense-update-text'),
          );
    final lead = strip.busy && progressPct == null
        ? const Padding(
            padding: EdgeInsets.only(right: SenseUi.iconGap),
            child: SenseSpinner(size: SenseFontSize.hintLarge),
          )
        : null;
    final buttons = Wrap(
      spacing: SenseUi.iconGap,
      runSpacing: SenseUi.iconGap,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final a in strip.actions)
          SenseButton(
            key: Key('sense-update-${a.name}'),
            label: label(a),
            kind: _kind(a),
            size: SenseButtonSize.small,
            autofocus: a == SenseUpdateAction.macCancel || a == SenseUpdateAction.nowCancel,
            onPressed: () => onAction(a),
          ),
      ],
    );
    final content = LayoutBuilder(builder: (context, c) {
      final narrow = c.maxWidth < narrowWidth;
      final textRow = Row(children: [if (lead != null) lead, Expanded(child: text)]);
      if (narrow || strip.actions.isEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            textRow,
            if (strip.actions.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: SenseUi.iconGap), child: buttons),
          ],
        );
      }
      return Row(children: [
        Expanded(child: textRow),
        const SizedBox(width: SenseUi.rowGap),
        buttons,
      ]);
    });
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const Key('sense-update-strip'),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
          border: Border.all(color: _border()),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SenseUi.rowGap, vertical: SenseUi.rowPadV),
            child: content,
          ),
          if (progressPct != null)
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: FractionallySizedBox(
                  key: const Key('sense-update-progress'),
                  widthFactor: progressPct!.clamp(0, 100) / 100,
                  child: Container(height: _kProgressLine, color: SenseColors.text),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
