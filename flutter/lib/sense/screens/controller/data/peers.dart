// Sense Remote: data of the Controller list (YH C2; prototype `pcsView`).
// Source: the panel's client lists (`/api/device-group/accessible` +
// `/api/peers` with the `sense` extension, read by the device group model) and,
// per computer, `GET /api/sense/peer-status` (health for the LED, last seen).
// The personal drag-and-drop order goes to `POST /api/sense/device-order`.
//
// Pure functions build what the screen shows; the backend is the only part that
// talks to the panel, so the tests run on fakes. Nothing is guessed: a value the
// panel did not send is missing and the screen says so.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../common.dart' show getHttpHeaders;
import '../../../../common/hbbs/hbbs.dart' show SensePanelOrder;
import '../../../../models/peer_model.dart' show Peer;
import '../../../../models/platform_model.dart' show bind;
import '../../../../utils/http_service.dart' as http;
import '../../../strings/controller.dart';
import '../../../tokens/sense_tokens.dart';
import '../../session/data/peer_status.dart';
import '../../session/popups/status/status_format.dart' show senseAgo;
import '../../session/popups/status/status_model.dart';
import '../../session/popups/status/status_strings.dart' show SenseStatusStrings;

/// One computer of the list.
class SenseComputer {
  const SenseComputer({
    required this.id,
    required this.name,
    this.deviceId = '',
    this.location = '',
    this.os = '',
    this.online = false,
    this.displayCount,
    this.busyBy,
    this.lastSeenAt,
  });

  /// Connection ID (what Bağlan uses).
  final String id;

  /// Panel device id (`dev_…`); empty when the panel did not send it.
  final String deviceId;
  final String name;
  final String location;

  /// "Windows", "macOS", "Linux" or empty.
  final String os;
  final bool online;

  /// Null = the panel has no display info (the tile then shows no count).
  final int? displayCount;

  /// "Meşgul · kişi" (panel `busy.by`, S8); null = free.
  final String? busyBy;

  /// Unix seconds, when known.
  final int? lastSeenAt;

  bool get busy => busyBy != null;

  SenseComputer copyWith({int? lastSeenAt}) => SenseComputer(
        id: id,
        name: name,
        deviceId: deviceId,
        location: location,
        os: os,
        online: online,
        displayCount: displayCount,
        busyBy: busyBy,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      );
}

/// One project group, computers in the person's order.
class SenseProject {
  const SenseProject({required this.id, required this.name, required this.computers, this.orphan = false});

  /// Panel project id; empty for "Projesiz" and for servers without `sense`.
  final String id;
  final String name;
  final List<SenseComputer> computers;

  /// "Projesiz": computers without a project the person can see.
  final bool orphan;

  /// Key of the group order and of the open group.
  String get key => orphan ? '' : (id.isNotEmpty ? id : name);

  int get online => computers.where((c) => c.online).length;
  int get offline => computers.length - online;

  SenseProject withComputers(List<SenseComputer> list) =>
      SenseProject(id: id, name: name, computers: list, orphan: orphan);
}

/// Case and Turkish dotted / dotless i insensitive form for the search.
String senseFold(String s) =>
    s.replaceAll('İ', 'i').replaceAll('I', 'i').replaceAll('ı', 'i').toLowerCase();

/// An ID typed into a field (digits and spaces), or null.
String? senseIdFrom(String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  return RegExp(r'^\d{6,12}$').hasMatch(compact) ? compact : null;
}

/// "Windows", "macOS", "Linux" from the peer platform ("Mac OS" in RustDesk).
String senseOsLabel(String platform) {
  final p = senseFold(platform);
  if (p.contains('mac')) return 'macOS';
  if (p.contains('win')) return 'Windows';
  if (p.contains('linux')) return 'Linux';
  return '';
}

