// Sense Remote: Sense setup wizard (prototype Calisma/prototip/kurulum.html).
// Pure UI: every platform call goes through [SenseInstallBackend], so it runs in widget tests.
//
// Wave 3 (I6): step 1 is the Sense sign-in (K-GİRİŞ: the 6-digit pairing code is shown large,
// the browser opens only on request), the project list comes from the panel, and after the
// installation the computer is registered with the panel (K-KAYIT: "Yeniden dene", or skip and
// it shows up in the panel as waiting for approval).

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
  static const dim = Color(0xFF5D5D66);
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
      return SenseEnrollAction.edit;
    case 'rate_limited':
      return SenseEnrollAction.wait;
    // Another computer holds this ID (panel alert): retrying can not help.
    case 'uuid_mismatch':
      return SenseEnrollAction.none;
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

const String _googleLogo =
    '<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg">'
    '<path fill="#4285F4" d="M45 24.5c0-1.6-.1-3.1-.4-4.5H24v8.5h11.8c-.5 2.7-2 5-4.4 6.6v5.5h7.1c4.1-3.8 6.5-9.4 6.5-16.1z"/>'
    '<path fill="#34A853" d="M24 46c5.9 0 10.9-2 14.5-5.3l-7.1-5.5c-2 1.3-4.5 2.1-7.4 2.1-5.7 0-10.5-3.8-12.2-9H4.5v5.7C8.1 41.1 15.5 46 24 46z"/>'
    '<path fill="#FBBC05" d="M11.8 28.3c-.4-1.3-.7-2.7-.7-4.3s.3-3 .7-4.3V14H4.5C3 17 2.2 20.4 2.2 24s.8 7 2.3 10l7.3-5.7z"/>'
    '<path fill="#EA4335" d="M24 10.7c3.2 0 6.1 1.1 8.4 3.3l6.3-6.3C34.9 4.2 29.9 2 24 2 15.5 2 8.1 6.9 4.5 14l7.3 5.7c1.7-5.2 6.5-9 12.2-9z"/>'
    '</svg>';

class SenseInstallWizard extends StatefulWidget {
  const SenseInstallWizard({
    super.key,
    required this.initialPath,
    required this.backend,
    this.initialStartMenu = true,
    this.initialDesktopIcon = true,
    this.initialPrinter = false,
    this.onPickPath,
    this.onClose,
    this.onDragStart,
    this.version = '1',
    this.icon,
    this.pollInterval = const Duration(seconds: 1),
  });

  final String initialPath;
  final SenseInstallBackend backend;
  final bool initialStartMenu;
  final bool initialDesktopIcon;
  final bool initialPrinter;
  final Future<String?> Function(String current)? onPickPath;
  final VoidCallback? onClose;
  final VoidCallback? onDragStart;
  final String version;
  final Widget? icon;

  /// How often the sign-in state is read while waiting for the browser.
  final Duration pollInterval;

  @override
  State<SenseInstallWizard> createState() => _SenseInstallWizardState();
}

class _SenseInstallWizardState extends State<SenseInstallWizard> {
  SenseInstallStep _step = SenseInstallStep.account;

  // Sign-in.
  SenseLoginStatus _login = SenseLoginStatus.idle;
  Timer? _poll;
  bool _polling = false;
  int _loginAttempt = 0;
  String? _notice;

  // Role and info.
  bool _host = false;
  bool _controller = false;
  final _name = TextEditingController();
  final _newProject = TextEditingController();
  final _location = TextEditingController();
  final _note = TextEditingController();
  final _newProjectFocus = FocusNode();
  List<SenseProject>? _available;
  bool _projectsLoading = false;
  String _projectsError = '';
  final Set<String> _selectedIds = {};
  final List<String> _newProjects = [];

  // Install and registration.
  late String _path = widget.initialPath;
  late bool _startMenu = widget.initialStartMenu;
  late bool _desktopIcon = widget.initialDesktopIcon;
  late bool _printer = widget.initialPrinter;
  bool _advanced = false;
  bool _installing = false;
  String? _error;
  bool _enrolling = false;
  String _enrollError = '';
  bool _registered = false;
  List<String> _enrolledProjects = const [];

  /// Installed by this wizard: the role is fixed, only sign-in and details can be redone for
  /// the registration.
  bool _installed = false;

