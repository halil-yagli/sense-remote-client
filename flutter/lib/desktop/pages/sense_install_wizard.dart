// Sense Remote: Sense setup wizard (prototype Calisma/prototip/kurulum.html).
// Pure UI: every platform call comes in through callbacks, so it runs in widget tests.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'sense_install_strings.dart';

String _t(String key) => senseInstallText(key);

/// Limits match `src/sense.rs` (`SetupInfo::normalized`).
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

enum SenseInstallStep { account, role, info, summary, done }

class SenseInstallRequest {
  const SenseInstallRequest({
    required this.host,
    required this.controller,
    required this.name,
    required this.projects,
    required this.location,
    required this.note,
    required this.path,
    required this.startMenu,
    required this.desktopIcon,
    required this.printer,
  });

  final bool host;
  final bool controller;
  final String name;
  final List<String> projects;
  final String location;
  final String note;
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

  String get infoJson => jsonEncode({
        'name': name,
        'projects': projects,
        'location': location,
        'note': note,
      });
}

String senseRoleLabel(bool host, bool controller) => host && controller
    ? 'Host + Controller'
    : host
        ? 'Host'
        : controller
            ? 'Controller'
            : _t('none');

/// Returns "" on success, "cancelled" when the user declined, otherwise an error.
typedef SenseInstallCallback = Future<String> Function(
    SenseInstallRequest request);

class SenseInstallWizard extends StatefulWidget {
  const SenseInstallWizard({
    super.key,
    required this.initialPath,
    required this.onInstall,
    required this.onFinish,
    this.initialStartMenu = true,
    this.initialDesktopIcon = true,
    this.initialPrinter = false,
    this.onPickPath,
    this.onClose,
    this.onDragStart,
    this.version = '1',
    this.icon,
  });

  final String initialPath;
  final bool initialStartMenu;
  final bool initialDesktopIcon;
  final bool initialPrinter;
  final SenseInstallCallback onInstall;

  /// After "Kuruldu": `true` opens the installed app.
  final void Function(bool openApp) onFinish;
  final Future<String?> Function(String current)? onPickPath;
  final VoidCallback? onClose;
  final VoidCallback? onDragStart;
  final String version;
  final Widget? icon;

  @override
  State<SenseInstallWizard> createState() => _SenseInstallWizardState();
}

