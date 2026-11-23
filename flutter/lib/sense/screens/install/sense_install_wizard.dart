// Sense Remote: the setup wizard (YH K1–K7; prototype SENSE-REMOTE_PROTOTIP.html "Kurulum",
// images i01–i09). Pure UI: every platform call goes through [SenseInstallBackend], so it runs
// in widget tests. Built only from the component library (lib/sense/sense.dart); colours,
// sizes and durations come from the tokens.
//
// Windows: Sense hesabı → Bu bilgisayarın rolü → Bilgisayar bilgisi → Özet ve kurulum → Kuruldu.
// macOS adds "Uygulamalar klasörü" first and "macOS izinleri" before "Kuruldu".
// No dialogs (T7): the only windows are the UAC prompt and the macOS password; every error
// and warning is a box in place.

import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../sense.dart';
import '../../strings/install.dart';
import 'sense_install_model.dart';

export 'sense_install_model.dart';

part 'sense_install_layout.dart';
part 'sense_install_steps_account.dart';
part 'sense_install_steps_info.dart';
part 'sense_install_steps_finish.dart';
part 'sense_install_steps_mac.dart';
part 'sense_install_steps_upgrade.dart';

String _t(String key, [Map<String, String> args = const {}]) =>
    senseInstallText(key, args);

/// Window size of the setup file (YH K1).
const Size kSenseInstallSize = Size(860, 620);
const Size kSenseInstallMinSize = Size(760, 540);

/// Sense Remote (P3, B6): empty room kept free around the setup window on the screen.
const double kSenseInstallScreenMargin = 40;

/// Pure: the setup window's size and minimum size for a screen whose visible area (logical
/// px, without the taskbar) is [visible]; `null` = unknown. The window never gets bigger than
/// the screen, so the footer buttons ([Güncelle], [İleri]) stay on it (B6).
({Size size, Size min}) senseInstallWindowFor(Size? visible) {
  var size = kSenseInstallSize;
  if (visible != null && visible.width > 0 && visible.height > 0) {
    size = Size(
      size.width.clamp(0, visible.width - kSenseInstallScreenMargin).toDouble(),
      size.height.clamp(0, visible.height - kSenseInstallScreenMargin).toDouble(),
    );
  }
  final min = Size(
    kSenseInstallMinSize.width < size.width ? kSenseInstallMinSize.width : size.width,
    kSenseInstallMinSize.height < size.height ? kSenseInstallMinSize.height : size.height,
  );
  return (size: size, min: min);
}

/// Width below which the step list narrows (B6), so a window smaller than 860 wide keeps room
/// for the page and its buttons.
const double kSenseInstallNarrowWidth = 820;

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
    this.pollInterval = const Duration(seconds: 1),
    this.optionsPollInterval = kSenseOptionsPoll,
    this.mac = false,
    this.upgrade,
  });

  final String initialPath;
  final SenseInstallBackend backend;
  final bool initialStartMenu;
  final bool initialDesktopIcon;
  final bool initialPrinter;
  final Future<String?> Function(String current)? onPickPath;
  final VoidCallback? onClose;
  final VoidCallback? onDragStart;

  /// Sense version number of this setup file (built-in option `sense-version`). Empty: the
  /// sidebar shows only the system (no made-up number, T3-11).
  final String version;

  /// How often the sign-in state (and on macOS the permission state) is read (K6: every second).
  final Duration pollInterval;

  /// How often the project and location lists are read again on the details step (K4).
  final Duration optionsPollInterval;

  /// macOS flow (Applications folder, permissions, no Windows options). A parameter, not a
  /// platform check, so the wizard stays testable anywhere.
  final bool mac;

  /// Set when this computer already has a Sense role: only the upgrade screen (K7).
  final SenseUpgrade? upgrade;

  @override
  State<SenseInstallWizard> createState() => _SenseInstallWizardState();
}

class _SenseInstallWizardState extends State<SenseInstallWizard> {
  late SenseInstallStep _step = widget.upgrade != null
      ? SenseInstallStep.upgrade
      : widget.mac
          ? SenseInstallStep.applications
          : SenseInstallStep.account;

  // ---- Sign-in (K2) ----
  SenseLoginStatus _login = SenseLoginStatus.idle;
  Timer? _poll;
  bool _polling = false;
  int _loginAttempt = 0;
  bool _copied = false;

  // ---- Role (K3) ----
  bool _host = false;
  bool _controller = false;

  // ---- Details (K4) ----
  final _name = TextEditingController();
  final _note = TextEditingController();
  List<SenseProject>? _projects;
  String _optionsError = '';
  bool _optionsLoading = false;
  Timer? _optionsPoll;
  int _optionsAttempt = 0;
  final List<String> _selectedIds = [];
  String _locationId = '';

