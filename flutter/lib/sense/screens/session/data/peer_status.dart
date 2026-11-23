// Sense Remote: peer-status for the session popups (YH O8, O9; S6). The base
// answer (online, displays, network, version) is read by sense_peer_status.dart,
// which stays as it is; this file adds the health_v2 detail and the inventory
// from the same body, and a small feed that keeps it fresh while a popup is open.
//
// Panel: GET /api/sense/peer-status (packages/shared ClientPeerStatus,
// `health` + `inventory`). Same Bearer key as the address book; the key never
// leaves the HTTP header.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../utils/http_service.dart' as http;
import 'health.dart';
import 'sense_peer_status.dart';

export 'health.dart';
export 'sense_peer_status.dart';

/// Everything the panel knows about the computer, parsed once.
class SensePeerStatusFull {
  const SensePeerStatusFull({required this.status, this.health, this.inventory});

  final SensePeerStatus status;

  /// v1 + v2 values; null when the computer never reported.
  final SenseHealthDetail? health;

  /// Fixed inventory; null for a computer without health_v2.
  final SenseInventory? inventory;

  /// Parses the peer-status body; null when it is not a valid answer.
  static SensePeerStatusFull? parse(String body) {
    try {
      final json = jsonDecode(body);
      final status = SensePeerStatus.fromJson(json);
      if (status == null || json is! Map) return null;
      return SensePeerStatusFull(
        status: status,
        health: SenseHealthDetail.fromJson(json['health']),
        inventory: SenseInventory.fromJson(json['inventory']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// One answer of the feed: data, or the reason there is none.
class SensePeerStatusFullResult {
  const SensePeerStatusFullResult.ok(SensePeerStatusFull this.data) : error = null;
  const SensePeerStatusFullResult.error(SensePeerStatusError this.error) : data = null;

  final SensePeerStatusFull? data;
  final SensePeerStatusError? error;

  /// The panel cannot have anything for this computer (no key, not ours).
  bool get noPanelInfo =>
      error == SensePeerStatusError.noKey ||
      error == SensePeerStatusError.unauthorized ||
      error == SensePeerStatusError.notFound;
}

typedef SensePeerStatusFetch = Future<SensePeerStatusFullResult> Function(String peerId);

/// Reads peer-status with the existing client and keeps the raw body for the
/// health_v2 fields the base parser does not know.
Future<SensePeerStatusFullResult> senseFetchPeerStatusFull(String peerId, {SenseHttpGet? get}) async {
  String? body;
  final inner = get;
  final client = SensePeerStatusClient(
    get: (url, headers) async {
      final r = inner != null ? await inner(url, headers) : await _defaultGet(url, headers);
      body = r.body;
      return r;
    },
  );
  final r = await client.fetch(peerId);
  if (r.error != null) return SensePeerStatusFullResult.error(r.error!);
  final full = body == null ? null : SensePeerStatusFull.parse(body!);
  if (full == null) return const SensePeerStatusFullResult.error(SensePeerStatusError.failed);
  return SensePeerStatusFullResult.ok(full);
}

/// Same HTTP call as the base client (utils/http_service: proxy aware).
Future<({int statusCode, String body})> _defaultGet(Uri url, Map<String, String> headers) async {
  final resp = await http.get(url, headers: headers);
  return (statusCode: resp.statusCode, body: resp.body);
}

/// Keeps peer-status fresh while at least one popup listens (O8, O9).
/// Panel limit is 60 requests per minute per key; 30 s is far under it.
class SensePeerStatusFeed extends ChangeNotifier {
  SensePeerStatusFeed({
    required this.peerId,
    SensePeerStatusFetch? fetch,
    DateTime Function()? now,
    this.refreshEvery = const Duration(seconds: 30),
  })  : _fetch = fetch ?? senseFetchPeerStatusFull,
        _now = now ?? DateTime.now;

  /// One feed per connected computer.
  static final Map<String, SensePeerStatusFeed> _byId = {};
  static SensePeerStatusFeed of(String peerId) =>
      _byId.putIfAbsent(peerId, () => SensePeerStatusFeed(peerId: peerId));
  static void remove(String peerId) => _byId.remove(peerId)?.dispose();

  final String peerId;
  final SensePeerStatusFetch _fetch;
  final DateTime Function() _now;

  /// Null: no periodic refresh (tests).
  final Duration? refreshEvery;

  SensePeerStatusFullResult? _result;
  SensePeerStatusFull? _last;
  DateTime? _fetchedAt;
  bool _loading = false;
  bool _disposed = false;
  int _users = 0;
  Timer? _timer;

  /// Latest answer (data or error).
  SensePeerStatusFullResult? get result => _result;

  /// Last good data, kept through a later error so the popup does not go blank.
  SensePeerStatusFull? get data => _last;
  DateTime? get fetchedAt => _fetchedAt;
  bool get loading => _loading;
  DateTime now() => _now();

  /// A popup opened: read now (when stale) and every [refreshEvery].
  void attach() {
    _users++;
    final at = _fetchedAt;
    if (at == null || _now().difference(at) > const Duration(seconds: 20)) refresh();
    final every = refreshEvery;
    if (every != null) _timer ??= Timer.periodic(every, (_) => refresh());
  }

  /// The popup closed; the timer stops when nobody listens.
  void detach() {
    if (_users > 0) _users--;
    if (_users == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> refresh() async {
    if (_loading || _disposed) return;
    _loading = true;
    _notify();
    final r = await _fetch(peerId);
    if (_disposed) return;
    _result = r;
    if (r.data != null) _last = r.data;
    _fetchedAt = _now();
    _loading = false;
    _notify();
  }

  /// Tests and previews: put a known answer in.
  @visibleForTesting
  void debugSet(SensePeerStatusFullResult r, {DateTime? at}) {
    _result = r;
    if (r.data != null) _last = r.data;
    _fetchedAt = at ?? _now();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