class _SenseInstallWizardState extends State<SenseInstallWizard> {
  // The account step stays disabled until the panel exists (wave 3).
  SenseInstallStep _step = SenseInstallStep.role;
  bool _host = false;
  bool _controller = false;
  final _name = TextEditingController();
  final _project = TextEditingController();
  final _location = TextEditingController();
  final _note = TextEditingController();
  final _projectFocus = FocusNode();
  final List<String> _projects = [];
  late String _path = widget.initialPath;
  late bool _startMenu = widget.initialStartMenu;
  late bool _desktopIcon = widget.initialDesktopIcon;
  late bool _printer = widget.initialPrinter;
  bool _advanced = false;
  bool _installing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
  }

  @override
  void dispose() {
    _name.dispose();
    _project.dispose();
    _location.dispose();
    _note.dispose();
    _projectFocus.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _go(SenseInstallStep step) => setState(() {
        _step = step;
        _error = null;
      });

  void _addProject() {
    final value = _project.text.trim();
    if (value.isEmpty) return;
    setState(() {
      final exists =
          _projects.any((p) => p.toLowerCase() == value.toLowerCase());
      if (!exists && _projects.length < kSenseMaxProjects) {
        _projects.add(value);
      }
      _project.clear();
    });
    _projectFocus.requestFocus();
  }

  SenseInstallRequest _request() => SenseInstallRequest(
        host: _host,
        controller: _controller,
        name: _name.text.trim(),
        projects: List.unmodifiable(_projects),
        location: _location.text.trim(),
        note: _note.text.trim(),
        path: _path,
        startMenu: _startMenu,
        desktopIcon: _desktopIcon,
        printer: _printer,
      );

  Future<void> _install() async {
    if (_installing) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    String result;
    try {
      result = await widget.onInstall(_request());
    } catch (e) {
      result = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _installing = false;
      if (result.isEmpty) {
        _step = SenseInstallStep.done;
      } else if (result == 'cancelled') {
        _error = _t('error-cancelled');
      } else {
        final known = kSenseInstallTr['error-$result'];
        _error = known ?? '${_t('error-failed')}\n$result';
      }
    });
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
              onTap: _installing ? null : widget.onClose,
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
    final soon = step == SenseInstallStep.account;
    final current = step == _step;
    final done = !soon && step.index < _step.index;
    final Color textColor = current
        ? SenseTokens.white
        : done
            ? SenseTokens.soft
            : SenseTokens.muted;
    final BoxDecoration circle = current
        ? const BoxDecoration(
            color: SenseTokens.white, shape: BoxShape.circle)
        : done
            ? const BoxDecoration(
                gradient: SenseTokens.gradient, shape: BoxShape.circle)
            : BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF2F2F38)));
    return Opacity(
      opacity: soon ? 0.55 : 1,
      child: Container(
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
                          fontWeight:
                              current ? FontWeight.w600 : FontWeight.w300,
                          color: current
                              ? SenseTokens.black
                              : SenseTokens.muted)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 13, color: textColor)),
            ),
            if (soon)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: SenseTokens.border),
                ),
                child: Text(_t('soon'),
                    style: const TextStyle(
                        fontSize: 9, color: SenseTokens.muted)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final Widget page;
    switch (_step) {
      case SenseInstallStep.account:
      case SenseInstallStep.role:
        page = _rolePage();
        break;
      case SenseInstallStep.info:
        page = _infoPage();
        break;
      case SenseInstallStep.summary:
        page = _summaryPage();
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
      const SizedBox(height: 14),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 14, color: SenseTokens.dim),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_t('account-soon'),
                style: const TextStyle(fontSize: 11, color: SenseTokens.dim)),
          ),
        ],
      ),
    ], [
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
      _field(_t('name'),
          _textInput(_name, _t('name-hint'), kSenseMaxName,
              key: const Key('sense-name'))),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _field(
              _t('projects'),
              _textInput(_project, _t('project-hint'), kSenseMaxProject,
                  key: const Key('sense-project'),
                  focusNode: _projectFocus,
                  onSubmitted: (_) => _addProject(),
                  suffix: IconButton(
                    key: const Key('sense-project-add'),
                    tooltip: _t('add-project'),
                    icon: const Icon(Icons.add, size: 18),
                    color: SenseTokens.muted,
                    onPressed: _addProject,
                  )),
              extra: _t('projects-multi'),
            ),
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
      if (_projects.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _projects)
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: SenseTokens.border),
                    color: SenseTokens.field,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(p, style: const TextStyle(fontSize: 12)),
                      const SizedBox(width: 2),
                      InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => setState(() => _projects.remove(p)),
                        child: Tooltip(
                          message: _t('remove-project'),
                          child: const Padding(
                            padding: EdgeInsets.all(3),
                            child: Icon(Icons.close,
                                size: 13, color: SenseTokens.muted),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      _field(_t('note'),
          _textInput(_note, _t('note-hint'), kSenseMaxNote,
              key: const Key('sense-note'))),
    ], [
      _secondaryButton(_t('back'), () => _go(SenseInstallStep.role)),
      const Spacer(),
      _primaryButton(
          _t('next'),
          canContinue
              ? () {
                  // A project typed but not confirmed with Enter still counts.
                  _addProject();
                  _go(SenseInstallStep.summary);
                }
              : null,
          key: const Key('sense-next')),
    ]);
  }

  // ---- Step 4: summary ----

  Widget _summaryPage() {
    final r = _request();
    final controllerOnly = _controller && !_host;
    String orNone(String v) => v.isEmpty ? _t('none') : v;
    final rows = <(String, String)>[
      (_t('account'), _t('account-value')),
      (_t('role'), senseRoleLabel(_host, _controller)),
      (_t('name'), r.name),
      (_t('projects'), orNone(r.projects.join(', '))),
      (_t('location'), orNone(r.location)),
      if (r.note.isNotEmpty) (_t('note').split(' (').first, r.note),
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
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('sense-advanced'),
          onPressed: _installing
              ? null
              : () => setState(() => _advanced = !_advanced),
          style: TextButton.styleFrom(foregroundColor: SenseTokens.muted),
          icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more,
              size: 18),
          label: Text(_t('advanced'), style: const TextStyle(fontSize: 12)),
        ),
      ),
      if (_advanced) _advancedOptions(),
      if (_installing)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const LinearProgressIndicator(
                  minHeight: 2,
                  color: SenseTokens.white,
                  backgroundColor: SenseTokens.border),
              const SizedBox(height: 8),
              Text(_t('installing'),
                  style:
                      const TextStyle(fontSize: 12, color: SenseTokens.soft)),
            ],
          ),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline,
                  size: 16, color: SenseTokens.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_error!,
                    key: const Key('sense-error'),
                    style: const TextStyle(
                        fontSize: 12, color: SenseTokens.error)),
              ),
            ],
          ),
        ),
    ], [
      _secondaryButton(_t('back'),
          _installing ? null : () => _go(SenseInstallStep.info)),
      const Spacer(),
      _primaryButton(_t('install'), _installing ? null : _install,
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
                onChanged:
                    _installing ? null : (v) => onChanged(v ?? false),
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

  // ---- Done ----

  Widget _donePage() {
    final locked = _host;
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
                Text(
                  locked
                      ? '${_t('done-lead')} ${_t('done-lead-locked')}'
                      : _t('done-lead'),
                  key: const Key('sense-done'),
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 13, color: SenseTokens.muted),
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            const Spacer(),
            _secondaryButton(_t('close'), () => widget.onFinish(false),
                key: const Key('sense-finish-close')),
            const SizedBox(width: 10),
            _primaryButton(_t('open-app'), () => widget.onFinish(true),
                key: const Key('sense-finish-open')),
          ],
        ),
      ],
    );
  }
}
