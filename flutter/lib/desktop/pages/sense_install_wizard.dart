// Sense Remote: Sense setup wizard (prototype Calisma/prototip/kurulum.html).
// Pure UI: every platform call goes through [SenseInstallBackend], so it runs in widget tests.
//
// Wave 3 (I6): step 1 is the Sense sign-in (K-GİRİŞ: the 6-digit pairing code is shown large,
// the browser opens only on request), the project list comes from the panel, and after the
// installation the computer is registered with the panel (K-KAYIT: "Yeniden dene", or skip and
// it shows up in the panel as waiting for approval).

import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'sense_install_strings.dart';
// Sense Remote: model and steps live in separate files (code review K3-6).
import 'sense_install_model.dart';
export 'sense_install_model.dart';

part 'sense_install_layout.dart';
part 'sense_install_steps_account.dart';
part 'sense_install_steps_info.dart';
part 'sense_install_steps_finish.dart';
// Sense Remote (Mac M3): the two macOS steps (Applications folder, privacy permissions).
part 'sense_install_steps_mac.dart';

String _t(String key) => senseInstallText(key);

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
    this.version = '',
    this.icon,
    this.pollInterval = const Duration(seconds: 1),
    this.mac = false,
  });

  final String initialPath;
  final SenseInstallBackend backend;
  final bool initialStartMenu;
  final bool initialDesktopIcon;
  final bool initialPrinter;
  final Future<String?> Function(String current)? onPickPath;
  final VoidCallback? onClose;
  final VoidCallback? onDragStart;

  /// Sense version number of this setup file (built-in option `sense-version`). Empty: no
  /// version line (no made-up number, design review T3-11).
  final String version;
  final Widget? icon;

  /// How often the sign-in state (and on macOS the permission state) is read.
  final Duration pollInterval;

  /// Sense Remote (Mac M3): macOS flow. Adds the Applications folder check before the
  /// sign-in and the privacy permissions after the registration; no Windows install options.
  /// A parameter (not a platform check) so the wizard stays pure UI and testable anywhere.
  final bool mac;

  @override
  State<SenseInstallWizard> createState() => _SenseInstallWizardState();
}

class _SenseInstallWizardState extends State<SenseInstallWizard> {
  late SenseInstallStep _step =
      widget.mac ? SenseInstallStep.applications : SenseInstallStep.account;

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

  // Sense Remote (Mac M3): state of the macOS steps (sense_install_steps_mac.dart).
  /// `null` until the first answer; `false` keeps the wizard on the Applications step.
  bool? _inApplications;
  bool _appsRechecked = false;
  SenseMacPermissions? _permissions;
  Timer? _permissionPoll;
  bool _permissionPolling = false;
  bool _laterWarned = false;
  bool _permissionsSkipped = false;
  bool _agentRestartFailed = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
    if (widget.mac) unawaited(_checkApplications());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _waitTimer?.cancel();
    _permissionPoll?.cancel();
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
        // Sense Remote (code review K4-9): an unknown result is an internal detail; the
        // screen shows the general text and the code goes to the log.
        final key = 'error-$result';
        final known = _t(key);
        if (known == key) {
          debugPrint('Sense Remote: install failed: $result');
          _error = _t('error-failed');
        } else {
          _error = known;
        }
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
        _step = _afterRegisterStep;
      } else {
        _enrollError = result.error;
        if (senseEnrollAction(result.error) == SenseEnrollAction.wait) {
          _startWait();
        }
      }
    });
    if (result.ok) _enterAfterRegister();
  }

  /// Sense Remote (Mac M3): macOS asks for the privacy permissions before "Kuruldu".
  SenseInstallStep get _afterRegisterStep =>
      widget.mac ? SenseInstallStep.permissions : SenseInstallStep.done;

  void _enterAfterRegister() {
    if (widget.mac) _startPermissionPoll();
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
  void _skipRegister() {
    setState(() {
      _registered = false;
      _waitTimer?.cancel();
      _step = _afterRegisterStep;
    });
    _enterAfterRegister();
  }

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


  /// setState for the step builders in the part files (extensions).
  void _update(VoidCallback fn) => setState(fn);
}
