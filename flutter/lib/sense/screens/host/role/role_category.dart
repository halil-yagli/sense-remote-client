// Sense Remote: "Bu bilgisayarın rolü" (YH H2, S4, K3 #34; prototype `roleBlock`).
// Host / Controller cards (installed label) → summary → "Sense hesabıyla doğrula"
// (pairing code, like the permanent password) → "Rol uygulanıyor… yönetici
// onayı" → splash → the app opens with the new role. At least one role stays;
// removing Host shows an orange warning. No window: every step is in place.
//
// Shared: the Controller settings (B4, C3 "H2 ile aynı") import
// [SenseRoleController] and [SenseRoleCategoryBody] from this file.
import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals, visibleForTesting;
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/host.dart';
import '../data/role.dart';
import '../host_format.dart';
import '../sense_password_model.dart' show sensePasswordSafeUrl;
import '../this_computer/widgets.dart';

export '../data/role.dart';

enum SenseRoleStage { idle, starting, login, applying, restarting }

/// Text of a role change error code (plan §2.6).
String senseRoleErrorText(String code) {
  switch (code) {
    case 'admin_denied':
      return SenseHostStrings.roleErrAdminDenied;
    case 'role_change_denied':
      return SenseHostStrings.roleErrDenied;
    case 'last_role':
      return SenseHostStrings.lastRole;
    case 'timeout':
      return SenseHostStrings.roleErrTimeout;
    case 'network':
      return SenseHostStrings.roleErrNetwork;
    case 'unavailable':
      return SenseHostStrings.errUnavailable;
    default:
      return SenseHostStrings.roleErrOther;
  }
}

String senseRoleName(SenseRole r) =>
    r == SenseRole.host ? SenseHostStrings.roleHost : SenseHostStrings.roleController;

/// "Host", "Controller", "Host + Controller".
String senseRoleSetName(Set<SenseRole> roles) => [
      for (final r in SenseRole.values)
        if (roles.contains(r)) senseRoleName(r),
    ].join(' + ');

int _unixNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// State of the role category.
class SenseRoleController extends ChangeNotifier {
  SenseRoleController(this.backend,
      {this.interval = const Duration(seconds: 1), int Function()? now, this.onRestart})
      : _now = now ?? _unixNow;

  final SenseRoleBackend backend;
  final Duration interval;
  final int Function() _now;

  /// Called once when the service applies the new role and the app reopens:
  /// the screen shows the splash (T8).
  final VoidCallback? onRestart;

  Set<SenseRole> current = {};
  Set<SenseRole>? _target;
  SenseRoleStage stage = SenseRoleStage.idle;
  String code = '';
  String url = '';
  int? expiresAt;

  /// Error text of the last attempt (already a UI text).
  String? error;

  Timer? _timer;
  bool _ticking = false;
  bool _disposed = false;

  Set<SenseRole> get target => _target ?? current;
  bool get changed => !setEquals(target, current);
  bool get none => target.isEmpty;
  bool get busy => stage != SenseRoleStage.idle;
  List<SenseRole> get adds => [for (final r in SenseRole.values) if (target.contains(r) && !current.contains(r)) r];
  List<SenseRole> get removes => [for (final r in SenseRole.values) if (!target.contains(r) && current.contains(r)) r];

