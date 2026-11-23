// Sense Remote: role of this computer and the in-app role change (YH H2, S4;
// plan §2.6). Bridge `main_sense_role_*` (D3b, `src/sense/role_change.rs`):
// Sense sign-in with purpose `role` → panel `role-change` → the service applies
// the signed role → the app reopens with it.
import 'dart:convert';

import '../../../../models/platform_model.dart';
import '../../controller/sense_home_strings.dart' show SenseHomeRole;

enum SenseRole { host, controller }

/// The wire value of a role set: `host`, `controller`, `host_controller`; null for
/// the empty set (never sent: the last role can not be removed).
String? senseRoleTarget(Set<SenseRole> roles) {
  final h = roles.contains(SenseRole.host), c = roles.contains(SenseRole.controller);
  if (h && c) return 'host_controller';
  if (h) return 'host';
  if (c) return 'controller';
  return null;
}

Set<SenseRole> senseRolesOf(SenseHomeRole role) {
  switch (role) {
    case SenseHomeRole.host:
      return {SenseRole.host};
    case SenseHomeRole.controller:
      return {SenseRole.controller};
    case SenseHomeRole.both:
      return {SenseRole.host, SenseRole.controller};
    case SenseHomeRole.none:
      return <SenseRole>{};
  }
}

Set<SenseRole> _roles(Object? list) {
  final out = <SenseRole>{};
  if (list is List) {
    for (final r in list) {
      if (r == 'host') out.add(SenseRole.host);
      if (r == 'controller') out.add(SenseRole.controller);
      if (r == 'host_controller') out.addAll(SenseRole.values);
    }
  }
  return out;
}

/// `main_sense_role_status`: `{roles:[…], pending:null|{target, stage}, error}`.
class SenseRoleStatus {
  const SenseRoleStatus({this.roles = const {}, this.pendingStage, this.error});
  final Set<SenseRole> roles;
  final String? pendingStage;
  final String? error;

  factory SenseRoleStatus.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return const SenseRoleStatus();
      final p = v['pending'];
      final e = v['error'];
      return SenseRoleStatus(
        roles: _roles(v['roles']),
        pendingStage: p is Map && p['stage'] is String ? p['stage'] as String : null,
        error: e is String && e.isNotEmpty ? e : null,
      );
    } catch (_) {
      return const SenseRoleStatus();
    }
  }
}

/// Answer of `main_sense_role_change_begin` (`{pairing_code, url, expires_at}`)
/// and `main_sense_role_change_status` (`{stage, error}`).
class SenseRoleAnswer {
  const SenseRoleAnswer({this.stage, this.error, this.code = '', this.url = '', this.expiresAt});
  final String? stage;
  final String? error;
  final String code;
  final String url;
  final int? expiresAt;

  factory SenseRoleAnswer.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return const SenseRoleAnswer(error: 'other');
      String? s(Object? o) => o is String && o.isNotEmpty ? o : null;
      return SenseRoleAnswer(
        stage: s(v['stage']),
        error: s(v['error']),
        code: s(v['pairing_code']) ?? '',
        url: s(v['url']) ?? '',
        expiresAt: v['expires_at'] is int ? v['expires_at'] as int : null,
      );
    } catch (_) {
      return const SenseRoleAnswer(error: 'other');
    }
  }
}

abstract class SenseRoleBackend {
  Future<String> status();
  Future<String> begin(String target);
  Future<String> changeStatus();
  Future<void> cancel();
}

class SenseRoleBridge implements SenseRoleBackend {
  const SenseRoleBridge();

  /// The stored role (Windows HKLM / macOS state.json) and a running change.
  @override
  Future<String> status() => bind.mainSenseRoleStatus();

  /// Sense sign-in with purpose `role` → `{pairing_code, url, expires_at}`.
  @override
  Future<String> begin(String target) => bind.mainSenseRoleChangeBegin(target: target);

  /// `{stage: login|applying|restarting, error}`; the service applies the
  /// panel's signed role and `restarting` means it is stored.
  @override
  Future<String> changeStatus() => bind.mainSenseRoleChangeStatus();

  @override
  Future<void> cancel() => bind.mainSenseRoleChangeCancel();
}
