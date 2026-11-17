// Sense Remote: data, tokens and the platform interface of the Sense setup wizard (split out of
// sense_install_wizard.dart, code review K3-6; behaviour unchanged).

import 'dart:convert';

import 'package:flutter/material.dart';

import 'sense_install_strings.dart';

String _t(String key) => senseInstallText(key);

/// Limits match `src/sense.rs` and `src/sense/enroll.rs`.
const int kSenseMaxName = 64;
const int kSenseMaxProjects = 10;
const int kSenseMaxProject = 48;
const int kSenseMaxLocation = 96;
const int kSenseMaxNote = 300;

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

enum SenseInstallStep { account, role, info, summary, register, done }

/// What the employee can do about a refused registration (panel `EnrollErrorCode`).
enum SenseEnrollAction { retry, relogin, edit, wait, none }

/// Panel `429` comes with `Retry-After: 60`.
const int kSenseRetryAfterSeconds = 60;

SenseEnrollAction senseEnrollAction(String code) {
  switch (code) {
    // The install token is not valid for this computer any more: sign in again.
    case 'token_invalid':
    case 'install_scope':
    case 'device_mismatch':
      return SenseEnrollAction.relogin;
    // The details or project choice were refused: fix them.
    case 'validation':
    case 'project_not_found':
    // Sense Remote: local checks of src/sense/enroll.rs (review K3-5).
    case 'invalid-name':
    case 'invalid-location':
    case 'invalid-note':
    case 'invalid-project':
      return SenseEnrollAction.edit;
    case 'rate_limited':
      return SenseEnrollAction.wait;
    // Another computer holds this ID (panel alert): retrying can not help.
    case 'uuid_mismatch':
    // Sense Remote: a broken setup file or install; retrying can not fix it (review K3-5).
    case 'not-installed':
    case 'build':
    case 'identity':
    case 'identity-store':
    // Sense Remote: the panel closed this computer (refused / removed); only an admin helps.
    case 'device_closed':
      return SenseEnrollAction.none;
    // Sense Remote: already active in the panel; retry after "Yeniden kurulum izni" there.
    case 'reinstall_not_allowed':
      return SenseEnrollAction.retry;
    default: // retry, network, other, unknown codes
      return SenseEnrollAction.retry;
  }
}

/// Lower case as the panel compares project names (`toLocaleLowerCase("tr")`).
String senseTrLower(String value) =>
    value.replaceAll('I', 'ı').replaceAll('İ', 'i').toLowerCase();

// ---- Data from / to the native side (src/sense/enroll.rs) ----

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

class SenseProject {
  const SenseProject(this.id, this.name);
  final String id;
  final String name;
}

/// Projects the signed-in employee can pick (`install_sense_projects`).
class SenseProjectList {
  const SenseProjectList.ok(this.projects) : error = '';
  const SenseProjectList.error(this.error) : projects = const [];

  factory SenseProjectList.fromJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      if (map['ok'] != true) {
        return SenseProjectList.error(map['error'] as String? ?? 'retry');
      }
      return SenseProjectList.ok([
        for (final p in map['projects'] as List)
          SenseProject(p['id'] as String, p['name'] as String),
      ]);
    } catch (_) {
      return const SenseProjectList.error('retry');
    }
  }

  final List<SenseProject> projects;
  final String error;
  bool get ok => error.isEmpty;
}

/// Panel registration result (`install_sense_enroll`).
class SenseEnrollResult {
  const SenseEnrollResult.ok(this.projects) : error = '';
  const SenseEnrollResult.error(this.error) : projects = const [];

  factory SenseEnrollResult.fromJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      if (map['ok'] != true) {
        return SenseEnrollResult.error(map['error'] as String? ?? 'other');
      }
      return SenseEnrollResult.ok([
        for (final p in map['projects'] as List) p['name'] as String,
      ]);
    } catch (_) {
      return const SenseEnrollResult.error('other');
    }
  }

  /// Names of the projects the computer was added to (shown on the done page).
  final List<String> projects;
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
    required this.location,
    required this.note,
    required this.projectIds,
    required this.newProjects,
  });

  final String name;
  final String location;
  final String note;
  final List<String> projectIds;
  final List<String> newProjects;

  String toJson() => jsonEncode({
        'name': name,
        'location': location,
        'note': note,
        'project_ids': projectIds,
        'new_projects': newProjects,
      });
}

/// Platform side of the wizard (`sense_install_page.dart` binds it to Rust).
abstract class SenseInstallBackend {
  Future<void> loginStart();
  Future<SenseLoginStatus> loginStatus();
  Future<void> loginCancel();
  Future<void> openUrl(String url);
  Future<SenseProjectList> projects();

  /// "" on success, "cancelled" when the administrator prompt was declined, otherwise an error.
  Future<String> install(SenseInstallRequest request);
  Future<SenseEnrollResult> enroll(SenseEnrollRequest request);

  /// Leaves the setup screen; `true` opens the installed app.
  void finish(bool openApp);
}

String senseRoleLabel(bool host, bool controller) => host && controller
    ? 'Host + Controller'
    : host
        ? 'Host'
        : controller
            ? 'Controller'
            : _t('none');