  /// Seconds left for the approval; null when the bridge gave no end.
  int? get remaining => expiresAt == null ? null : expiresAt! - _now();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    final s = SenseRoleStatus.parse(await backend.status());
    if (_disposed) return;
    current = s.roles;
    switch (s.pendingStage) {
      case 'login':
        stage = SenseRoleStage.login;
        _start();
      case 'applying':
        stage = SenseRoleStage.applying;
        _start();
      case 'restarting':
        stage = SenseRoleStage.restarting;
      default:
        break;
    }
    _notify();
  }

  /// Card pressed: adds or removes that role from the target (only while idle).
  void toggle(SenseRole role) {
    if (busy) return;
    final next = {...target};
    if (!next.remove(role)) next.add(role);
    _target = next;
    error = null;
    _notify();
  }

  /// Vazgeç of the summary: back to the installed roles.
  void reset() {
    if (busy) return;
    _target = null;
    error = null;
    _notify();
  }

  Future<void> verify() async {
    final t = senseRoleTarget(target);
    if (busy || !changed || t == null) return;
    stage = SenseRoleStage.starting;
    error = null;
    _notify();
    final a = SenseRoleAnswer.parse(await backend.begin(t));
    if (_disposed) return;
    if (a.error != null) {
      stage = SenseRoleStage.idle;
      error = senseRoleErrorText(a.error!);
    } else {
      stage = SenseRoleStage.login;
      code = a.code;
      url = a.url;
      expiresAt = a.expiresAt;
      _start();
    }
    _notify();
  }

  void _start() => _timer ??= Timer.periodic(interval, (_) => tick());

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _fail(String code) {
    _stop();
    stage = SenseRoleStage.idle;
    this.code = '';
    url = '';
    expiresAt = null;
    error = senseRoleErrorText(code);
  }

  @visibleForTesting
  Future<void> tick() async {
    if (_ticking || _disposed) return;
    _ticking = true;
    try {
      if (stage == SenseRoleStage.login && remaining != null && remaining! <= 0) {
        await backend.cancel();
        _fail('timeout');
        return;
      }
      if (stage != SenseRoleStage.login && stage != SenseRoleStage.applying) {
        _stop();
        return;
      }
      final a = SenseRoleAnswer.parse(await backend.changeStatus());
      if (_disposed) return;
      if (a.error != null) {
        _fail(a.error!);
      } else if (a.stage == 'applying') {
        stage = SenseRoleStage.applying;
      } else if (a.stage == 'restarting') {
        _stop();
        stage = SenseRoleStage.restarting;
        onRestart?.call();
      }
    } finally {
      _ticking = false;
      _notify();
    }
  }

  /// Vazgeç while waiting for the approval: the sign-in is dropped, the chosen
  /// roles stay so the user can try again.
  Future<void> cancelVerify() async {
    if (stage != SenseRoleStage.login && stage != SenseRoleStage.starting) return;
    _stop();
    stage = SenseRoleStage.idle;
    code = '';
    url = '';
    expiresAt = null;
    _notify();
    await backend.cancel();
  }

  @override
  void dispose() {
    final open = stage == SenseRoleStage.login;
    _disposed = true;
    _stop();
    if (open) unawaited(backend.cancel());
    super.dispose();
  }
}

/// Summary on the right of the category header.
String senseRoleSummary(SenseRoleController c) =>
    c.busy ? '${senseRoleSetName(c.current)} · ${SenseHostStrings.roleChanging}' : senseRoleSetName(c.current);

/// Body of the category.
class SenseRoleCategoryBody extends StatelessWidget {
  const SenseRoleCategoryBody({super.key, required this.controller, this.mac = false});

  final SenseRoleController controller;