SenseComputer senseComputerOf(Peer peer, SensePanelOrder? order) {
  final extra = order?.extras[peer.id];
  final name = peer.hostname.trim().isNotEmpty
      ? peer.hostname.trim()
      : (peer.alias.trim().isNotEmpty ? peer.alias.trim() : peer.id);
  return SenseComputer(
    id: peer.id,
    deviceId: extra?.deviceId ?? '',
    name: name,
    location: peer.note.trim(),
    os: senseOsLabel(peer.platform),
    // The panel's view first (the numbers above the list are the panel's);
    // the connection server's answer when the panel did not send one.
    online: extra?.online ?? peer.online,
    displayCount: order?.displayCounts[peer.id],
    // A computer that is not online is never "busy" (panel rule, S8).
    busyBy: (extra?.online ?? peer.online) ? extra?.busyBy : null,
    lastSeenAt: extra?.lastSeenAt,
  );
}

/// Project groups in panel order (the panel already applies the person's own
/// order to the sort keys). A computer tagged with several projects shows in
/// each. Computers without a known project go to "Projesiz" at the end.
List<SenseProject> senseProjectsFrom({
  required List<String> projectNames,
  required List<Peer> peers,
  SensePanelOrder? order,
}) {
  final known = projectNames.toSet();
  final byName = <String, List<Peer>>{for (final n in projectNames) n: []};
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
        byName[n]!.add(peer);
      }
    }
  }
  List<SenseComputer> sorted(List<Peer> list, String? groupName) {
    final copy = [...list];
    if (order != null) {
      copy.sort((a, b) => order.compare(a.id, b.id, groupName: groupName));
    } else {
      copy.sort((a, b) => senseFold(senseComputerOf(a, null).name)
          .compareTo(senseFold(senseComputerOf(b, null).name)));
    }
    return copy.map((p) => senseComputerOf(p, order)).toList();
  }

  return [
    for (final n in projectNames)
      if (byName[n]!.isNotEmpty)
        SenseProject(id: order?.projectIds[n] ?? '', name: n, computers: sorted(byName[n]!, n)),
    if (orphans.isNotEmpty)
      SenseProject(
          id: '', name: SenseControllerStrings.noProject, computers: sorted(orphans, null), orphan: true),
  ];
}

/// Computers once each (a computer in two projects counts once).
List<SenseComputer> senseUnique(List<SenseProject> projects) {
  final seen = <String>{};
  return [
    for (final p in projects)
      for (final c in p.computers)
        if (seen.add(c.id)) c,
  ];
}

/// The four number tiles (#26) and the header line.
class SenseCounts {
  const SenseCounts({
    required this.total,
    required this.online,
    required this.attention,
    required this.attentionLevel,
    required this.projects,
  });

  final int total;
  final int online;
  int get offline => total - online;

  /// Computers whose health is orange or red (known values only).
  final int attention;

  /// Worst of those; ok when none.
  final SenseLevel attentionLevel;
  final int projects;
}

/// Counted before the search and the location filter (like the panel's
/// `DeviceListSummary`: the tiles do not move while typing).
SenseCounts senseCountsOf(List<SenseProject> projects, Map<String, SenseLevel> levels) {
  final all = senseUnique(projects);
  final bad = [
    for (final c in all)
      if (levels[c.id] == SenseLevel.warn || levels[c.id] == SenseLevel.hot) levels[c.id]!,
  ];
  return SenseCounts(
    total: all.length,
    online: all.where((c) => c.online).length,
    attention: bad.length,
    attentionLevel: bad.isEmpty ? SenseLevel.ok : senseWorstLevel(bad),
    projects: projects.where((p) => !p.orphan).length,
  );
}

/// Location filter chips: each place once, with its computer count, sorted.
List<({String name, int count})> senseLocationsOf(List<SenseProject> projects) {
  final counts = <String, int>{};
  for (final c in senseUnique(projects)) {
    if (c.location.isEmpty) continue;
    counts[c.location] = (counts[c.location] ?? 0) + 1;
  }
  final names = counts.keys.toList()..sort((a, b) => senseFold(a).compareTo(senseFold(b)));
  return [for (final n in names) (name: n, count: counts[n]!)];
}

