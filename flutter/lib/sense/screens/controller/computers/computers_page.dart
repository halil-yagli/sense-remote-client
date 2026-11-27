// Sense Remote: binds "Bilgisayarlar" (YH C2) to the app: the device group
// model (panel lists with the `sense` extension), peer-status for the LEDs,
// the person's order (panel for tiles, this computer for the groups) and the
// connection window. The view itself is [SenseComputersView].
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../../common.dart' show connect, gFFI;
import '../../../../models/platform_model.dart' show bind;
import '../../../diag_log.dart';
import '../../../sense.dart';
import '../../../strings/controller.dart';
import '../data/grants.dart';
import '../data/peers.dart';
import 'computers_view.dart';
import 'tile_more.dart';

class SenseComputersPage extends StatefulWidget {
  const SenseComputersPage({
    super.key,
    required this.account,
    required this.grants,
    this.backend = const SensePeersBridge(),
  });

  /// E-mail of the signed-in person (keys the group order on this computer).
  final String account;
  final SenseGrantsWatch grants;
  final SensePeersBackend backend;

  @override
  State<SenseComputersPage> createState() => _SenseComputersPageState();
}

class _SenseComputersPageState extends State<SenseComputersPage> {
  late final SenseHealthCache _health = SenseHealthCache(widget.backend);
  Timer? _onlineTimer;
  Timer? _listTimer;
  Timer? _connectTimer;
  String? _connecting;

  /// Tile order the person just set, shown until the panel list has it.
  final Map<String, List<String>> _tileOrder = {};
  List<String> _groupOrder = const [];

  @override
  void initState() {
    super.initState();
    _groupOrder = _readGroupOrder();
    gFFI.groupModel.pull(force: false);
    _queryOnlines();
    // Online state of the connection server, like the stock list.
    _onlineTimer = Timer.periodic(const Duration(seconds: 20), (_) => _queryOnlines());
    // Panel state (online, "Meşgul · kişi") comes with the list.
    _listTimer = Timer.periodic(const Duration(seconds: 30), (_) => gFFI.groupModel.pull(force: true, quiet: true));
    widget.grants.addListener(_changed);
  }

  @override
  void dispose() {
    _onlineTimer?.cancel();
    _listTimer?.cancel();
    _connectTimer?.cancel();
    widget.grants.removeListener(_changed);
    _health.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _queryOnlines() {
    final ids = gFFI.groupModel.peers.map((p) => p.id).toList();
    if (ids.isNotEmpty) bind.queryOnlines(ids: ids);
  }

  List<String> _readGroupOrder() {
    try {
      final v = jsonDecode(widget.backend.readLocal(senseGroupOrderKey(widget.account)));
      return v is List ? v.whereType<String>().toList() : const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveGroupOrder(List<String> keys) async {
    setState(() => _groupOrder = keys);
    try {
      await widget.backend.writeLocal(senseGroupOrderKey(widget.account), jsonEncode(keys));
      if (mounted) SenseToast.show(context, SenseControllerStrings.orderSaved);
    } catch (_) {
      if (mounted) SenseToast.show(context, SenseControllerStrings.orderFailed);
    }
  }

  Future<void> _saveTileOrder(SenseProject p, List<String> ids) async {
    final before = _tileOrder[p.key];
    setState(() => _tileOrder[p.key] = ids);
    final byId = {for (final c in p.computers) c.id: c.deviceId};
    final deviceIds = [for (final id in ids) byId[id] ?? ''];
    // Only panel projects can keep a personal order ("Projesiz" has no id).
    final ok = p.id.isNotEmpty &&
        !deviceIds.contains('') &&
        await widget.backend.saveOrder(p.id, deviceIds);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        if (before == null) {
          _tileOrder.remove(p.key);
        } else {
          _tileOrder[p.key] = before;
        }
      });
      SenseToast.show(context, SenseControllerStrings.orderFailed);
      return;
    }
    // The panel now sends the new sort keys; keep ours until then.
    unawaited(gFFI.groupModel.pull(force: true, quiet: true));
  }