  /// macOS: "macOS yönetici parolası" instead of "Windows yönetici onayı".
  final bool mac;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final c = controller;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SenseHostMeta(SenseHostStrings.roleHint, color: SenseColors.textDim),
              const SizedBox(height: SenseUi.rowPadV - 1),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: SenseRoleCard(
                        key: const Key('sense-role-card-host'),
                        title: SenseHostStrings.roleHost,
                        text: SenseHostStrings.roleHostText,
                        selected: c.target.contains(SenseRole.host),
                        installed: c.current.contains(SenseRole.host),
                        onTap: c.busy ? null : () => c.toggle(SenseRole.host))),
                const SizedBox(width: SenseSizes.buttonPadH - 1),
                Expanded(
                    child: SenseRoleCard(
                        key: const Key('sense-role-card-controller'),
                        title: SenseHostStrings.roleController,
                        text: SenseHostStrings.roleControllerText,
                        selected: c.target.contains(SenseRole.controller),
                        installed: c.current.contains(SenseRole.controller),
                        onTap: c.busy ? null : () => c.toggle(SenseRole.controller))),
              ]),
              ..._tail(c),
            ],
          );
        },
      );

  List<Widget> _tail(SenseRoleController c) {
    final out = <Widget>[];
    Widget gap() => const SizedBox(height: SenseUi.rowPadV - 1);
    switch (c.stage) {
      case SenseRoleStage.idle:
        if (c.none) {
          out.add(SenseHostBox(
            key: const Key('sense-role-last'),
            level: SenseLevel.warn,
            child: SenseHostMeta(SenseHostStrings.lastRole, color: SenseColors.warn),
          ));
        } else if (c.changed) {
          final removesHost = c.removes.contains(SenseRole.host);
          final head = [
            if (c.adds.isNotEmpty) SenseHostStrings.willAdd(c.adds.map(senseRoleName).toList()),
            if (c.removes.isNotEmpty) SenseHostStrings.willRemove(c.removes.map(senseRoleName).toList()),
          ].join(' · ');
          final note = StringBuffer()
            ..write(removesHost ? SenseHostStrings.hostRemoveNote : '')
            ..write(c.adds.contains(SenseRole.host) ? SenseHostStrings.hostAddNote : '')
            ..write(c.adds.contains(SenseRole.controller) ? SenseHostStrings.controllerAddNote : '')
            ..write(SenseHostStrings.restartNote)
            ..write(SenseHostStrings.verifyNote(mac));
          out.add(SenseHostBox(
            key: const Key('sense-role-summary'),
            level: removesHost ? SenseLevel.warn : null,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SenseHostBoxTitle(head, level: removesHost ? SenseLevel.warn : null),
              const SizedBox(height: 4),
              SenseHostMeta(note.toString(), color: SenseColors.textSecondary),
              const SizedBox(height: SenseUi.rowPadV - 1),
              SenseHostActions([
                SenseButton(
                    key: const Key('sense-role-verify'),
                    label: SenseHostStrings.verifyWithSense,
                    kind: SenseButtonKind.primary,
                    onPressed: c.verify),
                SenseButton(
                    key: const Key('sense-role-reset'),
                    label: SenseCommonStrings.cancel,
                    onPressed: c.reset),
              ]),
            ]),
          ));
        }
      case SenseRoleStage.starting:
        out.add(const SenseHostBox(child: SenseHostWaitLine(SenseHostStrings.preparing)));
      case SenseRoleStage.login:
        final left = c.remaining;
        out.add(SenseHostBox(
          key: const Key('sense-role-login'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SenseHostMeta(SenseHostStrings.roleVerifyHint),
            const SizedBox(height: SenseUi.rowPadV - 1),
            SenseHostPairing(
              code: c.code,
              url: sensePasswordSafeUrl(c.url),
              waiting: left == null
                  ? SenseHostStrings.roleWaitLong
                  : SenseHostStrings.waiting(senseHostCountdown(left)),
              actions: [
                SenseButton(
                    key: const Key('sense-role-cancel'),
                    label: SenseCommonStrings.cancel,
                    size: SenseButtonSize.small,
                    onPressed: c.cancelVerify),
              ],
            ),
          ]),
        ));
      case SenseRoleStage.applying:
        out.add(SenseHostBox(
            key: const Key('sense-role-applying'),
            surface: true,
            child: SenseHostWaitLine(SenseHostStrings.roleApplying(mac))));
      case SenseRoleStage.restarting:
        out.add(const SenseHostBox(
            key: Key('sense-role-restarting'),
            surface: true,
            child: SenseHostWaitLine(SenseCommonStrings.splashOpening)));
    }
    if (c.error != null) {
      out.add(Padding(
        padding: const EdgeInsets.only(top: SenseUi.iconGap),
        child: Text(c.error!,
            key: const Key('sense-role-error'),
            style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.dangerTextSoft)),
      ));
    }
    if (out.isEmpty) return const [];
    return [gap(), ...out];
  }
}

// Prototype `.rcard` padding 14, corner 12, gap 6; `.ck` 18 px, corner 5.
const double _kCardPad = 14, _kCheck = 18, _kCheckRadius = 5;

/// One role card (`.rcard`): white frame when selected, ✓ in the corner.
class SenseRoleCard extends StatelessWidget {
  const SenseRoleCard({
    super.key,
    required this.title,
    required this.text,
    required this.selected,
    required this.installed,
    required this.onTap,
  });

  final String title;
  final String text;
  final bool selected;
  final bool installed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SenseInteractive(
        onTap: onTap,
        toggled: selected,
        semanticLabel: title,
        builder: (context, s) => SenseFocusRing(
          visible: s.focused,
          radius: SenseRadii.popup,
          child: Container(
            padding: const EdgeInsets.all(_kCardPad),
            decoration: BoxDecoration(
              color: selected ? SenseColors.bg : SenseColors.surface,
              border: Border.all(
                  color: selected
                      ? SenseColors.text
                      : (s.hovered ? SenseColors.lineStrong : SenseColors.line)),
              borderRadius: BorderRadius.circular(SenseRadii.popup),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(title,
                        style: SenseTextStyles.of(
                            size: SenseFontSize.categoryTitle, weight: SenseFontWeight.bold)),
                    if (installed) ...[
                      const SizedBox(width: SenseUi.iconGap),
                      const SenseChip(label: SenseHostStrings.installed, level: SenseLevel.ok),
                    ],
                  ]),
                  const SizedBox(height: SenseUi.iconGap),
                  Text(text,
                      style: SenseTextStyles.of(
                          size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
                ]),
              ),
              Container(
                width: _kCheck,
                height: _kCheck,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? SenseColors.text : null,
                  border: Border.all(color: selected ? SenseColors.text : SenseColors.lineStrong),
                  borderRadius: BorderRadius.circular(_kCheckRadius),
                ),
                child: selected
                    ? Text('✓',
                        style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.bg))
                    : null,
              ),
            ]),
          ),
        ),
      );
}
