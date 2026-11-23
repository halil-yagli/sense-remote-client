// Sense Remote: data and the platform interface of the setup wizard (YH K1–K7).
// Pure Dart: the wizard and its tests use only this; `data/install_bridge.dart` binds it to Rust.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'sense_mac_permissions.dart';

export 'sense_mac_permissions.dart';

/// Limits match the panel contract (`EnrollBody`) and `src/sense/enroll.rs`.
const int kSenseMaxName = 64;
const int kSenseMaxProjects = 10;
const int kSenseMaxNote = 300;

/// Only company accounts may install (YH K2).
const String kSenseCompanyDomain = '@sensedepartment.com';

/// How often the project and location lists are read again on the details step (YH K4: a
/// membership or a location added in the panel shows up by itself).
const Duration kSenseOptionsPoll = Duration(seconds: 10);

/// Panel `429` comes with `Retry-After: 60`.
const int kSenseRetryAfterSeconds = 60;

// Sense Remote: legacy colour class (TK9). No screen of the wizard uses it any more; it stays
// until the colour bridge PR removes it (plan B/C common rules: the body is not touched).
/// Design tokens (BRAND_CORE §5: black and white, navy→purple light accent).
class SenseTokens {
  static const black = Color(0xFF000000);
  static const white = Color(0xFFFFFFFF);
  static const line = Color(0xFF1D1D25);
  static const border = Color(0xFF2A2A33);
  static const field = Color(0xFF0A0A0E);
  static const muted = Color(0xFF8E8E98);
  // Sense Remote: #5D5D66 was 3.2:1 on black; #76767F is about 4.6:1 (WCAG AA
  // for the small setup texts, design review T3-5).
  static const dim = Color(0xFF76767F);
  static const soft = Color(0xFFC9C9D1);
  static const text3 = Color(0xFFB5B5BE);
  static const accent1 = Color(0xFF020162);
  static const accent2 = Color(0xFF640164);
  static const error = Color(0xFFFF6B7A);
  static const radius = 10.0;
  static const radiusCard = 14.0;
  static const font = 'Poppins';
  static const fontFallback = ['Segoe UI', 'Helvetica Neue', 'Arial'];
  static const gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [accent1, accent2]);
}

/// Steps in wizard order (the sidebar compares indexes). `applications` and `permissions`
/// are macOS only; `upgrade` replaces the whole flow on a computer with an older version.
enum SenseInstallStep { upgrade, applications, account, role, info, summary, permissions, done }

/// Pure: on macOS the app itself is the setup file, so a launch without an installed role
/// opens the wizard (Windows gets there with the `--install` argument of the setup exe).
bool senseMacNeedsSetup({required bool isMac, required bool roleInstalled}) =>
    isMac && !roleInstalled;

/// What the employee can do about a refused registration (panel `EnrollErrorCode`).
enum SenseEnrollAction { retry, relogin, edit, wait, none }

SenseEnrollAction senseEnrollAction(String code) {
  switch (code) {
    case 'token_invalid':
    case 'install_scope':
    case 'device_mismatch':
      return SenseEnrollAction.relogin;
    case 'validation':
    case 'project_not_found':
    case 'location_not_found':
    case 'invalid-name':
    case 'invalid-location':
    case 'invalid-note':
    case 'invalid-project':
      return SenseEnrollAction.edit;
    case 'rate_limited':
      return SenseEnrollAction.wait;
    case 'uuid_mismatch':
    case 'not-installed':
    case 'build':
    case 'identity':
    case 'identity-store':
      return SenseEnrollAction.none;
    // permission_denied: an admin turns "Bilgisayar kurma" on in the panel, then a retry works.
    default:
      return SenseEnrollAction.retry;
  }
}

/// Whether a signed-in e-mail may install (company domain, any letter case).
bool senseCompanyEmail(String email) =>
    email.trim().toLowerCase().endsWith(kSenseCompanyDomain);

// ---- Data from / to the native side ----

/// Sign-in state (`install_sense_login_status`). The access token never reaches Dart.
class SenseLoginStatus {
  const SenseLoginStatus(
    this.state, {
    this.url = '',
    this.pairingCode = '',
    this.error = '',
    this.detail = '',
    this.email = '',
    this.displayName = '',
  });

  /// Before the first sign-in attempt (not sent by the native side).
  static const idle = SenseLoginStatus('idle');

  factory SenseLoginStatus.fromJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      Map user = const {};
      if (map['user'] is Map) user = map['user'] as Map;
      return SenseLoginStatus(
        map['state'] as String? ?? 'failed',
        url: map['url'] as String? ?? '',
        pairingCode: map['pairing_code'] as String? ?? '',
        error: map['error'] as String? ?? '',
        detail: map['detail'] as String? ?? '',
        email: user['name'] as String? ?? '',
        displayName: user['display_name'] as String? ?? '',
      );
    } catch (_) {
      return const SenseLoginStatus('failed', error: 'failed');
    }
  }

  /// idle | requesting | waiting | done | failed
  final String state;
  final String url;
  final String pairingCode;

  /// `timeout` or `failed` when [state] is `failed`.
  final String error;
  final String detail;
  final String email;
  final String displayName;

  bool sameAs(SenseLoginStatus other) =>
      state == other.state &&
      url == other.url &&
      pairingCode == other.pairingCode &&
      error == other.error &&
      detail == other.detail &&
      email == other.email &&
      displayName == other.displayName;

  bool get isDone => state == 'done';
  bool get isWaiting => state == 'waiting';
  bool get isRequesting => state == 'requesting';
  bool get isFailed => state == 'failed';
}

