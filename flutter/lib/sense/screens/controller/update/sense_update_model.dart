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

import '../../../strings/update.dart';

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
    this.supported = false,
    this.state = SenseUpdateState.idle,
    this.target,
    this.source,
    this.progressPct,
    this.error,
    this.blocked,
    this.notesUrl,
    this.notesSummary,
    this.checkedAt,
    this.macPermissionWarning = false,
    this.lastResult,
    this.attempts,
    this.retryAt,
  });

  static const none = SenseUpdateStatus();

  final int current;

  /// Sense Remote (U2 GuiStatus `supported`, missing = false): this build
  /// installs updates. When false the strip only informs (no install button).
  final bool supported;
  final SenseUpdateState state;
  final int? target;

  /// `panel`, `local` or `manual`.
  final String? source;
  final int? progressPct;
  final String? error;

  /// `session_active` or `night_window`.
  final String? blocked;
  final String? notesUrl;

  /// #166: the release's one-line "Neler yeni" (panel `notes_summary`, at most 120 characters,
  /// signed with the release); null when the panel sent none.
  final String? notesSummary;
  final int? checkedAt;
  final bool macPermissionWarning;
  final SenseUpdateLastResult? lastResult;

  /// #134: attempts made in this period (null = none).
  final int? attempts;

  /// #134: Unix seconds of the next automatic attempt after a failed one.
  final int? retryAt;

  factory SenseUpdateStatus.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return none;
      final pct = _int(v['progress_pct']);
      return SenseUpdateStatus(
        current: _int(v['current']) ?? 0,
        supported: v['supported'] == true,
        state: _state(v['state']),
        target: _int(v['target']),
        source: _str(v['source']),
        progressPct: pct == null ? null : pct.clamp(0, 100),
        error: _str(v['error']),
        blocked: _str(v['blocked']),
        notesUrl: _safeUrl(_str(v['notes_url'])),
        notesSummary: senseNotesSummary(_str(v['notes_summary'])),
        checkedAt: _int(v['checked_at']),
        macPermissionWarning: v['mac_permission_warning'] == true,
        lastResult: SenseUpdateLastResult.fromJson(v['last_result']),
        attempts: _int(v['attempts']),
        retryAt: _int(v['retry_at']),
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

  /// #134: an attempt failed and the job waits for its automatic retry
  /// (`available` with the job's source and the error kept).
  bool get retryPending => hasReadyRelease && source != null && error != null;
}

