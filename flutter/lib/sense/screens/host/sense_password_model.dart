// Sense Remote: state of the "Kalıcı şifre" page (permanent password plan
// 2026-11-21, §2.1, §3.7, §4; package U13). No bridge here: the native calls
// go through [SensePasswordBackend], so every state is covered by tests.
//
// Safety: this UI is untrusted (plan §2). It never sees a token, key or grant;
// the privileged process decides. The password lives only in the two text
// controllers and is cleared after every save, on cancel and when the
// unlock window ends.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../install/sense_install_model.dart' show SenseLoginStatus;
import 'sense_password_strings.dart';

/// `main_sense_password_status` (§3.7). Anything unreadable is
/// [SensePasswordStatus.none]: not supported, no button.
class SensePasswordStatus {
  const SensePasswordStatus({
    this.supported = false,
    this.role = 'none',
    this.permSet,
    this.changedAt,
    this.stage = 'locked',
    this.until,
    this.user,
  });

  static const none = SensePasswordStatus();

  final bool supported;

  /// `host`, `both`, `controller` or `none`.
  final String role;

  /// Null when unknown.
  final bool? permSet;
  final int? changedAt;

  /// `locked`, `verifying` or `unlocked`.
  final String stage;
  final int? until;
  final String? user;

  bool get isController => role == 'controller';

  /// Host + Controller: the team's own computer, the browser is the first way.
  bool get browserFirst => role == 'both' || role == 'controller';

  factory SensePasswordStatus.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return none;
      final perm = v['perm_set'];
      final role = v['role'];
      final stage = v['stage'];
      final user = v['user'];
      return SensePasswordStatus(
        supported: v['supported'] == true,
        role: role is String ? role : 'none',
        permSet: perm is bool ? perm : null,
        changedAt: v['changed_at'] is int ? v['changed_at'] as int : null,
        stage: stage is String ? stage : 'locked',
        until: v['until'] is int ? v['until'] as int : null,
        user: user is String && user.isNotEmpty ? user : null,
      );
    } catch (_) {
      return none;
    }
  }
}

/// `{"ok":true,…}` / `{"ok":false,"error":…}` of begin and unlock.
class SensePasswordAnswer {
  const SensePasswordAnswer(this.ok,
      {this.error = 'other', this.until, this.user});
  final bool ok;
  final String error;
  final int? until;
  final String? user;

  factory SensePasswordAnswer.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return const SensePasswordAnswer(false);
      final e = v['error'];
      final u = v['user'];
      return SensePasswordAnswer(v['ok'] == true,
          error: e is String && e.isNotEmpty ? e : 'other',
          until: v['until'] is int ? v['until'] as int : null,
          user: u is String && u.isNotEmpty ? u : null);
    } catch (_) {
      return const SensePasswordAnswer(false);
    }
  }
}

enum SensePasswordStage {
  loading,
  unsupported,
  controller,
  locked,
  verifying,
  unlocked,
  done,
  expired,
}

/// Pure: page stage when it opens.
SensePasswordStage sensePasswordInitialStage(
    SensePasswordStatus s, int nowSeconds) {
  if (!s.supported) return SensePasswordStage.unsupported;
  if (s.isController) return SensePasswordStage.controller;
  if (s.stage == 'unlocked' && s.until != null && s.until! > nowSeconds) {
    return SensePasswordStage.unlocked;
  }
  if (s.stage == 'verifying') return SensePasswordStage.verifying;
  return SensePasswordStage.locked;
}

/// Pure: About row value.
String sensePasswordSummary(SensePasswordStatus s, [DateTime? changed]) {
  if (!s.supported) return sensePasswordText('summary_unsupported');
  if (s.isController) return sensePasswordText('summary_controller');
  if (s.permSet == true) {
    return changed == null
        ? sensePasswordText('summary_set')
        : sensePasswordText('summary_set_at', {'date': senseShortDate(changed)});
  }
  if (s.permSet == false) return sensePasswordText('summary_none');
  return sensePasswordText('summary_unknown');
}

/// Pure: the one line of the Host home; null when it is not shown (not
/// supported yet, or a Controller).
String? sensePasswordHostLine(SensePasswordStatus s) {
  if (!s.supported || s.isController) return null;
  if (s.permSet == true) return sensePasswordText('host_set');
  if (s.permSet == false) return sensePasswordText('host_none');
  return sensePasswordText('host_unknown');
}