/// A location (salon, section) defined in the panel for a project (YH K4, S2).
class SenseLocation {
  const SenseLocation(this.id, this.name);
  final String id;
  final String name;
}

/// A project the signed-in employee is a member of, with its panel locations.
class SenseProject {
  const SenseProject(this.id, this.name, [this.locations = const []]);
  final String id;
  final String name;
  final List<SenseLocation> locations;
}

/// What the details step offers. Only projects the employee is a member of; no new projects.
class SenseInstallOptions {
  const SenseInstallOptions.ok(this.projects) : error = '';
  const SenseInstallOptions.error(this.error) : projects = const [];

  /// `{"ok": true, "projects": [{id, name, locations: [{id, name}]}]}` or
  /// `{"ok": false, "error": "token_invalid" | "network" | "retry"}`. Location items may also
  /// use the panel names (`location_id`).
  factory SenseInstallOptions.fromJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      if (map['ok'] != true) {
        return SenseInstallOptions.error(map['error'] as String? ?? 'retry');
      }
      return SenseInstallOptions.ok([
        for (final p in map['projects'] as List)
          SenseProject(p['id'] as String, p['name'] as String, [
            for (final l in (p['locations'] as List?) ?? const [])
              SenseLocation((l['id'] ?? l['location_id']) as String, l['name'] as String),
          ]),
      ]);
    } catch (_) {
      return const SenseInstallOptions.error('retry');
    }
  }

  final List<SenseProject> projects;
  final String error;
  bool get ok => error.isEmpty;
}

/// Panel registration result (`install_sense_enroll`).
class SenseEnrollResult {
  const SenseEnrollResult.ok(this.projects, [this.location = '']) : error = '';
  const SenseEnrollResult.error(this.error)
      : projects = const [],
        location = '';

  factory SenseEnrollResult.fromJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      if (map['ok'] != true) {
        return SenseEnrollResult.error(map['error'] as String? ?? 'other');
      }
      final location = map['location'];
      return SenseEnrollResult.ok([
        for (final p in map['projects'] as List) p['name'] as String,
      ], location is Map ? (location['name'] as String? ?? '') : '');
    } catch (_) {
      return const SenseEnrollResult.error('other');
    }
  }

  /// Names of the projects the computer was added to.
  final List<String> projects;

  /// Registered location name (empty while the native side does not pass it on).
  final String location;
  final String error;
  bool get ok => error.isEmpty;
}

class SenseInstallRequest {
  const SenseInstallRequest({
    required this.host,
    required this.controller,
    required this.name,
    required this.location,
    required this.path,
    required this.startMenu,
    required this.desktopIcon,
    required this.printer,
  });

  final bool host;
  final bool controller;
  final String name;
  final String location;
  final String path;
  final bool startMenu;
  final bool desktopIcon;
  final bool printer;

  /// Value for `install_sense_install` (src/sense.rs `SenseRole::parse`).
  String get role => host && controller
      ? 'both'
      : host
          ? 'host'
          : 'controller';

  /// RustDesk install options (`install_me`).
  String get options => [
        if (startMenu) 'startmenu',
        if (desktopIcon) 'desktopicon',
        if (printer) 'printer',
      ].map((o) => ' $o').join();

  /// What stays on the computer (HKLM `Setup`): name and location only, never project names
  /// (wave 3 K-YEREL).
  String get infoJson => jsonEncode({'name': name, 'location': location});
}

/// Body for `install_sense_enroll` (src/sense/enroll.rs `EnrollInput`).
class SenseEnrollRequest {
  const SenseEnrollRequest({
    required this.name,
    required this.locationId,
    required this.locationName,
    required this.note,
    required this.projectIds,
  });

  final String name;
  final String locationId;
  final String locationName;
  final String note;
  final List<String> projectIds;

  /// `location` (the name) stays for today's native side, which forwards only the name (the
  /// panel then finds the location by name in the chosen projects); `location_id` is the
  /// Sürüm 4 field. TODO(D3-0): `enroll_body` forwards `location_id` to the panel.
  String toJson() => jsonEncode({
        'name': name,
        'location': locationName,
        'location_id': locationId,
        'note': note,
        'project_ids': projectIds,
        'new_projects': const <String>[],
      });
}

/// Platform side of the wizard (`data/install_bridge.dart` binds it to Rust; tests fake it).
abstract class SenseInstallBackend {
  Future<void> loginStart();
  Future<SenseLoginStatus> loginStatus();
  Future<void> loginCancel();
  Future<void> openUrl(String url);
  Future<void> copy(String text);

  /// Projects of the signed-in employee and their panel locations.
  Future<SenseInstallOptions> installOptions();

  /// Whether installing into [path] could overwrite other files (folder exists, not empty and
  /// not this app's own install folder). Shown in place, never as a window (YH K5).
  Future<bool> folderNotEmpty(String path);

  /// "" on success, "cancelled" when the administrator prompt was declined, otherwise an error.
  Future<String> install(SenseInstallRequest request);
  Future<SenseEnrollResult> enroll(SenseEnrollRequest request);

  /// Leaves the setup screen; `true` opens the installed app.
  void finish(bool openApp);

  // macOS only; the wizard calls these only when it runs as `mac`.

  /// Whether the app runs from the Applications folder (not from the disk image).
  Future<bool> inApplications();

  /// Current state of the privacy permissions (no system prompt).
  Future<SenseMacPermissions> macPermissions();

  /// Asks macOS for the permission and opens its pane in System Settings.
  Future<void> openMacPermission(SenseMacPermission permission);

  /// Restarts the background agent after Screen Recording was granted; "" on success.
  Future<String> restartAgent();
}
