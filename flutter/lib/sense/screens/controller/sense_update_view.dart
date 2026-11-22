// Sense Remote: "Yeni sürüm var" strip of the home screens and the macOS
// permission warning (update plan 2026-11-21, §6). One quiet line on top of
// the home screen; no full-screen window. [SenseUpdateStripView] is pure
// (data + callbacks); [SenseUpdateWatch] binds it to the app (GuiStatus every
// 5 s, `main_sense_update_install` on Güncelle).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../models/platform_model.dart';
import '../host_live/sense_cm_style.dart';
import '../host_live/sense_cm_widgets.dart';
import 'sense_update_model.dart';
import 'sense_update_strings.dart';

typedef _T = SenseCmTokens;

/// Local option keeping the "updated" notice closed across starts.
const kSenseUpdateSeenOption = 'sense-update-seen';

/// What the strip needs from the app; tests pass a fake.
abstract class SenseUpdateBackend {
  Future<String> status();
  Future<String> install(int version);
  String seenInstalled();
  Future<void> setSeenInstalled(String key);
  void openUrl(String url);
}

class SenseUpdateBridge implements SenseUpdateBackend {
  const SenseUpdateBridge();

  @override
  Future<String> status() => bind.mainSenseUpdateStatus();

  @override
  Future<String> install(int version) =>
      bind.mainSenseUpdateInstall(version: version);

  @override
  String seenInstalled() =>
      bind.mainGetLocalOption(key: kSenseUpdateSeenOption);

  @override
  Future<void> setSeenInstalled(String key) =>
      bind.mainSetLocalOption(key: kSenseUpdateSeenOption, value: key);

  @override
  void openUrl(String url) => launchUrlString(url);
}

/// Binds the strip: asks GuiStatus every 5 s and hands the strip (or null)
/// to [builder]. [onLayoutChanged] runs when the strip appears, goes or
/// changes its text (the Host window follows its content).
class SenseUpdateWatch extends StatefulWidget {
  const SenseUpdateWatch({
    super.key,
    required this.builder,
    this.onLayoutChanged,
    this.backend = const SenseUpdateBridge(),
    this.interval = const Duration(seconds: 5),
  });

  final Widget Function(BuildContext context, Widget? strip) builder;
  final VoidCallback? onLayoutChanged;
  final SenseUpdateBackend backend;
  final Duration interval;

  @override
  State<SenseUpdateWatch> createState() => _SenseUpdateWatchState();
}

class _SenseUpdateWatchState extends State<SenseUpdateWatch> {
  SenseUpdateStatus _status = SenseUpdateStatus.none;
  SenseUpdateUiState _ui = const SenseUpdateUiState();
  Timer? _timer;
  String? _lastText;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    String seen = '';
    try {
      seen = widget.backend.seenInstalled();
    } catch (_) {}
    _ui = SenseUpdateUiState(seenInstalled: seen.isEmpty ? null : seen);
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
            supported: _ui.supported, seenInstalled: _ui.seenInstalled);
      }
      _status = next;
    });
  }

  Future<void> _install() async {
    final version = senseUpdateRequestVersion(_status);
    if (version == null || _sending) return;
    if (_status.macPermissionWarning) {
      final go = await showSenseMacUpdateWarning(context);
      if (!go || !mounted) return;
    }
    _sending = true;
    String answer;
    try {
      answer = await widget.backend.install(version);
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
        ));
    await _poll();
  }

  void _close() {
    final key = senseInstalledNoticeKey(_status);
    if (key == null) return;
    setState(() => _ui = SenseUpdateUiState(
        supported: _ui.supported,
        requested: _ui.requested,
        answer: _ui.answer,
        seenInstalled: key));
    widget.backend.setSeenInstalled(key).catchError((_) {});
  }

  void _on(SenseUpdateAction action) {
    switch (action) {
      case SenseUpdateAction.update:
      case SenseUpdateAction.updateNow:
      case SenseUpdateAction.retry:
        _install();
        break;
      case SenseUpdateAction.notes:
        final url = _status.notesUrl;
        if (url != null) widget.backend.openUrl(url);
        break;
      case SenseUpdateAction.close:
        _close();
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
    return widget.builder(
        context,
        strip == null
            ? null
            : SenseUpdateStripView(
                strip: strip,
                progressPct: _status.state == SenseUpdateState.downloading
                    ? _status.progressPct
                    : null,
                onAction: _on));
  }
}

