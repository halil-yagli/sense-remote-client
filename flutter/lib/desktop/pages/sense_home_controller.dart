// Sense Remote: Controller home (prototype Calisma/prototip/uygulama.html,
// screen 2). The computers of the signed-in account as project cards, in the
// order set in the Sense panel; a computer tagged with several projects shows
// in each of them (decision 2026-11-16, "çoklu etiket"). Data comes from the
// device group model (`/api/device-group/accessible` + `/api/peers` with the
// panel's `sense` extension, see `SensePanelOrder`).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/hbbs/hbbs.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';
import 'sense_cm_style.dart';
import 'sense_cm_widgets.dart';
import 'sense_home_connect_id.dart';
import 'sense_home_strings.dart';
import 'sense_update_view.dart'; // Sense Remote: update strip (§6)
import '../widgets/sense_version_chip.dart'; // Sense Remote: version label (§6)

typedef _T = SenseCmTokens;

class SenseHomeComputer {
  final String id;
  final String name;
  final String location;
  final bool online;

  /// Screen count; null while the panel list does not carry it (then the card
  /// shows no count instead of a guess).
  final int? displayCount;

  const SenseHomeComputer(
      {required this.id,
      required this.name,
      required this.location,
      required this.online,
      this.displayCount});
}

class SenseHomeProject {
  final String name;
  final List<SenseHomeComputer> computers;
  const SenseHomeProject(this.name, this.computers);
}

/// Case and Turkish dotted/dotless i insensitive form used by the search.
String senseHomeFold(String s) => s
    .replaceAll('İ', 'i')
    .replaceAll('I', 'i')
    .replaceAll('ı', 'i')
    .toLowerCase();

/// An ID typed into the search box (digits, spaces allowed), or null.
String? senseIdFromQuery(String query) {
  final compact = query.replaceAll(RegExp(r'\s+'), '');
  return RegExp(r'^\d{6,12}$').hasMatch(compact) ? compact : null;
}

SenseHomeComputer senseHomeComputerOf(Peer peer, {int? displayCount}) =>
    SenseHomeComputer(
      id: peer.id,
      name: peer.hostname.trim().isNotEmpty
          ? peer.hostname.trim()
          : (peer.alias.trim().isNotEmpty ? peer.alias.trim() : peer.id),
      location: peer.note.trim(),
      online: peer.online,
      displayCount: displayCount,
    );

/// Pure: project sections for the Controller home.
/// [projectNames] are the device groups in panel order; [order] is null when
/// the server sent no `sense` extension (then each peer keeps its single
/// group and computers are sorted by name). Empty sections are dropped.
List<SenseHomeProject> senseHomeProjects({
  required List<String> projectNames,
  required List<Peer> peers,
  SensePanelOrder? order,
  String query = '',
  Map<String, int> displayCounts = const {},
}) {
  final q = senseHomeFold(query.trim());
  final qId = q.replaceAll(RegExp(r'\s+'), '');
  final known = projectNames.toSet();
  final byProject = <String, List<Peer>>{for (final n in projectNames) n: []};
  final orphans = <Peer>[];
  for (final peer in peers) {
    final names = order != null && order.knowsPeer(peer.id)
        ? order.groupNamesOf(peer.id).toList()
        : [if (peer.device_group_name.isNotEmpty) peer.device_group_name];
    final inKnown = names.where(known.contains).toList();
    if (inKnown.isEmpty) {
      orphans.add(peer);
    } else {
      for (final n in inKnown) {
        byProject[n]!.add(peer);
      }
    }
  }

  bool peerMatches(Peer p) {
    if (q.isEmpty) return true;
    final c = senseHomeComputerOf(p);
    return senseHomeFold(c.name).contains(q) ||
        senseHomeFold(c.location).contains(q) ||
        (qId.isNotEmpty && p.id.contains(qId));
  }

  SenseHomeProject? section(String name, List<Peer> list, bool panelProject) {
    final projectMatches =
        panelProject && q.isNotEmpty && senseHomeFold(name).contains(q);
    final shown = projectMatches ? [...list] : list.where(peerMatches).toList();
    if (shown.isEmpty) return null;
    if (order != null && panelProject) {
      shown.sort((a, b) => order.compare(a.id, b.id, groupName: name));
    } else {
      shown.sort((a, b) => senseHomeFold(senseHomeComputerOf(a).name)
          .compareTo(senseHomeFold(senseHomeComputerOf(b).name)));
    }
    return SenseHomeProject(
        name,
        shown
            .map((p) =>
                senseHomeComputerOf(p, displayCount: displayCounts[p.id]))
            .toList());
  }

  return [
    for (final n in projectNames) section(n, byProject[n]!, true),
    section(senseHomeText('no_project'), orphans, false),
  ].whereType<SenseHomeProject>().toList();
}

