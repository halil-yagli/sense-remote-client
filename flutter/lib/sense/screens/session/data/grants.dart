// Sense Remote: the person's rights (plan §2.1, S11) as the session buttons see them.
// A session button works only when both the person (panel envelope, `main_sense_grants`)
// and the computer (RustDesk permission) allow it; a button the person may not use is
// shown locked, not hidden ("Yetkin yok · panelden").
import 'dart:async';
import 'dart:convert';

import '../../../../models/platform_model.dart' show bind;

/// Person right keys (plan §2.1, `packages/shared/src/permissions.ts`).
abstract final class SenseGrant {
  static const String connect = 'connect';
  static const String control = 'control';
  static const String fileTransfer = 'file_transfer';
  static const String recordSession = 'record_session';
  static const String privacyMode = 'privacy_mode';
  static const String restartRemote = 'restart_remote';
  static const String terminalTunnel = 'terminal_tunnel';
  static const String installDevice = 'install_device';
}

/// Envelope state of `main_sense_grants()` (plan §2.6).
enum SenseGrantsState { ok, missing, expired, invalid, unavailable }

class SenseSessionGrants {
  const SenseSessionGrants(this.state, this.perms);

  /// The bridge function is not there yet: nothing is locked by the person's rights
  /// (the computer's RustDesk permissions still apply).
  const SenseSessionGrants.unavailable()
      : state = SenseGrantsState.unavailable,
        perms = const {};

  final SenseGrantsState state;
  final Set<String> perms;

  /// Whether the person may use [grant]. With a valid envelope: when it lists the
  /// right. Without one (missing, expired, invalid): never.
  bool allows(String grant) {
    switch (state) {
      case SenseGrantsState.unavailable:
        return true;
      case SenseGrantsState.ok:
        return perms.contains(grant);
      case SenseGrantsState.missing:
      case SenseGrantsState.expired:
      case SenseGrantsState.invalid:
        return false;
    }
  }

  /// Parses `{state:"ok"|"missing"|"expired"|"invalid", perms:[…], email, rev}`.
  static SenseSessionGrants parse(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const SenseSessionGrants(SenseGrantsState.invalid, {});
      final state = switch (j['state']) {
        'ok' => SenseGrantsState.ok,
        'missing' => SenseGrantsState.missing,
        'expired' => SenseGrantsState.expired,
        _ => SenseGrantsState.invalid,
      };
      final perms = <String>{
        if (j['perms'] is List)
          for (final p in j['perms'] as List)
            if (p is String) p,
      };
      return SenseSessionGrants(state, perms);
    } catch (_) {
      return const SenseSessionGrants(SenseGrantsState.invalid, {});
    }
  }
}

/// Reads the person's rights for the session buttons (`main_sense_grants`, checked in Rust).
/// The bridge answers asynchronously; the buttons read the last answer and a new read starts
/// at most every [_SenseSessionGrantsCache.every]. Until the first answer everything is closed
/// (missing), like a missing envelope; the session backend repaints often (link meter), so the
/// answer shows within a second.
SenseSessionGrants senseReadSessionGrants() => _SenseSessionGrantsCache.read();

abstract final class _SenseSessionGrantsCache {
  static const Duration every = Duration(seconds: 5);
  static SenseSessionGrants _value = const SenseSessionGrants(SenseGrantsState.missing, {});
  static DateTime? _askedAt;
  static bool _asking = false;

  static SenseSessionGrants read() {
    final now = DateTime.now();
    final asked = _askedAt;
    if (!_asking && (asked == null || now.difference(asked) >= every)) {
      _asking = true;
      _askedAt = now;
      unawaited(_ask());
    }
    return _value;
  }

  static Future<void> _ask() async {
    try {
      _value = SenseSessionGrants.parse(await bind.mainSenseGrants());
    } catch (_) {
      _value = const SenseSessionGrants(SenseGrantsState.invalid, {});
    } finally {
      _asking = false;
    }
  }
}
