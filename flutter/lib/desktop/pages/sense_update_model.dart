// Sense Remote: what the update strip shows (update plan 2026-11-21, §6),
// from the GuiStatus JSON of `main_sense_update_status` (§3.7). Pure: no
// bridge here, so every state is covered by tests.
//
// Safety: the strip only says "Sürüm N hazır" for `state == available` with a
// target above the running version. The privileged side sets `available` only
// after the signed release verified (§3.3, §3.6); the unsigned heartbeat hint
// never reaches GuiStatus. When updating from the app is not supported (U0
// skeleton, `SUPPORTED = false`) the strip only informs and offers no button.

import 'dart:convert';

import 'sense_update_strings.dart';

/// `SenseUpdateState` (§3.5); [unknown] for a name this build does not know.
enum SenseUpdateState {
  idle,
  available,
  scheduled,
  waitingIdle,
  downloading,
  verifying,
  installing,
  installed,
  failed,
  rolledBack,
  unknown,
}

const _stateNames = {
  'idle': SenseUpdateState.idle,
  'available': SenseUpdateState.available,
  'scheduled': SenseUpdateState.scheduled,
  'waiting_idle': SenseUpdateState.waitingIdle,
  'downloading': SenseUpdateState.downloading,
  'verifying': SenseUpdateState.verifying,
  'installing': SenseUpdateState.installing,
  'installed': SenseUpdateState.installed,
  'failed': SenseUpdateState.failed,
  'rolled_back': SenseUpdateState.rolledBack,
};

SenseUpdateState _state(Object? v) =>
    _stateNames[v is String ? v : ''] ?? SenseUpdateState.unknown;

int? _int(Object? v) => v is int ? v : null;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

class SenseUpdateLastResult {
  const SenseUpdateLastResult(
      {required this.state, required this.from, required this.to, this.at = 0});
  final SenseUpdateState state;
  final int from;
  final int to;
  final int at;

  static SenseUpdateLastResult? fromJson(Object? v) {
    if (v is! Map) return null;
    final from = _int(v['from']), to = _int(v['to']);
    if (from == null || to == null) return null;
    return SenseUpdateLastResult(
        state: _state(v['state']), from: from, to: to, at: _int(v['at']) ?? 0);
  }
}

/// GuiStatus (§3.7). Anything unreadable becomes [SenseUpdateStatus.none].
class SenseUpdateStatus {
  const SenseUpdateStatus({
    this.current = 0,
    this.state = SenseUpdateState.idle,
    this.target,
    this.source,
    this.progressPct,
    this.error,
    this.blocked,
    this.notesUrl,
    this.checkedAt,
    this.macPermissionWarning = false,
    this.lastResult,
  });

  static const none = SenseUpdateStatus();

  final int current;
  final SenseUpdateState state;
  final int? target;

  /// `panel`, `local` or `manual`.
  final String? source;
  final int? progressPct;
  final String? error;

  /// `session_active` or `night_window`.
  final String? blocked;
  final String? notesUrl;
  final int? checkedAt;
  final bool macPermissionWarning;
  final SenseUpdateLastResult? lastResult;

  factory SenseUpdateStatus.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return none;
      final pct = _int(v['progress_pct']);
      return SenseUpdateStatus(
        current: _int(v['current']) ?? 0,
        state: _state(v['state']),
        target: _int(v['target']),
        source: _str(v['source']),
        progressPct: pct == null ? null : pct.clamp(0, 100),
        error: _str(v['error']),
        blocked: _str(v['blocked']),
        notesUrl: _safeUrl(_str(v['notes_url'])),
        checkedAt: _int(v['checked_at']),
        macPermissionWarning: v['mac_permission_warning'] == true,
        lastResult: SenseUpdateLastResult.fromJson(v['last_result']),
      );
    } catch (_) {
      return none;
    }
  }

  /// A verified newer release waits (the only "hazır" case).
  bool get hasReadyRelease =>
      state == SenseUpdateState.available &&
      target != null &&
      target! > current;
}

/// Release notes open in the browser; only https (or http for a local panel
/// in development builds) is followed.
String? _safeUrl(String? url) {
  if (url == null) return null;
  final u = Uri.tryParse(url);
  if (u == null || !(u.isScheme('https') || u.isScheme('http'))) return null;
  return u.host.isEmpty ? null : url;
}

/// What a strip button does.
enum SenseUpdateAction { update, updateNow, retry, notes, close }

class SenseUpdateStrip {
  const SenseUpdateStrip(this.text,
      {this.actions = const [], this.busy = false, this.problem = false});
  final String text;
  final List<SenseUpdateAction> actions;

  /// Work in progress (downloading, verifying, installing).
  final bool busy;

  /// Failed or rolled back.
  final bool problem;
}

/// The UI's own memory next to GuiStatus.
class SenseUpdateUiState {
  const SenseUpdateUiState({
    this.supported = true,
    this.requested = false,
    this.answer,
    this.seenInstalled,
  });

  /// False once the app learned updating from here is not possible (install
  /// answered `unsupported`); the strip then only informs.
  final bool supported;

  /// The user pressed Güncelle and the request was taken.
  final bool requested;

  /// Text of a non-empty install answer, shown until the next status change.
  final String? answer;

  /// [senseInstalledNoticeKey] of the "updated" notice the user closed.
  final String? seenInstalled;
}

const _withButtons = {
  SenseUpdateState.available,
  SenseUpdateState.scheduled,
  SenseUpdateState.waitingIdle,
  SenseUpdateState.failed,
  SenseUpdateState.rolledBack,
};

