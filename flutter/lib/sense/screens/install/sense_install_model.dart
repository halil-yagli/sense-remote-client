// Sense Remote: data, tokens and the platform interface of the Sense setup wizard (split out of
// sense_install_wizard.dart, code review K3-6; behaviour unchanged).

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../tokens/sense_tokens.dart';

import 'sense_install_strings.dart';
import 'sense_mac_permissions.dart';

export 'sense_mac_permissions.dart';

String _t(String key) => senseInstallText(key);

/// Limits match `src/sense.rs` and `src/sense/enroll.rs`.
const int kSenseMaxName = 64;
const int kSenseMaxProjects = 10;
const int kSenseMaxProject = 48;
const int kSenseMaxLocation = 96;
const int kSenseMaxNote = 300;

/// Design tokens (BRAND_CORE §5: black and white, navy→purple light accent).
// Sense Remote (A1b, YH T1): bridge only. Every field is an alias of the one token set
// (tokens/sense_tokens.dart); screens move to SenseColors in their own PRs, then this goes.
class SenseTokens {
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const black = SenseColors.bg;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const white = SenseColors.text;
  // Was #1D1D25: the hover tone, not a border.
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const line = SenseColors.hover;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const border = SenseColors.line;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const field = SenseColors.surface;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const muted = SenseColors.textMuted;
  // Was #76767F on readable setup texts (notes, hints): readable text is at least muted (#68).
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const dim = SenseColors.textMuted;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const soft = SenseColors.textSecondary;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const text3 = SenseColors.textSecondary;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const accent1 = SenseColors.glowStart;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const accent2 = SenseColors.glowEnd;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const error = SenseColors.dangerTextSoft;
  @Deprecated('Sense Remote A1b: use SenseRadii / tokens/sense_tokens.dart')
  static const radius = SenseRadii.categoryLarge;
  @Deprecated('Sense Remote A1b: use SenseRadii / tokens/sense_tokens.dart')
  static const radiusCard = SenseRadii.popup;
  @Deprecated('Sense Remote A1b: use SenseFont / tokens/sense_tokens.dart')
  static const font = SenseFont.family;
  // No token: system fonts after the bundled Poppins.
  @Deprecated('Sense Remote A1b: use SenseFont / tokens/sense_tokens.dart')
  static const fontFallback = ['Segoe UI', 'Helvetica Neue', 'Arial'];
  @Deprecated('Sense Remote A1b: use SenseGradients / tokens/sense_tokens.dart')
  static const gradient = SenseGradients.glow;
}

// Sense Remote (Mac M3): `applications` and `permissions` are macOS only; Windows never
// enters them. The order is the order of the wizard (the sidebar compares indexes).
// Sense Remote (update plan §8, U7): `upgrade` is the one-time move from version 2; it replaces
// sign-in, role, info and registration (only `permissions` on macOS and `done` follow it).
enum SenseInstallStep {
  upgrade,
  applications,
  account,
  role,
  info,
  summary,
  register,
  permissions,
  done
}

// ---- macOS (Mac M3, plan 2026-11-21 §4.1) ----

/// Pure: on macOS the app itself is the setup file, so a launch without an installed role
/// opens the wizard (Windows gets there with the `--install` argument of the setup exe).
bool senseMacNeedsSetup({required bool isMac, required bool roleInstalled}) =>
    isMac && !roleInstalled;

// Sense Remote (code review K4-5): the permission model is shared with the home screens
// (sense_mac_permissions.dart, exported above).

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

  // Sense Remote (Mac M3): macOS only; the wizard calls these only when it runs as `mac`.

  /// Whether the app runs from the Applications folder (not from the disk image).
  Future<bool> inApplications();

  /// Current state of the privacy permissions (no system prompt).
  Future<SenseMacPermissions> macPermissions();

  /// Asks macOS for the permission and opens its pane in System Settings.
  Future<void> openMacPermission(SenseMacPermission permission);

  /// Restarts the background agent after Screen Recording was granted; "" on success.
  Future<String> restartAgent();
}

String senseRoleLabel(bool host, bool controller) => host && controller
    ? 'Host + Controller'
    : host
        ? 'Host'
        : controller
            ? 'Controller'
            : _t('none');