  void _connect(List<SenseProject> projects, String id, [SenseConnectKind kind = SenseConnectKind.screen]) {
    final found = senseUnique(projects).where((c) => c.id == id).toList();
    final c = found.isEmpty ? null : found.first;
    // A busy computer cannot be connected to (kabul C2): one person at a time.
    if (c != null && c.busy) {
      SenseToast.show(context, SenseControllerStrings.busyNow); // B16
      return;
    }
    if (!widget.grants.grants.can(SensePerm.connect) && widget.grants.loaded) {
      SenseToast.show(context, SenseControllerStrings.rightRevoked);
      return;
    }
    // R6: the other ways need their own grant, also checked here (not only hidden).
    if (!senseKindAllowed(kind, widget.grants.grants)) {
      SenseToast.show(context, SenseControllerStrings.rightRevoked);
      return;
    }
    // P3 (B7): the "Bağlanıyor" state ends when the window call returns (or fails, with a
    // note); the timer is only a safety net. A second click meanwhile is ignored.
    if (_connecting == id) return;
    senseUiButton('connect.${kind.name}', where: 'controller.computers'); // the kind only, no id
    _connectTimer?.cancel();
    setState(() => _connecting = id);
    _connectTimer = Timer(kSenseConnectSafety, _endConnecting);
    unawaited(_open(id, kind));
  }

  Future<void> _open(String id, SenseConnectKind kind) async {
    final ok = await senseOpenConnection(() => connect(
          context,
          id,
          isFileTransfer: kind == SenseConnectKind.fileTransfer,
          isTerminal: kind == SenseConnectKind.terminal,
          isTcpTunneling: kind == SenseConnectKind.tcpTunnel,
        ));
    if (!mounted) return;
    _connectTimer?.cancel();
    _endConnecting();
    if (!ok) SenseToast.show(context, SenseControllerStrings.connectFailed);
  }

  void _endConnecting() {
    if (mounted) setState(() => _connecting = null);
  }

  List<SenseProject> _ordered(List<SenseProject> projects) {
    final tiles = [
      for (final p in projects)
        _tileOrder[p.key] == null
            ? p
            : p.withComputers(senseApplyOrder(p.computers, _tileOrder[p.key]!, (c) => c.id)),
    ];
    return senseApplyOrder(tiles, _groupOrder, (p) => p.key);
  }

  @override
  Widget build(BuildContext context) {
    final group = gFFI.groupModel;
    return Obx(() {
      final names = group.deviceGroups.map((g) => g.name).toList();
      final peers = group.peers.toList();
      final loading = group.groupLoading.value || !group.initialized;
      final error = group.groupLoadError.value;
      return AnimatedBuilder(
        animation: group.peersModel,
        builder: (context, _) {
          final projects = _ordered(senseProjectsFrom(projectNames: names, peers: peers, order: group.senseOrder));
          final g = widget.grants;
          final state = error.isNotEmpty
              ? SenseListState.error
              : (loading && projects.isEmpty ? SenseListState.loading : SenseListState.ready);
          return SenseComputersView(
            projects: projects,
            state: state,
            now: _health.now(),
            health: _health,
            connectingId: _connecting,
            canConnect: !g.loaded || g.grants.can(SensePerm.connect),
            grantsMissing: g.loaded && !g.grants.ok,
            onConnect: (id) => _connect(projects, id),
            canFileTransfer: g.loaded && senseKindAllowed(SenseConnectKind.fileTransfer, g.grants),
            canTerminalTunnel: g.loaded && senseKindAllowed(SenseConnectKind.terminal, g.grants),
            onConnectKind: (id, kind) => _connect(projects, id, kind),
            onRetry: () => group.pull(force: true),
            onTileOrder: _saveTileOrder,
            onGroupOrder: _saveGroupOrder,
          );
        },
      );
    });
  }
}

/// Longest the "Bağlanıyor" state of a tile lasts if the window call never returns (B7).
const Duration kSenseConnectSafety = Duration(seconds: 30);

/// Runs [open]; `false` when it throws (B7: the person is told instead of a silent end).
Future<bool> senseOpenConnection(Future<void> Function() open) async {
  try {
    await open();
    return true;
  } catch (_) {
    return false;
  }
}

/// R6: whether the grants allow opening a computer in [kind] (the screen needs
/// only the connect right, checked by the caller).
bool senseKindAllowed(SenseConnectKind kind, SenseGrants g) => switch (kind) {
      SenseConnectKind.screen => true,
      SenseConnectKind.fileTransfer => g.can(SensePerm.fileTransfer),
      SenseConnectKind.terminal || SenseConnectKind.tcpTunnel => g.can(SensePerm.terminalTunnel),
    };