/// Pure: the strip for this status, or null when there is nothing to say.
SenseUpdateStrip? senseUpdateStrip(SenseUpdateStatus s,
    [SenseUpdateUiState ui = const SenseUpdateUiState()]) {
  final n = '${s.target ?? 0}';
  final dat = senseTurkishDative(s.target ?? 0);
  final cur = '${s.current}';
  List<SenseUpdateAction> act(List<SenseUpdateAction> a) => ui.supported
      ? a
      : a.where((x) => x == SenseUpdateAction.notes || x == SenseUpdateAction.close).toList();
  final notes = s.notesUrl != null ? [SenseUpdateAction.notes] : const <SenseUpdateAction>[];
  final sessionText = senseUpdateText('session_active');

  // A refused install request is said where the button was, until the next
  // status change clears it.
  if (ui.answer != null && _withButtons.contains(s.state)) {
    if (s.state == SenseUpdateState.available && !s.hasReadyRelease) return null;
    return SenseUpdateStrip(ui.answer!, actions: act(notes));
  }

  switch (s.state) {
    case SenseUpdateState.available:
      if (!s.hasReadyRelease) return null;
      if (ui.requested && s.blocked == 'session_active') {
        return SenseUpdateStrip(sessionText);
      }
      return SenseUpdateStrip(senseUpdateText('available', {'n': n}),
          actions: act([SenseUpdateAction.update, ...notes]));
    case SenseUpdateState.scheduled:
    case SenseUpdateState.waitingIdle:
      if (s.target == null || s.target! <= s.current) return null;
      if (s.blocked == 'night_window') {
        return SenseUpdateStrip(senseUpdateText('scheduled_night', {'n': n}),
            actions: act([SenseUpdateAction.updateNow]));
      }
      if (s.blocked == 'session_active' && s.source != 'panel') {
        return SenseUpdateStrip(sessionText);
      }
      return SenseUpdateStrip(s.source == 'panel'
          ? senseUpdateText('scheduled_panel', {'n': n, 'dat': dat})
          : senseUpdateText('scheduled_local', {'n': n}));
    case SenseUpdateState.downloading:
      if (s.target == null) return null;
      final p = s.progressPct;
      return SenseUpdateStrip(
          p == null
              ? senseUpdateText('downloading', {'n': n})
              : senseUpdateText('downloading_pct', {'n': n, 'p': '$p'}),
          busy: true);
    case SenseUpdateState.verifying:
      if (s.target == null) return null;
      return SenseUpdateStrip(senseUpdateText('verifying', {'n': n}), busy: true);
    case SenseUpdateState.installing:
      if (s.target == null) return null;
      return SenseUpdateStrip(senseUpdateText('installing', {'n': n}),
          busy: true);
    case SenseUpdateState.failed:
      return SenseUpdateStrip(
          senseUpdateText('failed',
              {'reason': senseUpdateReason(s.error), 'cur': cur}),
          problem: true,
          actions: act(s.target != null && s.target! > s.current
              ? [SenseUpdateAction.retry]
              : const []));
    case SenseUpdateState.rolledBack:
      final tried = s.target ?? s.lastResult?.to;
      if (tried == null) return null;
      return SenseUpdateStrip(
          senseUpdateText('rolled_back', {
            'n': '$tried',
            'cur': cur,
            'dat': senseTurkishDative(s.current),
          }),
          problem: true,
          actions: act(tried > s.current ? [SenseUpdateAction.retry] : const []));
    case SenseUpdateState.installed:
    case SenseUpdateState.idle:
    case SenseUpdateState.unknown:
      return _installedNotice(s, ui);
  }
}

/// "Sense Remote güncellendi" once, on the first start of the new version.
SenseUpdateStrip? _installedNotice(SenseUpdateStatus s, SenseUpdateUiState ui) {
  final key = senseInstalledNoticeKey(s);
  if (key == null || key == ui.seenInstalled) return null;
  return SenseUpdateStrip(
      senseUpdateText('installed', {'n': '${s.current}'}),
      actions: const [SenseUpdateAction.close]);
}

/// Identity of the "updated" notice ("<version>:<at>"), which the close
/// button remembers; null when there is no such notice.
String? senseInstalledNoticeKey(SenseUpdateStatus s) {
  if (s.current <= 0) return null;
  final r = s.lastResult;
  if (r != null && r.state == SenseUpdateState.installed && r.to == s.current) {
    return '${r.to}:${r.at}';
  }
  if (s.state == SenseUpdateState.installed) return '${s.current}:0';
  return null;
}

/// Version the Güncelle / Tekrar dene / Şimdi güncelle buttons ask for.
int? senseUpdateRequestVersion(SenseUpdateStatus s) {
  final v = s.target ?? s.lastResult?.to;
  return v != null && v > s.current ? v : null;
}

/// About line (§6): "Güncel" or "Sürüm N hazır", plus "Son denetim". Null
/// when nothing was checked yet (no made-up "Güncel").
String? senseAboutUpdateText(SenseUpdateStatus s, int nowSeconds) {
  final checked = s.checkedAt;
  final ago = checked == null
      ? null
      : senseUpdateText('about_checked', {'ago': senseAgoText(checked, nowSeconds)});
  String? head;
  if (s.hasReadyRelease) {
    head = senseUpdateText('about_ready', {'n': '${s.target}'});
  } else if (checked != null &&
      (s.state == SenseUpdateState.idle || s.state == SenseUpdateState.installed)) {
    head = senseUpdateText('about_current');
  }
  final parts = [if (head != null) head, if (ago != null) ago];
  return parts.isEmpty ? null : parts.join(' · ');
}
