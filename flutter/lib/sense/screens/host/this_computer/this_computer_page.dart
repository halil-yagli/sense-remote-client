// Sense Remote: binds the "Bu bilgisayar" page to the app (YH H1, H2). Real
// sources: connection server state, stopped service flag, video connection
// count, macOS permissions, device ID, permission options, permanent password
// bridge. Name / place (D3c), role change (D3b), who is connected (D1) and the
// incoming history go through the adapters in ../data/ until their bridge exists.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../../../common.dart';
import '../../../../models/state_model.dart';
import '../../controller/sense_home_strings.dart' show SenseHomeRole;
import '../data/host_status.dart';
import '../data/identity.dart';
import '../data/password.dart';
import '../permissions/permissions_category.dart';
import '../recent/recent_category.dart';
import '../role/role_category.dart';
import '../sense_home_mac.dart';
import '../sense_password_model.dart';
import 'this_computer_view.dart';

export 'this_computer_view.dart';

// The page polls what the panel or the service can change outside the app.
const Duration _kIdentityEvery = Duration(seconds: 15);
const Duration _kPermissionsEvery = Duration(seconds: 10);
const Duration _kClockEvery = Duration(seconds: 30);

class SenseThisComputerPage extends StatefulWidget {
  const SenseThisComputerPage({
    super.key,
    this.role = SenseHomeRole.host,
    this.onRoleRestart,
    this.onOpenSettingsPassword,
    this.identityBackend = const SenseIdentityBridge(),
    this.roleBackend = const SenseRoleBridge(),
    this.passwordBackend = const SensePasswordBridge(),
  });

  /// [SenseHomeRole.host]: password and role in the page. [SenseHomeRole.both]
  /// (B3): password opens Ayarlar, no role category.
  final SenseHomeRole role;

  /// The new role is being applied: the shell shows the splash (T8).
  final VoidCallback? onRoleRestart;
  final VoidCallback? onOpenSettingsPassword;
  final SenseIdentityBackend identityBackend;
  final SenseRoleBackend roleBackend;
  final SensePasswordBackend passwordBackend;

  @override
  State<SenseThisComputerPage> createState() => _SenseThisComputerPageState();
}

class _SenseThisComputerPageState extends State<SenseThisComputerPage> {
  bool get _host => widget.role == SenseHomeRole.host;

  late final SensePasswordController _password = SensePasswordController(widget.passwordBackend);
  late final SenseRoleController _role =
      SenseRoleController(widget.roleBackend, onRestart: widget.onRoleRestart);
  SensePasswordStatus _pwStatus = SensePasswordStatus.none;

  SenseIdentity _identity = SenseIdentity.empty;
  List<bool> _permissions = const [];
  List<SenseRecentConnection> _recent = const [];
  SenseHostLive _live = const SenseHostLive();
  int? _seenSince;
  final List<Timer> _timers = [];

  @override
  void initState() {
    super.initState();
    if (_host) {
      _password.load();
      _role.load();
    } else {
      _loadPasswordStatus();
    }
    _loadIdentity();
    _loadPermissions();
    _loadRecent();
    _timers
      ..add(Timer.periodic(_kIdentityEvery, (_) => _loadIdentity()))
      ..add(Timer.periodic(_kPermissionsEvery, (_) {
        _loadPermissions();
        _loadLive();
      }))
      ..add(Timer.periodic(_kClockEvery, (_) {
        _loadRecent();
        if (mounted) setState(() {});
      }));
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _password.dispose();
    _role.dispose();
    super.dispose();
  }

  Future<void> _loadPasswordStatus() async {
    final s = SensePasswordStatus.parse(await widget.passwordBackend.status());
    if (mounted) setState(() => _pwStatus = s);
  }

  Future<void> _loadIdentity() async {
    final i = SenseIdentity.parse(await widget.identityBackend.identity());
    if (mounted) setState(() => _identity = i);
  }

  Future<void> _loadPermissions() async {
    final p = await senseHostPermissions();
    if (mounted) setState(() => _permissions = p);
  }

  Future<void> _loadRecent() async {
    final r = senseRecentParse(await senseRecentRaw());
    if (mounted) setState(() => _recent = r);
  }

  Future<void> _loadLive() async {
    final l = SenseHostLive.parse(await senseHostLiveRaw());
    if (mounted) setState(() => _live = l);
  }

  Future<String?> _rename(String name) async {
    final e = senseIdentitySetError(await widget.identityBackend.setIdentity(name, _identity.placeId));
    if (e == null && mounted) setState(() => _identity = _identity.copyWith(name: name));
    return e;
  }

  Future<String?> _place(SensePlace place) async {
    final e = senseIdentitySetError(await widget.identityBackend.setIdentity(_identity.name, place.id));
    if (e == null && mounted) {
      setState(() => _identity = _identity.copyWith(placeId: place.id, placeName: place.name));
    }
    return e;
  }

  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Widget _view(List<SenseMacPermission> macMissing, void Function(SenseMacPermission)? openMac) {
    final stopped = Get.isRegistered<RxBool>(tag: 'stop-service') ? Get.find<RxBool>(tag: 'stop-service') : false.obs;
    return ListenableBuilder(
        listenable: gFFI.serverModel.serverId,
        builder: (context, _) => Obx(() {
      final count = stateGlobal.videoConnCount.value;
      // Until D1 says since when, the time counts from when the page saw it.
      if (count > 0) {
        _seenSince ??= _now();
      } else {
        _seenSince = null;
      }
      final since = _live.since ?? _seenSince;
      final blocked = senseMacBlocksHost(macMissing);
      return SenseThisComputerView(
        phase: senseHostPhase(
            svc: stateGlobal.svcStatus.value,
            stopped: stopped.value,
            macBlocked: blocked,
            connections: count),
        identity: _identity,
        deviceId: gFFI.serverModel.serverId.text,
        permissions: _permissions,
        recent: _recent,
        now: DateTime.now(),
        macMissing: [for (final p in macMissing) p.label],
        connections: count,
        connectedBy: _live.connectedBy,
        connectedSeconds: since == null ? null : _now() - since,
        onRetry: senseHostRetry,
        onStartService: () => start_service(true),
        onOpenPermissions: openMac == null || macMissing.isEmpty ? null : () => openMac(macMissing.first),
        onRename: _rename,
        onPlace: _place,
        passwordController: _host ? _password : null,
        passwordStatus: _pwStatus,
        onOpenSettingsPassword: widget.onOpenSettingsPassword,
        roleController: _host ? _role : null,
        mac: isMacOS,
      );
    }));
  }

  @override
  Widget build(BuildContext context) {
    if (!isMacOS) return _view(const [], null);
    return SenseMacPermissionWatch(
      role: widget.role,
      builder: (_, missing, open) => _view(missing, open),
    );
  }
}