  // ---- Summary and install (K5) ----
  late String _path = widget.initialPath;
  late bool _startMenu = widget.initialStartMenu;
  late bool _desktopIcon = widget.initialDesktopIcon;
  late bool _printer = widget.initialPrinter;
  bool _advancedOpen = false;

  /// Folder shown with the "not empty" warning; pressing Kur again with it installs (T7: the
  /// second step is in place, no window).
  String? _pathWarned;
  bool _installing = false;
  String _installError = '';
  bool _installed = false;
  bool _enrolling = false;
  String _enrollError = '';
  bool _registered = false;
  List<String> _enrolledProjects = const [];
  String _enrolledLocation = '';
  int _waitLeft = 0;
  Timer? _waitTimer;

  // ---- macOS (K1, K6) ----
  bool? _inApplications;
  bool _appsRechecked = false;
  SenseMacPermissions? _permissions;
  Timer? _permissionPoll;
  bool _permissionPolling = false;
  bool _laterWarned = false;
  bool _permissionsSkipped = false;
  bool _agentRestartFailed = false;

  // ---- Upgrade (K7) ----
  bool _upgradeRunning = false;
  String _upgradeError = '';
  bool _upgradeNotNewer = false;
  bool _upgradeDone = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
    final upgrade = widget.upgrade;
    if (upgrade != null) {
      // The installed role decides which permissions macOS needs after the move.
      _host = upgrade.host;
      _controller = upgrade.controller;
    } else if (widget.mac) {
      unawaited(_checkApplications());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _optionsPoll?.cancel();
    _waitTimer?.cancel();
    _permissionPoll?.cancel();
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  /// setState for the step builders in the part files (extensions).
  void _update(VoidCallback fn) => setState(fn);

  void _go(SenseInstallStep step) {
    if (step != SenseInstallStep.info) _optionsPoll?.cancel();
    setState(() => _step = step);
    if (step == SenseInstallStep.info) _startOptionsPoll();
  }

  bool get _busy => _installing || _enrolling || _upgradeRunning;

  // ---- Sign-in ----

  bool get _loginAccepted => _login.isDone && senseCompanyEmail(_login.email);

  Future<void> _startLogin() async {
    final attempt = ++_loginAttempt;
    _poll?.cancel();
    setState(() {
      _login = const SenseLoginStatus('requesting');
      _copied = false;
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
    // K2: an account outside the company is refused here too (the panel refuses it first);
    // its sign-in is dropped at once.
    if (status.isDone && !senseCompanyEmail(status.email)) {
      unawaited(widget.backend.loginCancel());
    }
  }

  /// "Vazgeç" while waiting, "Başka hesap" after signing in. Signing in again for the
  /// registration keeps the chosen projects and location.
  void _cancelLogin() {
    _loginAttempt++;
    _poll?.cancel();
    unawaited(widget.backend.loginCancel());
    setState(() {
      _login = SenseLoginStatus.idle;
      _copied = false;
      if (!_installed) {
        _projects = null;
        _selectedIds.clear();
        _locationId = '';
      }
    });
  }

  Future<void> _copyLink() async {
    try {
      await widget.backend.copy(_login.url);
    } catch (_) {
      return;
    }
    if (mounted) setState(() => _copied = true);
  }

  void _accountNext() {
    if (!_loginAccepted) return;
    if (_installed) {
      // Signed in again for the registration: straight back to it.
      _go(SenseInstallStep.summary);
      unawaited(_enroll());
    } else {
      _go(SenseInstallStep.role);
    }
  }

  // ---- Projects and locations ----

  void _startOptionsPoll() {
    _optionsPoll?.cancel();
    unawaited(_loadOptions());
    _optionsPoll =
        Timer.periodic(widget.optionsPollInterval, (_) => _loadOptions());
  }

  Future<void> _loadOptions() async {
    if (_optionsLoading) return;
    final attempt = ++_optionsAttempt;
    _optionsLoading = true;
    if (_projects == null) setState(() {});
    SenseInstallOptions options;
    try {
      options = await widget.backend.installOptions();
    } catch (_) {
      options = const SenseInstallOptions.error('retry');
    } finally {
      _optionsLoading = false;
    }
    if (!mounted || attempt != _optionsAttempt) return;
    setState(() {
      if (!options.ok) {
        _optionsError = options.error;
        return;
      }
      _optionsError = '';
      _projects = options.projects;
      _selectedIds.removeWhere((id) => !options.projects.any((p) => p.id == id));
      if (!_locations.any((l) => l.location.id == _locationId)) _locationId = '';
    });
  }

  List<SenseProject> get _chosenProjects => [
        for (final id in _selectedIds)
          for (final p in _projects ?? const <SenseProject>[])
            if (p.id == id) p,
      ];

  /// Locations of the chosen projects, with their project (K4: the chip names the project
  /// when more than one project is chosen).
  List<({SenseProject project, SenseLocation location})> get _locations => [
        for (final p in _chosenProjects)
          for (final l in p.locations) (project: p, location: l),
      ];

  SenseLocation? get _location {
    for (final l in _locations) {
      if (l.location.id == _locationId) return l.location;
    }
    return null;
  }

  void _toggleProject(SenseProject project) {
    setState(() {
      if (_selectedIds.contains(project.id)) {
        _selectedIds.remove(project.id);
      } else if (_selectedIds.length < kSenseMaxProjects) {
        _selectedIds.add(project.id);
      }
      if (!_locations.any((l) => l.location.id == _locationId)) _locationId = '';
    });
  }

  bool get _infoReady =>
      _name.text.trim().isNotEmpty && _selectedIds.isNotEmpty && _location != null;

  void _infoNext() {
    if (!_infoReady) return;
    _go(SenseInstallStep.summary);
    // Details fixed after a refused registration: register again at once.
    if (_installed && !_registered) unawaited(_enroll());
  }

  // ---- Install and registration ----

  SenseInstallRequest _installRequest() => SenseInstallRequest(
        host: _host,
        controller: _controller,
        name: _name.text.trim(),
        location: _location?.name ?? '',
        path: _path,
        startMenu: _startMenu,
        desktopIcon: _desktopIcon,
        printer: _printer,
      );

  SenseEnrollRequest _enrollRequest() => SenseEnrollRequest(
        name: _name.text.trim(),
        locationId: _location?.id ?? '',
        locationName: _location?.name ?? '',
        note: _note.text.trim(),
        projectIds: List.unmodifiable(_selectedIds),
      );

  Future<void> _pickPath() async {
    final picked = await widget.onPickPath?.call(_path);
    if (picked == null || !mounted) return;
    setState(() {
      _path = picked;
      _pathWarned = null;
    });
    await _checkPath();
  }

  /// K5: a folder that is not empty gets an orange box in place (no window).
  Future<bool> _checkPath() async {
    if (widget.mac) return false;
    bool notEmpty;
    try {
      notEmpty = await widget.backend.folderNotEmpty(_path);
    } catch (_) {
      notEmpty = true;
    }
    if (!mounted) return false;
    setState(() {
      _pathWarned = notEmpty ? _path : null;
      if (notEmpty) _advancedOpen = true;
    });
    return notEmpty;
  }

  Future<void> _install() async {
    if (_busy || _installed) return;
    if (!widget.mac && _pathWarned != _path) {
      // First press: check the folder; a warning stops here, the second press installs.
      if (await _checkPath()) return;
    }
    setState(() {
      _installing = true;
      _installError = '';
    });
    String result;
    try {
      result = await widget.backend.install(_installRequest());
    } catch (e) {
      result = 'failed';
    }
    if (!mounted) return;
    setState(() {
      _installing = false;
      if (result.isEmpty) {
        _installed = true;
      } else if (kSenseInstallTr.containsKey('error-$result')) {
        _installError = result;
      } else {
        debugPrint('Sense Remote: install failed: $result');
        _installError = 'failed';
      }
    });
    if (result.isEmpty) await _enroll();
  }

  Future<void> _enroll() async {
    if (_enrolling) return;
    _waitTimer?.cancel();
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
        _enrolledLocation = result.location;
      } else {
        _enrollError = result.error;
        if (senseEnrollAction(result.error) == SenseEnrollAction.wait) _startWait();
      }
    });
    if (result.ok) _afterRegister();
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

  /// macOS asks for the privacy permissions before "Kuruldu".
  void _afterRegister() {
    if (widget.mac) {
      _go(SenseInstallStep.permissions);
      _startPermissionPoll();
    } else {
      _go(SenseInstallStep.done);
    }
  }

  void _skipRegister() {
    _waitTimer?.cancel();
    setState(() {
      _registered = false;
      _enrollError = '';
    });
    _afterRegister();
  }

  /// `token_invalid` / `install_scope` / `device_mismatch`: a new sign-in for this computer.
  void _reloginForRegister() {
    _cancelLogin();
    _go(SenseInstallStep.account);
  }

  /// `validation` / `project_not_found` / `location_not_found`: fix the details.
  void _editForRegister() {
    setState(() => _enrollError = '');
    _go(SenseInstallStep.info);
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
    return Theme(
      data: senseTheme(),
      child: DefaultTextStyle(
        style: SenseTextStyles.body,
        child: Material(
          color: SenseColors.bg,
          child: Column(
            children: [
              _titleBar(),
              Expanded(
                // Sense Remote (B6): the step list narrows in a narrow window.
                child: LayoutBuilder(
                  builder: (context, box) => Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _rail(narrow: box.maxWidth < kSenseInstallNarrowWidth),
                      Expanded(child: _main()),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