/// Pure: the locked text ("ayarlı · son değişiklik …" / "yok" / unknown).
String sensePasswordLockedText(SensePasswordStatus s, [DateTime? changed]) {
  if (s.permSet == true) {
    return changed == null
        ? '${sensePasswordText('locked_set_nodate')} ${sensePasswordText('locked_hint')}'
        : '${sensePasswordText('locked_set', {'date': senseShortDate(changed)})}. ${sensePasswordText('locked_hint')}';
  }
  if (s.permSet == false) return sensePasswordText('locked_none');
  return sensePasswordText('locked_unknown');
}

/// What a page button does.
enum SensePasswordAction { unlock, copyLink, openBrowser, cancel, save, ok }

/// Pure: buttons of a stage, the first is the primary one. Host: QR and copy
/// link first, the browser of this computer second (§2.2 B2); Host +
/// Controller: the browser first, like the setup wizard.
List<SensePasswordAction> sensePasswordActions(
    SensePasswordStage stage, SensePasswordStatus s,
    {bool hasUrl = true}) {
  switch (stage) {
    case SensePasswordStage.locked:
    case SensePasswordStage.expired:
      return const [SensePasswordAction.unlock];
    case SensePasswordStage.verifying:
      if (!hasUrl) return const [SensePasswordAction.cancel];
      return s.browserFirst
          ? const [
              SensePasswordAction.openBrowser,
              SensePasswordAction.copyLink,
              SensePasswordAction.cancel,
            ]
          : const [
              SensePasswordAction.copyLink,
              SensePasswordAction.openBrowser,
              SensePasswordAction.cancel,
            ];
    case SensePasswordStage.unlocked:
      return const [SensePasswordAction.save, SensePasswordAction.cancel];
    case SensePasswordStage.done:
      return const [SensePasswordAction.ok];
    case SensePasswordStage.loading:
    case SensePasswordStage.unsupported:
    case SensePasswordStage.controller:
      return const [];
  }
}

/// Answers of `main_sense_password_set` after which the grant is gone: the
/// page locks again and asks for a new verification. A rule error keeps the
/// window open (plan §2.1: a rule error does not burn the grant).
bool sensePasswordSetRelocks(String code) {
  final head = code.split(':').first;
  return const {
    'unsupported',
    'not_incoming',
    'no_pending',
    'grant_invalid',
    'nonce_mismatch',
  }.contains(head);
}

/// Only http(s) links with a host become a QR code or open in a browser.
String? sensePasswordSafeUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || !(u.isScheme('https') || u.isScheme('http'))) return null;
  return u.host.isEmpty ? null : url;
}

/// What the page needs from the app; tests pass a fake.
abstract class SensePasswordBackend {
  Future<String> status();
  Future<String> begin();
  Future<String> loginStatus();
  Future<String> unlock();
  Future<String> check(String password);
  Future<String> set(String password);
  Future<void> cancel();
  void openUrl(String url);
  Future<void> copy(String text);
}

int _unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// The page's state machine: locked → verifying → unlocked → done, back to
/// locked on cancel, and expired when the unlock window ends.
class SensePasswordController extends ChangeNotifier {
  SensePasswordController(this.backend,
      {this.interval = const Duration(seconds: 1), int Function()? now})
      : _now = now ?? _unixNow;

  final SensePasswordBackend backend;
  final Duration interval;
  final int Function() _now;

  /// The two fields; cleared after every save attempt, on cancel and expiry.
  final password = TextEditingController();
  final repeat = TextEditingController();

  SensePasswordStatus status = SensePasswordStatus.none;
  SensePasswordStage stage = SensePasswordStage.loading;
  SenseLoginStatus login = SenseLoginStatus.idle;
  int? until;
  String user = '';

  /// Error or notice text under the state text (already a UI text).
  String? message;
  bool busy = false;

  Timer? _timer;
  bool _ticking = false;
  bool _disposed = false;

  int get now => _now();

  /// Seconds until the page locks itself again.
  int get remaining => until == null ? 0 : until! - _now();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _clearFields() {
    password.clear();
    repeat.clear();
  }

