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
class SenseGrantsWatch extends ChangeNotifier {
  SenseGrantsWatch(this.backend, {this.interval = const Duration(seconds: 10)});

  final SenseGrantsBackend backend;
  final Duration interval;
  SenseGrants _grants = SenseGrants.missing;
  bool _loaded = false;
  Timer? _timer;
  bool _disposed = false;

  SenseGrants get grants => _grants;

  /// False until the first answer (the screen does not flash "alınamadı").
  bool get loaded => _loaded;

  void start() {
    unawaited(_read());
    _timer ??= Timer.periodic(interval, (_) => unawaited(_read()));
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
      g = SenseGrants.missing;
    }
    if (_disposed) return;
    final changed = !_loaded ||
        g.state != _grants.state ||
        g.rev != _grants.rev ||
        !setEquals(g.perms, _grants.perms);
    _grants = g;
    _loaded = true;
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