/// Binds the Controller home to the app models. Not signed in to the panel:
/// the stock connection page ([fallback]) stays, so the computer can still
/// sign in and connect by ID.
class SenseControllerHome extends StatefulWidget {
  const SenseControllerHome({super.key, required this.fallback});
  final Widget fallback;

  @override
  State<SenseControllerHome> createState() => _SenseControllerHomeState();
}

class _SenseControllerHomeState extends State<SenseControllerHome> {
  Timer? _onlineTimer;

  @override
  void initState() {
    super.initState();
    gFFI.groupModel.pull(force: false);
    _queryOnlines();
    // Online state comes from the connection server; the group peers model
    // applies the answer to the same Peer objects and notifies.
    _onlineTimer =
        Timer.periodic(const Duration(seconds: 20), (_) => _queryOnlines());
  }

  void _queryOnlines() {
    final ids = gFFI.groupModel.peers.map((p) => p.id).toList();
    if (ids.isNotEmpty) bind.queryOnlines(ids: ids);
  }

  @override
  void dispose() {
    _onlineTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final group = gFFI.groupModel;
    return Obx(() {
      if (!gFFI.userModel.isLogin) return widget.fallback;
      final names = group.deviceGroups.map((g) => g.name).toList();
      final peers = group.peers.toList();
      final loading = group.groupLoading.value;
      final error = group.groupLoadError.value;
      // Sense Remote (update plan §6): version label and update strip.
      return SenseUpdateWatch(
        builder: (context, strip) => AnimatedBuilder(
        animation: group.peersModel,
        builder: (context, _) => SenseControllerHomeView(
          projectNames: names,
          peers: peers,
          order: group.senseOrder,
          // Sense Remote: screen count from the panel list (K3-3); missing
          // counts are simply not shown.
          displayCounts: group.senseOrder?.displayCounts ?? const {},
          loading: loading,
          error: error,
          onConnect: (id) => connect(context, id),
          onRefresh: () => group.pull(force: true),
          versionChip: SenseVersionChip(
              version: senseAppVersion(), onTap: senseOpenAbout),
          updateStrip: strip,
        ),
      ));
    });
  }
}

/// Pure view (data + callbacks), covered by widget tests.
class SenseControllerHomeView extends StatefulWidget {
  const SenseControllerHomeView({
    super.key,
    required this.projectNames,
    required this.peers,
    required this.onConnect,
    this.order,
    this.loading = false,
    this.error = '',
    this.onRefresh,
    this.displayCounts = const {},
    this.versionChip,
    this.updateStrip,
  });

  final List<String> projectNames;
  final List<Peer> peers;
  final SensePanelOrder? order;
  final bool loading;
  final String error;
  final void Function(String id) onConnect;
  final VoidCallback? onRefresh;
  final Map<String, int> displayCounts;

  /// Sense Remote (update plan §6): "Sürüm N" next to the title, and the
  /// update strip on top (null when there is nothing to say).
  final Widget? versionChip;
  final Widget? updateStrip;

  @override
  State<SenseControllerHomeView> createState() =>
      _SenseControllerHomeViewState();
}

