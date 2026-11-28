// Sense Remote: the person's own permissions on this Controller (YH S11, P8,
// P9; plan §2.4, §2.6). The signed grants envelope is checked in Rust (D3a,
// `main_sense_grants`); Dart only reads the answer
// `{state:"ok"|"missing"|"expired"|"invalid", perms:[…], email, rev}`.
// Anything but "ok" means every permission is closed (the screen then says
// "Yetkiler panelden alınamadı" and Bağlan is locked).
//
// Hiding a button here is not the protection (plan §2.4 "Sınır"): the panel
// refuses the lists, peer-status and connections a person may not use.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../models/platform_model.dart' show bind;

enum SenseGrantsState { ok, missing, expired, invalid }

/// App permissions (panel `APP_PERMISSIONS`).
abstract final class SensePerm {
  static const String connect = 'connect';
  static const String control = 'control';
  static const String fileTransfer = 'file_transfer';
  static const String recordSession = 'record_session';
  static const String privacyMode = 'privacy_mode';
  static const String restartRemote = 'restart_remote';
  static const String terminalTunnel = 'terminal_tunnel';
  static const String installDevice = 'install_device';

  static const List<String> all = [
    connect,
    control,
    fileTransfer,
    recordSession,
    privacyMode,
    restartRemote,
    terminalTunnel,
    installDevice,
  ];
}

class SenseGrants {
  const SenseGrants({required this.state, this.perms = const {}, this.email = '', this.rev = 0});

  final SenseGrantsState state;
  final Set<String> perms;
  final String email;
  final int rev;

  bool get ok => state == SenseGrantsState.ok;

  /// Closed unless the envelope is valid and carries [perm].
  bool can(String perm) => ok && perms.contains(perm);

  static const missing = SenseGrants(state: SenseGrantsState.missing);

  factory SenseGrants.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return missing;
      final state = switch (v['state']) {
        'ok' => SenseGrantsState.ok,
        'expired' => SenseGrantsState.expired,
        'invalid' => SenseGrantsState.invalid,
        _ => SenseGrantsState.missing,
      };
      final perms = v['perms'];
      return SenseGrants(
        state: state,
        perms: {
          if (perms is List)
            for (final p in perms)
              if (p is String && SensePerm.all.contains(p)) p,
        },
        email: v['email'] is String ? v['email'] as String : '',
        rev: v['rev'] is int ? v['rev'] as int : 0,
      );
    } catch (_) {
      return missing;
    }
  }
}

abstract class SenseGrantsBackend {
  Future<String> grants();

  /// Asks the panel now (`GET /api/sense/grants`), e.g. when the window gets focus.
  Future<void> refresh();
}

class SenseGrantsBridge implements SenseGrantsBackend {
  const SenseGrantsBridge();

  @override
  Future<String> grants() => bind.mainSenseGrants();

  @override
  Future<void> refresh() => bind.mainSenseGrantsRefresh();
}

/// Keeps the grants fresh while the Controller list is open: every [interval]
/// (plan §2.3: 10 s) and when asked (window focus).
///
/// #149: right after the start the panel answer is often not there yet (the core
/// fetches it with its own retries). The screen therefore does not call the grants
/// "missing" at the first failed answer: it waits for [graceReads] answers in a row
/// that are not "ok" (asked every [quickInterval] meanwhile, about 10 s in all).
class SenseGrantsWatch extends ChangeNotifier {
  SenseGrantsWatch(this.backend,
      {this.interval = const Duration(seconds: 10), this.quickInterval = const Duration(seconds: 4)});

  /// Answers in a row that are not "ok" before the screen says so (#149: 3 tries).
  static const int graceReads = 3;

  final SenseGrantsBackend backend;
  final Duration interval;

  /// Spacing of the first retries while the answer is not "ok" yet.
  final Duration quickInterval;
  SenseGrants _grants = SenseGrants.missing;
  bool _loaded = false;
  int _misses = 0;
  Timer? _timer;
  Timer? _quick;
  bool _disposed = false;

  SenseGrants get grants => _grants;

  /// False until the first answer.
  bool get loaded => _loaded;

  /// #149: the answer can be trusted: "ok", or [graceReads] answers in a row were not.
  /// Until then the screen shows neither "Yetkiler panelden alınamadı" nor "Yetkin yok".
  bool get settled => _loaded && (_grants.ok || _misses >= graceReads);

  void start() {
    unawaited(_read());
    _timer ??= Timer.periodic(interval, (_) => unawaited(_read()));
    _quick ??= Timer.periodic(quickInterval, (_) {
      if (_grants.ok || _misses >= graceReads) {
        _quick?.cancel();
        _quick = null;
        return;
      }
      unawaited(_read());
    });
  }

  Future<void> refresh() async {
    try {
      await backend.refresh();
    } catch (_) {}
    await _read();
  }

  Future<void> _read() async {
    SenseGrants g;
    try {
      g = SenseGrants.parse(await backend.grants());
    } catch (_) {
      // P3 (B11): a failed read keeps the last good answer; only a first read that fails
      // is `missing`.
      if (_loaded || _disposed) return;
      g = SenseGrants.missing;
    }
    if (_disposed) return;
    final wasSettled = settled;
    final changed = !_loaded ||
        g.state != _grants.state ||
        g.rev != _grants.rev ||
        !setEquals(g.perms, _grants.perms);
    _grants = g;
    _loaded = true;
    _misses = g.ok ? 0 : _misses + 1;
    if (changed || wasSettled != settled) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _quick?.cancel();
    super.dispose();
  }
}