  /// Seconds left before "Yeniden dene" after `rate_limited` (panel `Retry-After: 60`).
  int _waitLeft = 0;
  Timer? _waitTimer;

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
  }

  @override
  void dispose() {
    _poll?.cancel();
    _waitTimer?.cancel();
    _name.dispose();
    _newProject.dispose();
    _location.dispose();
    _note.dispose();
    _newProjectFocus.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _go(SenseInstallStep step) => setState(() {
        _step = step;
        _error = null;
        _notice = null;
      });

  bool get _busy => _installing || _enrolling;

  // ---- Sign-in ----

  Future<void> _startLogin() async {
    final attempt = ++_loginAttempt;
    _poll?.cancel();
    setState(() {
      _login = const SenseLoginStatus('requesting');
      _notice = null;
    });
    try {
      await widget.backend.loginStart();
    } catch (_) {
      if (mounted && attempt == _loginAttempt) {
        setState(() => _login = const SenseLoginStatus('failed', error: 'failed'));
      }
      return;
    }
    if (!mounted || attempt != _loginAttempt) return;
    _poll = Timer.periodic(widget.pollInterval, (_) => _pollLogin(attempt));
  }

  Future<void> _pollLogin(int attempt) async {
    if (_polling) return;
    _polling = true;
    SenseLoginStatus status;
    try {
      status = await widget.backend.loginStatus();
    } catch (_) {
      status = const SenseLoginStatus('failed', error: 'failed');
    } finally {
      _polling = false;
    }
    if (!mounted || attempt != _loginAttempt) return;
    if (status.isDone || status.isFailed) _poll?.cancel();
    if (status.sameAs(_login)) return;
    setState(() => _login = status);
    if (status.isDone) unawaited(_loadProjects());
  }

  /// "Vazgeç" while waiting, or "Başka hesapla gir" after signing in.
  /// `keepProjects`: signing in again for the registration keeps the chosen projects (the
  /// list is read again after the new sign-in).
  void _cancelLogin({bool keepProjects = false}) {
    _loginAttempt++;
    _poll?.cancel();
    unawaited(widget.backend.loginCancel());
    setState(() {
      _login = SenseLoginStatus.idle;
      _notice = null;
      _projectsError = '';
      if (!keepProjects) {
        _available = null;
        _selectedIds.clear();
      }
    });
  }

  Future<void> _copyLink() async {
    try {
      await Clipboard.setData(ClipboardData(text: _login.url));
    } catch (_) {
      return;
    }
    if (mounted) setState(() => _notice = _t('link-copied'));
  }

  // ---- Projects ----

  Future<void> _loadProjects() async {
    setState(() {
      _projectsLoading = true;
      _projectsError = '';
    });
    SenseProjectList list;
    try {
      list = await widget.backend.projects();
    } catch (_) {
      list = const SenseProjectList.error('retry');
    }
    if (!mounted) return;
    setState(() {
      _projectsLoading = false;
      if (list.ok) {
        _available = list.projects;
        _selectedIds.removeWhere((id) => !list.projects.any((p) => p.id == id));
      } else {
        _projectsError = list.error;
      }
    });
  }

  int get _projectCount => _selectedIds.length + _newProjects.length;

  List<SenseProject> get _chosenProjects => [
        for (final p in _available ?? const <SenseProject>[])
          if (_selectedIds.contains(p.id)) p,
      ];

  void _toggleProject(SenseProject project) {
    setState(() {
      if (_selectedIds.contains(project.id)) {
        _selectedIds.remove(project.id);
      } else if (_projectCount < kSenseMaxProjects) {
        _selectedIds.add(project.id);
      }
    });
  }

  /// A typed name that matches an existing project selects that project (like the panel,
  /// K-PROJE) instead of asking for a second one.
  void _addNewProject() {
    final value = _newProject.text.trim();
    if (value.isEmpty) return;
    setState(() {
      final key = senseTrLower(value);
      final existing = (_available ?? const <SenseProject>[])
          .where((p) => senseTrLower(p.name) == key);
      if (existing.isNotEmpty) {
        if (!_selectedIds.contains(existing.first.id) &&
            _projectCount < kSenseMaxProjects) {
          _selectedIds.add(existing.first.id);
        }
      } else if (!_newProjects.any((p) => senseTrLower(p) == key) &&
          _projectCount < kSenseMaxProjects) {
        _newProjects.add(value);
      }
      _newProject.clear();
    });
    _newProjectFocus.requestFocus();
  }

  // ---- Install and registration ----

  SenseInstallRequest _installRequest() => SenseInstallRequest(
        host: _host,
        controller: _controller,
        name: _name.text.trim(),
        location: _location.text.trim(),
        path: _path,
        startMenu: _startMenu,
        desktopIcon: _desktopIcon,
        printer: _printer,
      );

  SenseEnrollRequest _enrollRequest() => SenseEnrollRequest(
        name: _name.text.trim(),
        location: _location.text.trim(),
        note: _note.text.trim(),
        projectIds: [for (final p in _chosenProjects) p.id],
        newProjects: List.unmodifiable(_newProjects),
      );

  Future<void> _install() async {
    if (_busy) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    String result;
    try {
      result = await widget.backend.install(_installRequest());
    } catch (e) {
      result = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _installing = false;
      if (result.isEmpty) {
        _installed = true;
        _step = SenseInstallStep.register;
      } else if (result == 'cancelled') {
        _error = _t('error-cancelled');
      } else {
        final known = kSenseInstallTr['error-$result'];
        _error = known ?? '${_t('error-failed')}\n$result';
      }
    });
    if (result.isEmpty) await _enroll();
  }

  Future<void> _enroll() async {
    if (_enrolling) return;
    setState(() {
      _enrolling = true;
      _enrollError = '';
    });
    SenseEnrollResult result;
    try {
      result = await widget.backend.enroll(_enrollRequest());
    } catch (_) {
      result = const SenseEnrollResult.error('other');
    }
    if (!mounted) return;
    setState(() {
      _enrolling = false;
      if (result.ok) {
        _registered = true;
        _enrolledProjects = result.projects;
        _step = SenseInstallStep.done;
      } else {
        _enrollError = result.error;
        if (senseEnrollAction(result.error) == SenseEnrollAction.wait) {
          _startWait();
        }
      }
    });
  }

  void _startWait() {
    _waitTimer?.cancel();
    _waitLeft = kSenseRetryAfterSeconds;
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _waitLeft--);
      if (_waitLeft <= 0) timer.cancel();
    });
  }

  /// Registration after installing, from the summary ("Panele kaydet") or a new sign-in.
  void _registerAgain() {
    _go(SenseInstallStep.register);
    unawaited(_enroll());
  }

  /// `token_invalid` / `install_scope` / `device_mismatch`: sign in again (new install token for
  /// this computer's ID), then register.
  void _reloginForRegister() {
    _cancelLogin(keepProjects: true);
    _go(SenseInstallStep.account);
  }

  /// `validation` / `project_not_found`: fix the details or pick projects again, then register.
  void _editForRegister() {
    unawaited(_loadProjects());
    _go(SenseInstallStep.info);
  }

  /// The computer is installed; it shows up in the panel as waiting for approval.
  void _skipRegister() => setState(() {
        _registered = false;
        _waitTimer?.cancel();
        _step = SenseInstallStep.done;
      });

  void _close() {
    // After installing, leave through `finish` so a Host drops the sign-in (K-KAYIT-b).
    if (_installed) {
      widget.backend.finish(false);
    } else {
      widget.onClose?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: SenseTokens.font,
      scaffoldBackgroundColor: SenseTokens.black,
      colorScheme: const ColorScheme.dark(
        primary: SenseTokens.white,
        onPrimary: SenseTokens.black,
        surface: SenseTokens.black,
        error: SenseTokens.error,
      ),
    );
    return Theme(
      data: base.copyWith(
        textTheme: base.textTheme.apply(
          fontFamily: SenseTokens.font,
          bodyColor: SenseTokens.white,
          displayColor: SenseTokens.white,
        ),
        textSelectionTheme: const TextSelectionThemeData(
            cursorColor: SenseTokens.white,
            selectionColor: SenseTokens.accent2),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: SenseTokens.font,
          fontFamilyFallback: SenseTokens.fontFallback,
          fontWeight: FontWeight.w300,
          fontSize: 14,
          color: SenseTokens.white,
        ),
        child: Material(
          color: SenseTokens.black,
          child: Column(
            children: [
              _titleBar(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sidebar(),
                    Expanded(child: _body()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _titleBar() {
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: SenseTokens.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => widget.onDragStart?.call(),
              child: Center(
                child: Text(_t('window-title'),
                    style: const TextStyle(
                        fontSize: 11, color: SenseTokens.muted)),
              ),
            ),
          ),
          Tooltip(
            message: _t('close'),
            child: InkWell(
              key: const Key('sense-window-close'),
              onTap: _busy ? null : _close,
              child: const SizedBox(
                width: 46,
                height: 34,
                child: Icon(Icons.close, size: 16, color: SenseTokens.muted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar() {
    const steps = [
      SenseInstallStep.account,
      SenseInstallStep.role,
      SenseInstallStep.info,
      SenseInstallStep.summary,
    ];
    const labels = ['step-account', 'step-role', 'step-info', 'step-summary'];
    return Container(
      width: 230,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: SenseTokens.line)),
      ),
      child: ClipRect(
        child: Stack(
          children: [
            // Light accent at the bottom, like the prototype's blurred glow.
            Positioned(
              left: -60,
              right: -60,
              bottom: -120,
              height: 260,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        SenseTokens.accent1.withAlpha(190),
                        SenseTokens.accent2.withAlpha(70),
                        SenseTokens.black.withAlpha(0),
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: widget.icon ??
                            SvgPicture.asset('assets/icon.svg',
                                width: 24, height: 24),
                      ),
                      const SizedBox(width: 10),
                      // Sense Remote: dar kenar çubuğunda (185 px) taşmasın.
                      const Flexible(
                        child: Text.rich(
                          TextSpan(children: [
                            TextSpan(
                                text: 'Sense',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                            TextSpan(
                                text: ' Remote',
                                style: TextStyle(fontWeight: FontWeight.w200)),
                          ]),
                          style: TextStyle(fontSize: 16),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 34),
                  for (var i = 0; i < steps.length; i++)
                    _stepItem(i + 1, _t(labels[i]), steps[i]),
                  const Spacer(),
                  Text('${_t('version')} ${widget.version}',
                      style: const TextStyle(
                          fontSize: 11, color: SenseTokens.dim)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepItem(int number, String label, SenseInstallStep step) {
    final current = step == _step;
    final done = step.index < _step.index;
    final Color textColor = current
        ? SenseTokens.white
        : done
            ? SenseTokens.soft
            : SenseTokens.muted;
    final BoxDecoration circle = current
        ? const BoxDecoration(color: SenseTokens.white, shape: BoxShape.circle)
        : done
            ? const BoxDecoration(
                gradient: SenseTokens.gradient, shape: BoxShape.circle)
            : BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF2F2F38)));
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: current ? SenseTokens.white.withAlpha(10) : null,
        borderRadius: BorderRadius.circular(SenseTokens.radius),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: circle,
            child: done
                ? const Icon(Icons.check, size: 13, color: SenseTokens.white)
                : Text('$number',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w300,
                        color:
                            current ? SenseTokens.black : SenseTokens.muted)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, color: textColor)),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final Widget page;
    switch (_step) {
      case SenseInstallStep.account:
        page = _accountPage();
        break;
      case SenseInstallStep.role:
        page = _rolePage();
        break;
      case SenseInstallStep.info:
        page = _infoPage();
        break;
      case SenseInstallStep.summary:
        page = _summaryPage();
        break;
      case SenseInstallStep.register:
        page = _registerPage();
        break;
      case SenseInstallStep.done:
        page = _donePage();
        break;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 24, 34, 24),
      child: page,
    );
  }

  Widget _heading(String a, String b, {bool boldFirst = false}) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(
            text: a,
            style: TextStyle(
                fontWeight: boldFirst ? FontWeight.w700 : FontWeight.w200)),
        TextSpan(
            text: b,
            style: TextStyle(
                fontWeight: boldFirst ? FontWeight.w200 : FontWeight.w700)),
      ]),
      style: const TextStyle(fontSize: 24, letterSpacing: -0.4),
    );
  }

  Widget _lead(String text) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 20),
        child: Text(text,
            style: const TextStyle(fontSize: 13, color: SenseTokens.muted)),
      );

  /// Page layout: scrollable content with the buttons pinned at the bottom.
  Widget _page(List<Widget> content, List<Widget> footer) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: content,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(children: footer),
      ],
    );
  }

  Widget _primaryButton(String label, VoidCallback? onPressed, {Key? key}) {
    return FilledButton(
      key: key,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: SenseTokens.white,
        foregroundColor: SenseTokens.black,
        disabledBackgroundColor: SenseTokens.white.withAlpha(77),
        disabledForegroundColor: SenseTokens.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SenseTokens.radius)),
        textStyle: const TextStyle(
            fontFamily: SenseTokens.font,
            fontFamilyFallback: SenseTokens.fontFallback,
            fontWeight: FontWeight.w600,
            fontSize: 14),
      ),
      child: Text(label),
    );
  }

  Widget _secondaryButton(String label, VoidCallback? onPressed, {Key? key}) {
    return OutlinedButton(
      key: key,
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: SenseTokens.soft,
        side: const BorderSide(color: SenseTokens.border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SenseTokens.radius)),
        textStyle: const TextStyle(
            fontFamily: SenseTokens.font,
            fontFamilyFallback: SenseTokens.fontFallback,
            fontWeight: FontWeight.w400,
            fontSize: 14),
      ),
      child: Text(label),
    );
  }

  Widget _textButton(String label, VoidCallback? onPressed, {Key? key}) {
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: SenseTokens.soft,
        textStyle: const TextStyle(
            fontFamily: SenseTokens.font,
            fontFamilyFallback: SenseTokens.fontFallback,
            fontWeight: FontWeight.w400,
            fontSize: 13),
      ),
      child: Text(label),
    );
  }

  Widget _errorRow(String text, {Key? key}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 16, color: SenseTokens.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              key: key,
              style: const TextStyle(fontSize: 12, color: SenseTokens.error)),
        ),
      ],
    );
  }

  Widget _statusLine(IconData icon, String text, {Key? key}) {
    return Row(
      children: [
        Icon(icon, size: 14, color: SenseTokens.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              key: key,
              style: const TextStyle(fontSize: 12, color: SenseTokens.muted)),
        ),
      ],
    );
  }

  Widget _progress(String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(
            minHeight: 2,
            color: SenseTokens.white,
            backgroundColor: SenseTokens.border),
        const SizedBox(height: 8),
        Text(text,
            style: const TextStyle(fontSize: 12, color: SenseTokens.soft)),
      ],
    );
  }

  // ---- Step 1: Sense sign-in ----

  Widget _accountPage() {
    final s = _login;
    final content = <Widget>[
      _heading(_t('account-title-a'), _t('account-title-b'), boldFirst: true),
      _lead(_t('account-lead')),
    ];
    if (s.isDone) {
      content.add(_accountRow(s));
    } else if (s.isWaiting) {
      content.add(_pairingPanel(s));
    } else if (s.isRequesting) {
      // A still icon (no endless animation): the wizard waits at most a few seconds here.
      content.add(_statusLine(Icons.sync, _t('requesting'),
          key: const Key('sense-login-requesting')));
    } else {
      if (s.isFailed) {
        final text = s.error == 'timeout'
            ? _t('login-timeout')
            : [_t('login-failed'), if (s.detail.isNotEmpty) s.detail]
                .join('\n');
        content.add(Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _errorRow(text, key: const Key('sense-login-error')),
        ));
      }
      final label = !s.isFailed
          ? _t('google-sign-in')
          : s.error == 'timeout'
              ? _t('new-code')
              : _t('retry');
      content.add(Align(
        alignment: Alignment.centerLeft,
        child: _googleButton(label),
      ));
      content.add(Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(_t('sign-in-note'),
            style: const TextStyle(fontSize: 11, color: SenseTokens.dim)),
      ));
    }
    return _page(content, [
      Expanded(
        child: Text(_t('domain-hint'),
            style: const TextStyle(fontSize: 11, color: SenseTokens.dim)),
      ),
      const SizedBox(width: 12),
      _primaryButton(
          _t('next'),
          !s.isDone
              ? null
              : _installed
                  ? _registerAgain
                  : () => _go(SenseInstallStep.role),
          key: const Key('sense-next')),
    ]);
  }

  Widget _googleButton(String label) {
    return FilledButton.icon(
      key: const Key('sense-login'),
      onPressed: _startLogin,
      icon: SvgPicture.string(_googleLogo, width: 18, height: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: SenseTokens.white,
        foregroundColor: SenseTokens.black,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SenseTokens.radius)),
        textStyle: const TextStyle(
            fontFamily: SenseTokens.font,
            fontFamilyFallback: SenseTokens.fontFallback,
            fontWeight: FontWeight.w500,
            fontSize: 14),
      ),
    );
  }

  /// The code the panel's approval page also shows (3+3, like `ClientApprove.tsx`). The browser
  /// opens only when asked, so the code is on screen before the approval page.
  Widget _pairingPanel(SenseLoginStatus s) {
    final code = s.pairingCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (code.isNotEmpty)
          Container(
            key: const Key('sense-pairing'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SenseTokens.radiusCard),
              border: Border.all(color: SenseTokens.border),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  SenseTokens.accent1.withAlpha(90),
                  SenseTokens.accent2.withAlpha(45),
                ],
              ),
            ),
            child: Column(
              children: [
                Text(_t('pairing-label'),
                    style: const TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.2,
                        color: SenseTokens.muted)),
                const SizedBox(height: 6),
                Semantics(
                  container: true,
                  label: _t('pairing-spoken') + spokenSensePairingCode(code),
                  excludeSemantics: true,
                  child: Text(
                    formatSensePairingCode(code),
                    key: const Key('sense-pairing-code'),
                    style: const TextStyle(
                      fontSize: 44,
                      height: 1.15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 5,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(_t('pairing-hint'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12, color: SenseTokens.soft)),
              ],
            ),
          ),
        const SizedBox(height: 16),
        Row(
          children: [
            _primaryButton(
                _t('open-browser'), () => widget.backend.openUrl(s.url),
                key: const Key('sense-open-browser')),
            const SizedBox(width: 6),
            _textButton(_t('copy-link'), _copyLink,
                key: const Key('sense-copy-link')),
            const Spacer(),
            _textButton(_t('cancel'), _cancelLogin,
                key: const Key('sense-login-cancel')),
          ],
        ),
        const SizedBox(height: 12),
        _statusLine(Icons.schedule, _notice ?? _t('waiting')),
      ],
    );
  }

  Widget _accountRow(SenseLoginStatus s) {
    final source = s.displayName.isNotEmpty ? s.displayName : s.email.split('@').first;
    final initials = source
        .split(RegExp(r'[\s._-]+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part.characters.first.toUpperCase())
        .join();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: const Key('sense-account'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SenseTokens.radius),
            border: Border.all(color: SenseTokens.border),
            color: SenseTokens.field,
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    gradient: SenseTokens.gradient, shape: BoxShape.circle),
                child: Text(initials,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(s.email,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14)),
              ),
              const Icon(Icons.check, size: 14, color: SenseTokens.soft),
              const SizedBox(width: 4),
              Text(_t('verified'),
                  style:
                      const TextStyle(fontSize: 12, color: SenseTokens.soft)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        _textButton(_t('other-account'), _cancelLogin,
            key: const Key('sense-other-account')),
      ],
    );
  }

  // ---- Step 2: role ----

  Widget _rolePage() {
    final any = _host || _controller;
    final summary = !any
        ? _t('no-role')
        : senseRoleLabel(_host, _controller) +
            (_host && _controller ? _t('both-desc') : '.');
    return _page([
      _heading(_t('role-title-a'), _t('role-title-b')),
      _lead(_t('role-lead')),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _roleCard(
              key: const Key('sense-role-host'),
              title: 'Host',
              description: _t('host-desc'),
              icon: Icons.desktop_windows_outlined,
              selected: _host,
              onTap: () => setState(() => _host = !_host),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _roleCard(
              key: const Key('sense-role-controller'),
              title: 'Controller',
              description: _t('controller-desc'),
              icon: Icons.mouse_outlined,
              selected: _controller,
              onTap: () => setState(() => _controller = !_controller),
            ),
          ),
        ],
      ),
      Container(
        key: const Key('sense-role-summary'),
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(SenseTokens.radius),
          border: Border.all(color: const Color(0xFF2F2F38)),
        ),
        child: Text(summary,
            style: const TextStyle(fontSize: 12, color: SenseTokens.soft)),
      ),
    ], [
      _secondaryButton(_t('back'), () => _go(SenseInstallStep.account),
          key: const Key('sense-back')),
      const Spacer(),
      _primaryButton(
          _t('next'), any ? () => _go(SenseInstallStep.info) : null,
          key: const Key('sense-next')),
    ]);
  }

  Widget _roleCard({
    required Key key,
    required String title,
    required String description,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Semantics(
      key: key,
      button: true,
      selected: selected,
      label: title,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SenseTokens.radiusCard),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SenseTokens.radiusCard),
            border: Border.all(
                color: selected ? SenseTokens.white : SenseTokens.border),
            color: selected ? null : SenseTokens.field,
            gradient: selected
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      SenseTokens.accent1.withAlpha(115),
                      SenseTokens.accent2.withAlpha(64),
                    ],
                  )
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 30, color: SenseTokens.white),
                  const Spacer(),
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: selected ? SenseTokens.white : null,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                          color: selected
                              ? SenseTokens.white
                              : SenseTokens.border),
                    ),
                    child: selected
                        ? const Icon(Icons.check,
                            size: 13, color: SenseTokens.black)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(description,
                  style:
                      const TextStyle(fontSize: 12, color: SenseTokens.text3)),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Step 3: computer info ----

  InputDecoration _inputDecoration(String hint, {Widget? suffix}) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(SenseTokens.radius),
        borderSide: BorderSide(color: color));
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: SenseTokens.dim, fontSize: 13),
      isDense: true,
      filled: true,
      fillColor: SenseTokens.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
      enabledBorder: border(SenseTokens.border),
      focusedBorder: border(SenseTokens.white),
      border: border(SenseTokens.border),
      suffixIcon: suffix,
    );
  }

  Widget _field(String label, Widget input, {String? extra}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(children: [
              TextSpan(text: label),
              if (extra != null)
                TextSpan(
                    text: ' $extra',
                    style: const TextStyle(color: SenseTokens.dim)),
            ]),
            style: const TextStyle(fontSize: 12, color: SenseTokens.muted),
          ),
          const SizedBox(height: 6),
          input,
        ],
      ),
    );
  }

  Widget _textInput(TextEditingController controller, String hint, int max,
      {Key? key,
      FocusNode? focusNode,
      ValueChanged<String>? onSubmitted,
      Widget? suffix}) {
    return TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w300),
      inputFormatters: [LengthLimitingTextInputFormatter(max)],
      decoration: _inputDecoration(hint, suffix: suffix),
    );
  }

  Widget _infoPage() {
    final canContinue = _name.text.trim().isNotEmpty;
    return _page([
      _heading(_t('info-title-a'), _t('info-title-b')),
      _lead(_t('info-lead')),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _field(
                _t('name'),
                _textInput(_name, _t('name-hint'), kSenseMaxName,
                    key: const Key('sense-name'))),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _field(
                _t('location'),
                _textInput(_location, _t('location-hint'), kSenseMaxLocation,
                    key: const Key('sense-location'))),
          ),
        ],
      ),
      _projectsField(),
      _field(
          _t('note'),
          _textInput(_note, _t('note-hint'), kSenseMaxNote,
              key: const Key('sense-note'))),
    ], [
      // After installing the role is fixed: no way back to the role step.
      if (!_installed)
        _secondaryButton(_t('back'), () => _go(SenseInstallStep.role)),
      const Spacer(),
      _primaryButton(
          _t('next'),
          canContinue
              ? () {
                  // A project typed but not confirmed with Enter still counts.
                  _addNewProject();
                  _go(SenseInstallStep.summary);
                }
              : null,
          key: const Key('sense-next')),
    ]);
  }

  Widget _projectsField() {
    final available = _available ?? const <SenseProject>[];
    final chips = <Widget>[
      for (final p in available)
        _projectChip(
          key: Key('sense-project-${p.id}'),
          label: p.name,
          selected: _selectedIds.contains(p.id),
          onTap: () => _toggleProject(p),
        ),
      for (final name in _newProjects)
        _projectChip(
          key: Key('sense-new-project-$name'),
          label: name,
          selected: true,
          isNew: true,
          onRemove: () => setState(() => _newProjects.remove(name)),
        ),
    ];
    Widget? status;
    if (_projectsLoading) {
      status = _statusLine(Icons.hourglass_empty, _t('projects-loading'));
    } else if (_projectsError.isNotEmpty) {
      status = Row(
        children: [
          Expanded(
            child: _errorRow(
                kSenseInstallTr['projects-error-$_projectsError'] ??
                    _t('projects-error'),
                key: const Key('sense-projects-error')),
          ),
          _textButton(_t('retry'), _loadProjects,
              key: const Key('sense-projects-retry')),
        ],
      );
    } else if (chips.isEmpty) {
      status = _statusLine(Icons.info_outline, _t('projects-empty'));
    }
    final full = _projectCount >= kSenseMaxProjects;
    return _field(
      _t('projects'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chips.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          if (status != null) ...[
            if (chips.isNotEmpty) const SizedBox(height: 10),
            status,
          ],
          const SizedBox(height: 10),
          _textInput(_newProject, _t('project-hint'), kSenseMaxProject,
              key: const Key('sense-project'),
              focusNode: _newProjectFocus,
              onSubmitted: (_) => _addNewProject(),
              suffix: IconButton(
                key: const Key('sense-project-add'),
                tooltip: _t('add-project'),
                icon: const Icon(Icons.add, size: 18),
                color: SenseTokens.muted,
                onPressed: _addNewProject,
              )),
          if (full)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_t('projects-max'),
                  style:
                      const TextStyle(fontSize: 11, color: SenseTokens.dim)),
            ),
        ],
      ),
      extra: _t('projects-multi'),
    );
  }

  Widget _projectChip({
    required Key key,
    required String label,
    required bool selected,
    bool isNew = false,
    VoidCallback? onTap,
    VoidCallback? onRemove,
  }) {
    return Semantics(
      key: key,
      button: onTap != null,
      selected: selected,
      label: isNew ? '$label (${_t('new-tag')})' : label,
      excludeSemantics: onRemove == null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.fromLTRB(12, 6, onRemove != null ? 4 : 12, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? SenseTokens.white : SenseTokens.border),
            color: selected ? null : SenseTokens.field,
            gradient: selected
                ? LinearGradient(colors: [
                    SenseTokens.accent1.withAlpha(115),
                    SenseTokens.accent2.withAlpha(64),
                  ])
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected && !isNew) ...[
                const Icon(Icons.check, size: 13, color: SenseTokens.white),
                const SizedBox(width: 5),
              ],
              Text(label, style: const TextStyle(fontSize: 12)),
              if (isNew) ...[
                const SizedBox(width: 6),
                Text(_t('new-tag'),
                    style: const TextStyle(
                        fontSize: 10, color: SenseTokens.soft)),
              ],
              if (onRemove != null) ...[
                const SizedBox(width: 2),
                Tooltip(
                  message: _t('remove-project'),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onRemove,
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.close,
                          size: 13, color: SenseTokens.muted),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---- Step 4: summary ----

  Widget _summaryPage() {
    final r = _installRequest();
    final note = _note.text.trim();
    final controllerOnly = _controller && !_host;
    String orNone(String v) => v.isEmpty ? _t('none') : v;
    final projects = [
      for (final p in _chosenProjects) p.name,
      for (final name in _newProjects) '$name (${_t('new-tag')})',
    ].join(', ');
    final rows = <(String, String)>[
      (_t('account'), orNone(_login.email)),
      (_t('role'), senseRoleLabel(_host, _controller)),
      (_t('name'), r.name),
      (_t('projects'), orNone(projects)),
      (_t('location'), orNone(r.location)),
      if (note.isNotEmpty) (_t('note').split(' (').first, note),
      (_t('update'), _t('update-value')),
      (_t('password'), _t('password-value')),
    ];
    return _page([
      _heading(_t('summary-title'), '', boldFirst: true),
      _lead(_t(controllerOnly ? 'summary-lead-controller' : 'summary-lead')),
      Container(
        key: const Key('sense-summary'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SenseTokens.line),
        ),
        child: Column(
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(row.$1,
                          style: const TextStyle(
                              fontSize: 13, color: SenseTokens.muted)),
                    ),
                    Expanded(
                        child: Text(row.$2,
                            style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      if (!_installed)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('sense-advanced'),
          onPressed:
              _installing ? null : () => setState(() => _advanced = !_advanced),
          style: TextButton.styleFrom(foregroundColor: SenseTokens.muted),
          icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more,
              size: 18),
          label: Text(_t('advanced'), style: const TextStyle(fontSize: 12)),
        ),
      ),
      if (_advanced && !_installed) _advancedOptions(),
      if (_installing)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _progress(_t('installing')),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _errorRow(_error!, key: const Key('sense-error')),
        ),
    ], [
      _secondaryButton(
          _t('back'), _installing ? null : () => _go(SenseInstallStep.info)),
      const Spacer(),
      // Already installed (details fixed after a refused registration): register only.
      _installed
          ? _primaryButton(_t('register-save'), _registerAgain,
              key: const Key('sense-register-save'))
          : _primaryButton(_t('install'), _installing ? null : _install,
              key: const Key('sense-install')),
    ]);
  }

  Widget _advancedOptions() {
    Widget check(String label, bool value, ValueChanged<bool> onChanged) {
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _installing ? null : () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Checkbox(
                value: value,
                visualDensity:
                    const VisualDensity(horizontal: -4, vertical: -4),
                side: const BorderSide(color: SenseTokens.border),
                onChanged: _installing ? null : (v) => onChanged(v ?? false),
              ),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SenseTokens.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_t('install-path'),
              style: const TextStyle(fontSize: 12, color: SenseTokens.muted)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(_path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
              if (widget.onPickPath != null)
                TextButton(
                  onPressed: _installing
                      ? null
                      : () async {
                          final picked = await widget.onPickPath!(_path);
                          if (picked != null && mounted) {
                            setState(() => _path = picked);
                          }
                        },
                  style:
                      TextButton.styleFrom(foregroundColor: SenseTokens.white),
                  child: Text(_t('change-path')),
                ),
            ],
          ),
          const SizedBox(height: 6),
          check(_t('start-menu'), _startMenu,
              (v) => setState(() => _startMenu = v)),
          check(_t('desktop-icon'), _desktopIcon,
              (v) => setState(() => _desktopIcon = v)),
          check(_t('printer'), _printer, (v) => setState(() => _printer = v)),
        ],
      ),
    );
  }

  // ---- Panel registration (after installing) ----

  /// The one action that can fix the panel's answer (contract `EnrollErrorCode`).
  Widget? _registerAction() {
    switch (senseEnrollAction(_enrollError)) {
      case SenseEnrollAction.relogin:
        return _primaryButton(_t('relogin'), _reloginForRegister,
            key: const Key('sense-relogin-register'));
      case SenseEnrollAction.edit:
        return _primaryButton(_t('edit-details'), _editForRegister,
            key: const Key('sense-edit-register'));
      case SenseEnrollAction.wait:
        return _primaryButton(
            _waitLeft > 0
                ? '${_t('retry')} ($_waitLeft ${_t('seconds-short')})'
                : _t('retry'),
            _waitLeft > 0 ? null : _enroll,
            key: const Key('sense-retry-register'));
      case SenseEnrollAction.retry:
        return _primaryButton(_t('retry'), _enroll,
            key: const Key('sense-retry-register'));
      case SenseEnrollAction.none:
        return null;
    }
  }

  Widget _registerPage() {
    final failed = !_enrolling && _enrollError.isNotEmpty;
    final action = failed ? _registerAction() : null;
    return _page([
      _heading(_t('register-title-a'), _t('register-title-b')),
      const SizedBox(height: 20),
      if (_enrolling) _progress(_t('registering')),
      if (failed) ...[
        Text(_t('register-failed'),
            key: const Key('sense-register-failed'),
            style: const TextStyle(fontSize: 14)),
        const SizedBox(height: 10),
        _errorRow(
            kSenseInstallTr['enroll-$_enrollError'] ?? _t('enroll-other'),
            key: const Key('sense-enroll-error')),
      ],
    ], [
      const Spacer(),
      if (failed) ...[
        _secondaryButton(_t('skip-register'), _skipRegister,
            key: const Key('sense-skip-register')),
        if (action != null) ...[const SizedBox(width: 10), action],
      ],
    ]);
  }

  // ---- Done ----

  String _doneText() {
    final lines = <String>[_t('done-lead')];
    if (!_registered) {
      lines.add(_t('done-pending'));
    } else if (_enrolledProjects.isEmpty) {
      lines.add(_t('done-panel-none'));
    } else {
      final key = _enrolledProjects.length == 1
          ? 'done-panel-project'
          : 'done-panel-projects';
      lines.add(_t(key).replaceAll('{projects}', _enrolledProjects.join(', ')));
    }
    if (_host) lines.add(_t('done-lead-locked'));
    return lines.join(' ');
  }

  Widget _donePage() {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                      gradient: SenseTokens.gradient, shape: BoxShape.circle),
                  child: const Icon(Icons.check,
                      size: 30, color: SenseTokens.white),
                ),
                const SizedBox(height: 16),
                _heading(_t('done-title'), '', boldFirst: true),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Text(
                    _doneText(),
                    key: const Key('sense-done'),
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 13, color: SenseTokens.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            const Spacer(),
            _secondaryButton(_t('close'), () => widget.backend.finish(false),
                key: const Key('sense-finish-close')),
            const SizedBox(width: 10),
            _primaryButton(_t('open-app'), () => widget.backend.finish(true),
                key: const Key('sense-finish-open')),
          ],
        ),
      ],
    );
  }
}