/// The summary as the strip shows it: one line, no control characters, at most 120 characters
/// (the panel's limit; the core refuses longer ones too). Null when nothing is left.
String? senseNotesSummary(String? raw) {
  if (raw == null) return null;
  final t = raw.replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ').replaceAll(RegExp(r' {2,}'), ' ').trim();
  if (t.isEmpty) return null;
  final runes = t.runes.toList();
  return runes.length <= 120 ? t : '${String.fromCharCodes(runes.take(119)).trimRight()}…';
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
enum SenseUpdateAction {
  update,
  updateNow,
  retry,
  notes,
  close,

  /// Stops a running download (only when the backend can).
  cancel,

  /// macOS second step: go on although permissions may be asked again.
  macGo,

  /// macOS second step: do not update now.
  macCancel,

  /// #134: "Şimdi kur" while a connection is open; asks in place first.
  installNow,

  /// #134: second step of [installNow]: close the connections and install.
  nowGo,

  /// #134: second step of [installNow]: do not close anything.
  nowCancel,
}

class SenseUpdateStrip {
  const SenseUpdateStrip(this.text,
      {this.actions = const [],
      this.busy = false,
      this.problem = false,
      this.done = false,
      this.asking = false,
      this.detail});
  final String text;

  /// Lighter text after [text] on the same line ("· Neler yeni: …", #166).
  final String? detail;
  final List<SenseUpdateAction> actions;

  /// Work in progress (downloading, verifying, installing).
  final bool busy;

  /// Failed or rolled back (red frame).
  final bool problem;

  /// The update finished (green frame).
  final bool done;

  /// The in-place second step is shown (macOS permission warning).
  final bool asking;
}

/// The UI's own memory next to GuiStatus.
class SenseUpdateUiState {
  const SenseUpdateUiState({
    this.supported = true,
    this.requested = false,
    this.answer,
    this.seenInstalled,
    this.askingMac = false,
    this.canCancel = false,
    this.askingNow = false,
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

  /// macOS: Güncelle was pressed; the strip asks in place before installing.
  final bool askingMac;

  /// The backend can stop a running download (Vazgeç).
  final bool canCancel;

  /// #134: "Şimdi kur" was pressed; the strip asks before closing connections.
  final bool askingNow;

  SenseUpdateUiState copyWith({
    bool? supported,
    bool? requested,
    String? answer,
    bool clearAnswer = false,
    String? seenInstalled,
    bool? askingMac,
    bool? canCancel,
    bool? askingNow,
  }) =>
      SenseUpdateUiState(
        supported: supported ?? this.supported,
        requested: requested ?? this.requested,
        answer: clearAnswer ? null : (answer ?? this.answer),
        seenInstalled: seenInstalled ?? this.seenInstalled,
        askingMac: askingMac ?? this.askingMac,
        canCancel: canCancel ?? this.canCancel,
        askingNow: askingNow ?? this.askingNow,
      );
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
  // Sense Remote: the build (GuiStatus `supported`) and the app's own memory
  // (an install answered `unsupported`) must both allow installing.
  List<SenseUpdateAction> act(List<SenseUpdateAction> a) =>
      ui.supported && s.supported
      ? a
      : a.where((x) => x == SenseUpdateAction.notes || x == SenseUpdateAction.close).toList();
  final notes = s.notesUrl != null ? [SenseUpdateAction.notes] : const <SenseUpdateAction>[];
  final sessionText = senseUpdateText('session_active', {'n': n});

  // macOS (YH C4): the warning is the strip's own second step, no window.
  if (ui.askingMac && senseUpdateRequestVersion(s) != null && _withButtons.contains(s.state)) {
    return SenseUpdateStrip(senseUpdateText('mac_body'),
        asking: true,
        actions: const [SenseUpdateAction.macCancel, SenseUpdateAction.macGo]);
  }

  // #134: "Şimdi kur" during a connection asks in place before anything closes.
  if (ui.askingNow && senseUpdateRequestVersion(s) != null && _withButtons.contains(s.state)) {
    return SenseUpdateStrip(senseUpdateText('now_body', {'n': n}),
        asking: true,
        actions: const [SenseUpdateAction.nowCancel, SenseUpdateAction.nowGo]);
  }

  // A refused install request is said where the button was, until the next
  // status change clears it. #134: the buttons stay, so "Tekrar dene" can be
  // pressed again after "servise ulaşılamadı" without waiting for a change.
  if (ui.answer != null && _withButtons.contains(s.state)) {
    if (s.state == SenseUpdateState.available && !s.hasReadyRelease) return null;
    final base = senseUpdateStrip(s, ui.copyWith(clearAnswer: true));
    return SenseUpdateStrip(ui.answer!, actions: base?.actions ?? act(notes));
  }

  switch (s.state) {
    case SenseUpdateState.available:
      if (!s.hasReadyRelease) return null;
      // #134: a failed attempt waits for its automatic retry: said, in red,
      // with "Tekrar dene" (before, the strip looked like nothing happened).
      if (s.retryPending) {
        return SenseUpdateStrip(
            senseUpdateText('retry_pending', {'reason': senseUpdateReason(s.error)}),
            problem: true,
            actions: act([SenseUpdateAction.retry, ...notes]));
      }
      if (ui.requested && s.blocked == 'session_active') {
        return SenseUpdateStrip(sessionText, actions: act([SenseUpdateAction.installNow]));
      }
      final summary = s.notesSummary;
      return SenseUpdateStrip(senseUpdateText('available', {'n': n}),
          detail: summary == null ? null : '${senseUpdateText('notes_prefix')}$summary',
          actions: act([SenseUpdateAction.update, ...notes]));
    case SenseUpdateState.scheduled:
    case SenseUpdateState.waitingIdle:
      if (s.target == null || s.target! <= s.current) return null;
      if (s.blocked == 'night_window') {
        return SenseUpdateStrip(senseUpdateText('scheduled_night', {'n': n}),
            actions: act([SenseUpdateAction.updateNow]));
      }
      // #134: the user's own job waits only for an open connection; "Şimdi
      // kur" closes it after asking.
      if (s.blocked == 'session_active' && s.source != 'panel') {
        return SenseUpdateStrip(sessionText, actions: act([SenseUpdateAction.installNow]));
      }
      // #134: a panel order can be hurried from here ("Şimdi güncelle" makes it
      // the user's own job, which waits only for an open connection).
      if (s.source == 'panel') {
        return SenseUpdateStrip(senseUpdateText('scheduled_panel', {'n': n, 'dat': dat}),
            actions: act([SenseUpdateAction.updateNow]));
      }
      return SenseUpdateStrip(senseUpdateText('scheduled_local', {'n': n}));
    case SenseUpdateState.downloading:
      if (s.target == null) return null;
      final p = s.progressPct;
      return SenseUpdateStrip(
          p == null
              ? senseUpdateText('downloading', {'n': n})
              : senseUpdateText('downloading_pct', {'n': n, 'p': '$p'}),
          busy: true,
          // A panel order's download is not stopped from the computer (D3e).
          actions: ui.canCancel && s.source != 'panel' ? const [SenseUpdateAction.cancel] : const []);
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
      done: true,
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

/// What the About box button does (YH C4).
enum SenseAboutUpdateAction { check, update }

/// The status box at the top of About: "Güncel" + Denetle, or "Yeni sürüm
/// hazır: Sürüm N" + Güncelle (prototype `aboutView2`).
class SenseAboutUpdateBox {
  const SenseAboutUpdateBox(
      {required this.title, required this.body, required this.action, this.ready = false, this.current = false});

  final String title;
  final String body;
  final SenseAboutUpdateAction action;

  /// A verified newer release waits (orange box).
  final bool ready;

  /// Checked and up to date (green title).
  final bool current;
}

/// Pure: the About box for this status. "Güncel" only after a real check
/// (no made-up state); Güncelle only when this build installs updates.
SenseAboutUpdateBox senseAboutUpdateBox(SenseUpdateStatus s, int nowSeconds, {required bool host}) {
  if (s.hasReadyRelease) {
    return SenseAboutUpdateBox(
      title: senseUpdateText('box_ready', {'n': '${s.target}'}),
      body: senseUpdateText(host ? 'box_ready_body_host' : 'box_ready_body_controller'),
      action: s.supported ? SenseAboutUpdateAction.update : SenseAboutUpdateAction.check,
      ready: true,
    );
  }
  final checked = s.checkedAt;
  final body = checked == null
      ? senseUpdateText('box_not_checked')
      : senseUpdateText('box_checked', {'ago': senseAgoText(checked, nowSeconds)});
  // #134: after a failed update About offers Güncelle too (it is taken at
  // once now); before, only Denetle was there.
  if (s.state == SenseUpdateState.failed && s.supported && senseUpdateRequestVersion(s) != null) {
    return SenseAboutUpdateBox(
        title: senseUpdateStrip(s)?.text ?? senseUpdateText('about_label'),
        body: body,
        action: SenseAboutUpdateAction.update);
  }
  final idle = s.state == SenseUpdateState.idle || s.state == SenseUpdateState.installed;
  if (checked != null && idle) {
    return SenseAboutUpdateBox(
        title: senseUpdateText('about_current'), body: body, action: SenseAboutUpdateAction.check, current: true);
  }
  return SenseAboutUpdateBox(
      title: senseUpdateStrip(s)?.text ?? senseUpdateText('about_label'),
      body: body,
      action: SenseAboutUpdateAction.check);
}