  void _startTimer() {
    _timer ??= Timer.periodic(interval, (_) => tick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> load() async {
    status = SensePasswordStatus.parse(await backend.status());
    if (_disposed) return;
    stage = sensePasswordInitialStage(status, _now());
    if (stage == SensePasswordStage.unlocked) {
      until = status.until;
      user = status.user ?? '';
      _startTimer();
    } else if (stage == SensePasswordStage.verifying) {
      login = const SenseLoginStatus('requesting');
      _startTimer();
    }
    _notify();
  }

  Future<void> unlockPressed() async {
    if (busy) return;
    busy = true;
    message = null;
    _notify();
    final answer = SensePasswordAnswer.parse(await backend.begin());
    busy = false;
    if (_disposed) return;
    if (!answer.ok) {
      // not_incoming: the Controller text says it already.
      if (answer.error == 'not_incoming') {
        stage = SensePasswordStage.controller;
      } else {
        message = sensePasswordErrorText(answer.error);
      }
      _notify();
      return;
    }
    stage = SensePasswordStage.verifying;
    login = const SenseLoginStatus('requesting');
    _startTimer();
    _notify();
  }

  /// One step of the timer: polls the sign-in while verifying, runs the
  /// countdown while unlocked.
  @visibleForTesting
  Future<void> tick() async {
    if (_ticking || _disposed) return;
    _ticking = true;
    try {
      if (stage == SensePasswordStage.verifying) {
        final s = SenseLoginStatus.fromJson(await backend.loginStatus());
        if (_disposed || stage != SensePasswordStage.verifying) return;
        login = s;
        if (s.isDone) {
          await _finishUnlock();
        } else if (s.isFailed) {
          _stopTimer();
          stage = SensePasswordStage.locked;
          login = SenseLoginStatus.idle;
          message = sensePasswordErrorText(
              s.error == 'timeout' ? 'login_timeout' : 'login_failed');
          await backend.cancel();
        }
      } else if (stage == SensePasswordStage.unlocked) {
        if (remaining <= 0) await _expire();
      } else {
        _stopTimer();
      }
    } finally {
      _ticking = false;
      _notify();
    }
  }

  Future<void> _finishUnlock() async {
    final answer = SensePasswordAnswer.parse(await backend.unlock());
    if (_disposed) return;
    login = SenseLoginStatus.idle;
    if (answer.ok && answer.until != null && answer.until! > _now()) {
      stage = SensePasswordStage.unlocked;
      until = answer.until;
      user = answer.user ?? '';
      message = null;
    } else {
      _stopTimer();
      stage = SensePasswordStage.locked;
      message = sensePasswordErrorText(answer.ok ? 'other' : answer.error);
    }
  }

  Future<void> _expire() async {
    _stopTimer();
    _clearFields();
    stage = SensePasswordStage.expired;
    until = null;
    user = '';
    message = null;
    await backend.cancel();
  }

  Future<void> save() async {
    if (busy || stage != SensePasswordStage.unlocked) return;
    message = null;
    final pw = password.text;
    if (pw != repeat.text) {
      _clearFields();
      message = sensePasswordErrorText('mismatch');
      _notify();
      return;
    }
    busy = true;
    _notify();
    try {
      final hint = await backend.check(pw);
      if (_disposed) return;
      if (hint.isNotEmpty) {
        message = sensePasswordRuleText(hint);
        return;
      }
      final answer = await backend.set(pw);
      if (_disposed) return;
      if (answer.isEmpty) {
        _stopTimer();
        stage = SensePasswordStage.done;
        until = null;
      } else {
        message = sensePasswordErrorText(answer);
        if (sensePasswordSetRelocks(answer)) {
          _stopTimer();
          stage = SensePasswordStage.locked;
          until = null;
          user = '';
        }
      }
    } finally {
      if (!_disposed) _clearFields();
      busy = false;
      _notify();
    }
  }

  /// Vazgeç: the sign-in is forgotten, the grant dropped, back to locked.
  Future<void> cancelPressed() async {
    _stopTimer();
    _clearFields();
    login = SenseLoginStatus.idle;
    until = null;
    user = '';
    message = null;
    await backend.cancel();
    await _reload();
  }

  /// Tamam after a change: the page locks and shows the new status.
  Future<void> okPressed() => _reload();

  Future<void> _reload() async {
    status = SensePasswordStatus.parse(await backend.status());
    if (_disposed) return;
    final s = sensePasswordInitialStage(status, _now());
    stage = s == SensePasswordStage.unlocked || s == SensePasswordStage.verifying
        ? SensePasswordStage.locked
        : s;
    _notify();
  }

  Future<void> copyLink() async {
    final url = sensePasswordSafeUrl(login.url);
    if (url == null) return;
    await backend.copy(url);
    message = sensePasswordText('link_copied');
    _notify();
  }

  void openBrowser() {
    final url = sensePasswordSafeUrl(login.url);
    if (url != null) backend.openUrl(url);
  }

  @override
  void dispose() {
    final open = stage == SensePasswordStage.verifying ||
        stage == SensePasswordStage.unlocked;
    _disposed = true;
    _stopTimer();
    _clearFields();
    password.dispose();
    repeat.dispose();
    // Closing the page while verifying or unlocked gives the grant back.
    if (open) unawaited(backend.cancel());
    super.dispose();
  }
}