/// Search (computer, project, location, ID) and location filter. A project
/// whose name matches keeps all its computers. Empty groups are dropped.
List<SenseProject> senseFilter(List<SenseProject> projects, {String query = '', String? location}) {
  final q = senseFold(query.trim());
  final qId = q.replaceAll(RegExp(r'\s+'), '');
  bool hit(SenseComputer c) =>
      senseFold(c.name).contains(q) ||
      senseFold(c.location).contains(q) ||
      (qId.isNotEmpty && RegExp(r'^\d+$').hasMatch(qId) && c.id.contains(qId));
  final out = <SenseProject>[];
  for (final p in projects) {
    var list = location == null ? p.computers : p.computers.where((c) => c.location == location).toList();
    if (q.isNotEmpty && !senseFold(p.name).contains(q)) list = list.where(hit).toList();
    if (list.isNotEmpty) out.add(p.withComputers(list));
  }
  return out;
}

/// Drag and drop inside a group: [dragged] goes in front of [target]
/// (prototype `tMove`). Unknown ids leave the order as it is.
List<String> senseMoveBefore(List<String> order, String dragged, String target) {
  if (dragged == target || !order.contains(dragged) || !order.contains(target)) return order;
  final out = [...order]..remove(dragged);
  out.insert(out.indexOf(target), dragged);
  return out;
}

/// Group drag: [dragged] takes the place of [target].
List<String> senseMoveTo(List<String> order, String dragged, String target) {
  if (dragged == target || !order.contains(dragged) || !order.contains(target)) return order;
  final at = order.indexOf(target);
  final out = [...order]..remove(dragged);
  out.insert(at, dragged);
  return out;
}

/// Applies a saved order to a list: the named ids first in that order, the
/// rest after them in their current order.
List<T> senseApplyOrder<T>(List<T> items, List<String> order, String Function(T) idOf) {
  final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final ra = rank[idOf(a.$2)], rb = rank[idOf(b.$2)];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null) return -1;
    if (rb != null) return 1;
    return a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

// ------------------------------------------------------------------ health

/// One line of the LED box: label, value (null = "okunamadı"), colour.
typedef SenseHealthLine = ({String label, String? value, SenseLevel level});

/// What the LED and its box show for one computer.
class SenseComputerHealth {
  const SenseComputerHealth({required this.level, this.lines = const [], this.at, this.lastSeenAt});

  /// [SenseLevel.unknown] = no data (hollow ring).
  final SenseLevel level;
  final List<SenseHealthLine> lines;

  /// Unix seconds of the health values.
  final int? at;
  final int? lastSeenAt;

  static const none = SenseComputerHealth(level: SenseLevel.unknown);
}

/// Built from the same model as the "Bilgisayar durumu" popup (O8): the
/// overview rows without the network meter, the popup's overall level.
SenseComputerHealth senseHealthOf(SensePeerStatusFull full) {
  final seen = full.status.lastSeenAt;
  if (full.health == null) return SenseComputerHealth(level: SenseLevel.unknown, lastSeenAt: seen);
  final view = senseBuildStatusView(full);
  final lines = <SenseHealthLine>[
    for (final m in view.meters)
      if (m.label != SenseStatusStrings.network)
        (label: m.label, value: m.text, level: m.text == null ? SenseLevel.unknown : m.valueLevel),
  ];
  return SenseComputerHealth(level: view.level, lines: lines, at: full.health!.at, lastSeenAt: seen);
}

/// Head of the LED box.
String senseHealthTitle(SenseLevel level, {required bool online}) {
  if (!online) return SenseControllerStrings.healthNone;
  switch (level) {
    case SenseLevel.ok:
      return SenseControllerStrings.healthOk;
    case SenseLevel.warn:
      return SenseControllerStrings.healthWarn;
    case SenseLevel.hot:
      return SenseControllerStrings.healthHot;
    case SenseLevel.unknown:
      return SenseControllerStrings.healthNone;
  }
}