class _SenseControllerHomeViewState extends State<SenseControllerHomeView> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projects = senseHomeProjects(
      projectNames: widget.projectNames,
      peers: widget.peers,
      order: widget.order,
      query: _query,
      displayCounts: widget.displayCounts,
    );
    final typedId = senseIdFromQuery(_query);
    return Container(
      color: _T.black,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(26, 22, 26, 26),
        children: [
          if (widget.updateStrip != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: widget.updateStrip!),
          _header(),
          if (typedId != null) _connectById(typedId),
          ..._body(projects),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        spacing: 14,
        runSpacing: 10,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(senseHomeText('computers'),
                style: _T.text(size: 22, weight: FontWeight.w700)),
            if (widget.versionChip != null) ...[
              const SizedBox(width: 8),
              widget.versionChip!,
            ],
          ]),
          // Sense Remote: a Wrap, so the header does not overflow in a
          // narrow window now that it carries one more button.
          Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
            SizedBox(
              // Sense Remote: 300 so the longer hint (… ya da kimlik) fits.
              width: 300,
              child: TextField(
                key: const Key('sense-home-search'),
                controller: _search,
                onChanged: (v) => setState(() => _query = v),
                cursorColor: _T.white,
                style: _T.text(size: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: senseHomeText('search_hint'),
                  hintStyle: _T.text(size: 12, color: _T.muted),
                  prefixIcon:
                      const Icon(Icons.search, size: 16, color: _T.muted),
                  prefixIconConstraints:
                      const BoxConstraints(minWidth: 34, minHeight: 34),
                  filled: true,
                  fillColor: _T.field,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(_T.radius),
                      borderSide: const BorderSide(color: Color(0xFF23232C))),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(_T.radius),
                      borderSide: const BorderSide(color: _T.white)),
                ),
              ),
            ),
            // Sense Remote: always visible; connecting by ID was only
            // reachable by typing an ID into the search box (user test
            // 2026-11-21). The password is asked by the connection window.
            SizedBox(
              width: 136,
              child: SenseCmButton(
                  key: const Key('sense-home-connect-id-open'),
                  label: senseHomeText('connect_id'),
                  onTap: () =>
                      showSenseConnectByIdDialog(context, widget.onConnect)),
            ),
            if (widget.onRefresh != null)
              SenseCmTextButton(
                  key: const Key('sense-home-refresh'),
                  label: senseHomeText('refresh'),
                  onTap: widget.onRefresh!),
          ]),
        ],
      ),
    );
  }

  Widget _connectById(String id) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 260,
          child: SenseCmButton(
            key: const Key('sense-home-connect-id'),
            label: '${senseHomeText('connect_id')} · $id',
            primary: true,
            onTap: () => widget.onConnect(id),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(List<SenseHomeProject> projects) {
    if (projects.isEmpty) {
      final String text;
      if (widget.loading) {
        text = senseHomeText('loading');
      } else if (widget.error.isNotEmpty) {
        text = senseHomeText('load_error');
      } else if (_query.trim().isNotEmpty) {
        text = senseHomeText('no_match');
      } else {
        text = senseHomeText('empty');
      }
      return [
        Padding(
          padding: const EdgeInsets.only(top: 28),
          child: Text(text,
              key: const Key('sense-home-message'),
              style: _T.text(size: 12, color: _T.muted)),
        )
      ];
    }
    return [
      for (final p in projects) ...[
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 10),
          child: Text(senseHomeUpper(p.name),
              style: _T.text(size: 10, color: _T.muted)
                  .copyWith(letterSpacing: 1.6)),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in p.computers)
              SenseHomeCard(
                  key: ValueKey('sense-card-${p.name}-${c.id}'),
                  computer: c,
                  onConnect: () => widget.onConnect(c.id)),
          ],
        ),
      ],
    ];
  }
}

class SenseHomeCard extends StatelessWidget {
  const SenseHomeCard(
      {super.key, required this.computer, required this.onConnect});
  final SenseHomeComputer computer;
  final VoidCallback onConnect;

  static const width = 236.0;

  String get subtitle {
    final parts = <String>[
      if (computer.location.isNotEmpty) computer.location,
      if (computer.displayCount != null)
        senseHomeText('screen_count', {'n': '${computer.displayCount}'}),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final online = computer.online;
    final screens = (computer.displayCount ?? 1).clamp(1, 6);
    return Container(
      width: width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _T.field,
        borderRadius: BorderRadius.circular(_T.radiusCard),
        border: Border.all(color: _T.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 84,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: online
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF0B0B30), Color(0xFF2A0230)])
                  : null,
              color: online ? null : const Color(0xFF0C0C10),
            ),
            child: Row(
              children: [
                for (var i = 0; i < screens; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: Colors.white.withOpacity(0.04),
                        border: Border.all(
                            color: Colors.white.withOpacity(0.18)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                _Dot(on: online),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(computer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _T.text(size: 13, weight: FontWeight.w600)),
                      if (subtitle.isNotEmpty)
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _T.text(size: 11, color: _T.muted)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _ConnectButton(online: online, onTap: onConnect),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? _T.live : _T.idle,
          boxShadow: on
              ? const [BoxShadow(color: _T.live, blurRadius: 10)]
              : null,
        ),
      );
}

/// Offline computers keep a muted "Kapalı" button that still tries: the online
/// answer of the public connection server can lag behind.
class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.online, required this.onTap});
  final bool online;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: online ? _T.white : const Color(0xFF1B1B22),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Text(senseHomeText(online ? 'connect' : 'offline'),
              style: _T.text(
                  size: 11,
                  weight: FontWeight.w600,
                  color: online ? _T.black : _T.idle)),
        ),
      ),
    );
    return online
        ? button
        : Tooltip(message: senseHomeText('offline_tip'), child: button);
  }
}