/// Pure strip: text on the left, buttons on the right; text above the
/// buttons when narrow (the Host window is 280 px wide).
class SenseUpdateStripView extends StatelessWidget {
  const SenseUpdateStripView(
      {super.key, required this.strip, required this.onAction, this.progressPct});

  final SenseUpdateStrip strip;
  final void Function(SenseUpdateAction action) onAction;
  final int? progressPct;

  static String label(SenseUpdateAction a) {
    switch (a) {
      case SenseUpdateAction.update:
        return senseUpdateText('update');
      case SenseUpdateAction.updateNow:
        return senseUpdateText('update_now');
      case SenseUpdateAction.retry:
        return senseUpdateText('retry');
      case SenseUpdateAction.notes:
        return senseUpdateText('notes');
      case SenseUpdateAction.close:
        return senseUpdateText('close');
    }
  }

  static bool _primary(SenseUpdateAction a) =>
      a == SenseUpdateAction.update ||
      a == SenseUpdateAction.updateNow ||
      a == SenseUpdateAction.retry;

  Widget _button(SenseUpdateAction a) {
    final key = Key('sense-update-${a.name}');
    if (_primary(a)) {
      return SizedBox(
          width: a == SenseUpdateAction.updateNow ? 128 : 104,
          child: SenseCmButton(
              key: key, label: label(a), primary: true, onTap: () => onAction(a)));
    }
    return SenseCmTextButton(
        key: key,
        label: label(a),
        strong: a == SenseUpdateAction.close,
        onTap: () => onAction(a));
  }

  @override
  Widget build(BuildContext context) {
    final dotColor = strip.problem ? _T.danger : _T.accent2;
    final text = Text(strip.text,
        key: const Key('sense-update-text'),
        style: _T.text(size: 12, color: _T.soft));
    final buttons = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [for (final a in strip.actions) _button(a)],
    );
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const Key('sense-update-strip'),
        decoration: BoxDecoration(
          color: _T.field,
          borderRadius: BorderRadius.circular(_T.radius),
          border: Border.all(color: _T.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
              child: LayoutBuilder(builder: (context, c) {
                final dot = Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(top: 5, right: 10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: strip.problem ? null : _T.gradient,
                    color: strip.problem ? dotColor : null,
                  ),
                );
                final narrow = c.maxWidth < 460;
                if (narrow || strip.actions.isEmpty) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      dot,
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            text,
                            if (strip.actions.isNotEmpty)
                              Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: buttons),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Padding(padding: const EdgeInsets.only(bottom: 4), child: dot),
                    Expanded(child: text),
                    const SizedBox(width: 12),
                    buttons,
                  ],
                );
              }),
            ),
            if (progressPct != null)
              LinearProgressIndicator(
                key: const Key('sense-update-progress'),
                value: progressPct! / 100,
                minHeight: 2,
                backgroundColor: _T.line,
                valueColor: const AlwaysStoppedAnimation(_T.soft),
              ),
          ],
        ),
      ),
    );
  }
}

/// macOS Host (§6, §7): permissions may be asked again after the update.
Future<bool> showSenseMacUpdateWarning(BuildContext context) async {
  final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => SenseMacUpdateWarningDialog(
          onAnswer: (v) => Navigator.of(ctx).pop(v)));
  return go == true;
}

class SenseMacUpdateWarningDialog extends StatelessWidget {
  const SenseMacUpdateWarningDialog({super.key, required this.onAnswer});
  final void Function(bool go) onAnswer;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _T.black,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_T.radiusCard),
          side: const BorderSide(color: _T.border)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(senseUpdateText('mac_title'),
                  style: _T.text(size: 14, weight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(senseUpdateText('mac_body'),
                  key: const Key('sense-update-mac-body'),
                  style: _T.text(size: 12, color: _T.soft)),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SenseCmTextButton(
                      key: const Key('sense-update-mac-cancel'),
                      label: senseUpdateText('cancel'),
                      onTap: () => onAnswer(false)),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 104,
                    child: SenseCmButton(
                        key: const Key('sense-update-mac-go'),
                        label: senseUpdateText('update'),
                        primary: true,
                        onTap: () => onAnswer(true)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