/// "8 sn önce" from Unix seconds; null when unknown.
String? senseAgoFrom(int? at, int now) =>
    at == null ? null : senseAgo(Duration(seconds: now - at < 0 ? 0 : now - at));

// ------------------------------------------------------------------ backend

abstract class SensePeersBackend {
  Future<SensePeerStatusFullResult> peerStatus(String id);

  /// `POST /api/sense/device-order`; true when the panel saved it.
  Future<bool> saveOrder(String projectId, List<String> deviceIds);

  /// Group order is kept on this computer for the signed-in person (the panel
  /// has no per-person project order).
  String readLocal(String key);
  Future<void> writeLocal(String key, String value);
}

class SensePeersBridge implements SensePeersBackend {
  const SensePeersBridge();

  @override
  Future<SensePeerStatusFullResult> peerStatus(String id) => senseFetchPeerStatusFull(id);

  @override
  Future<bool> saveOrder(String projectId, List<String> deviceIds) async {
    try {
      final api = await bind.mainGetApiServer();
      if (api.trim().isEmpty) return false;
      final headers = getHttpHeaders();
      headers['Content-Type'] = 'application/json';
      final resp = await http.post(Uri.parse('$api/api/sense/device-order'),
          headers: headers, body: jsonEncode({'project_id': projectId, 'device_ids': deviceIds}));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  String readLocal(String key) => bind.mainGetLocalOption(key: key);

  @override
  Future<void> writeLocal(String key, String value) => bind.mainSetLocalOption(key: key, value: value);
}

/// Local option holding the person's project order (JSON list of names).
String senseGroupOrderKey(String account) => 'sense-group-order-${senseFold(account)}';

/// Health per computer, fetched one at a time for the computers on screen.
/// The panel allows 60 peer-status requests a minute per key (the session
/// window uses the same key), so the cache keeps an answer [ttl] long and
/// waits [gap] between requests.
class SenseHealthCache extends ChangeNotifier {
  SenseHealthCache(
    this.backend, {
    int Function()? now,
    this.ttl = const Duration(seconds: 60),
    this.gap = const Duration(milliseconds: 1500),
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  final SensePeersBackend backend;
  final Duration ttl;
  final Duration gap;
  final int Function() _now;

  final Map<String, SenseComputerHealth> _data = {};
  final Map<String, int> _fetchedAt = {};
  final List<String> _queue = [];
  bool _running = false;
  bool _disposed = false;

  int now() => _now();

  SenseComputerHealth? of(String id) => _data[id];

  /// Levels for the "Dikkat isteyen" tile (known computers only).
  Map<String, SenseLevel> get levels => {for (final e in _data.entries) e.key: e.value.level};

  bool _fresh(String id) {
    final at = _fetchedAt[id];
    return at != null && _now() - at < ttl.inSeconds;
  }

  /// Asks for [ids] (screen order); fresh ones and queued ones are skipped.
  void want(Iterable<String> ids, {bool first = false}) {
    var added = false;
    for (final id in ids) {
      if (_fresh(id) || _queue.contains(id)) continue;
      first ? _queue.insert(0, id) : _queue.add(id);
      added = true;
    }
    if (added) unawaited(_run());
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_disposed) {
        final id = _queue.removeAt(0);
        if (_fresh(id)) continue;
        final r = await backend.peerStatus(id);
        if (_disposed) return;
        _fetchedAt[id] = _now();
        if (r.data != null) {
          _data[id] = senseHealthOf(r.data!);
        } else if (r.noPanelInfo) {
          _data[id] = SenseComputerHealth.none;
        }
        notifyListeners();
        if (_queue.isNotEmpty && gap > Duration.zero) await Future<void>.delayed(gap);
      }
    } finally {
      _running = false;
    }
  }

  @visibleForTesting
  void put(String id, SenseComputerHealth h) {
    _data[id] = h;
    _fetchedAt[id] = _now();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _queue.clear();
    super.dispose();
  }
}
