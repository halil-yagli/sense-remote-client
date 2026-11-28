// Sense Remote: what the panel knows about the computer we are connected to
// (displays, health, network addresses, version). Contract: panel
// `GET /api/sense/peer-status?id=<id>` (packages/shared ClientPeerStatus,
// Dalga 3 plan §3.3). The remote computer gets no new protocol message; the
// data is the one it already reports to the panel (K-DURUM).
//
// Parsing is tolerant on purpose: a field the panel did not send, or sent in
// an unexpected shape, is simply missing here and the interface hides it. No
// value is ever invented.

import 'dart:convert';

import '../../../../models/platform_model.dart';
import '../../../../utils/http_service.dart' as http;

class SensePeerDisplay {
  const SensePeerDisplay({
    required this.index,
    this.name,
    this.x,
    this.y,
    this.width,
    this.height,
    this.scale,
    this.primary,
    this.refreshHz,
    this.connection,
    this.bitDepth,
    this.colorFormat,
    this.hdr,
    this.nativeWidth,
    this.nativeHeight,
  });

  final int index;
  final String? name;
  final int? x;
  final int? y;
  final int? width;
  final int? height;
  final double? scale;
  final bool? primary;
  final double? refreshHz;

  /// hdmi, displayport, dvi, vga, usb_c, internal, other, unknown
  final String? connection;
  final int? bitDepth;

  /// rgb, ycbcr444, ycbcr422, ycbcr420, unknown
  final String? colorFormat;
  final bool? hdr;
  final int? nativeWidth;
  final int? nativeHeight;

  static SensePeerDisplay? fromJson(Object? json) {
    if (json is! Map) return null;
    final index = _int(json['index']);
    if (index == null || index < 0) return null;
    return SensePeerDisplay(
      index: index,
      name: _str(json['name']),
      x: _int(json['x']),
      y: _int(json['y']),
      width: _int(json['width']),
      height: _int(json['height']),
      scale: _num(json['scale']),
      primary: _bool(json['primary']),
      refreshHz: _num(json['refresh_hz']),
      connection: _str(json['connection']),
      bitDepth: _int(json['bit_depth']),
      colorFormat: _str(json['color_format']),
      hdr: _bool(json['hdr']),
      nativeWidth: _int(json['native_width']),
      nativeHeight: _int(json['native_height']),
    );
  }
}

class SensePeerDisk {
  const SensePeerDisk({required this.mount, required this.usedPct, this.totalGb});
  final String mount;
  final double usedPct;
  final double? totalGb;

  static SensePeerDisk? fromJson(Object? json) {
    if (json is! Map) return null;
    final mount = _str(json['mount']);
    final used = _num(json['used_pct']);
    if (mount == null || used == null) return null;
    return SensePeerDisk(
        mount: mount, usedPct: used, totalGb: _num(json['total_gb']));
  }
}

class SensePeerHealth {
  const SensePeerHealth({
    this.at,
    this.cpuPct,
    this.gpuPct,
    this.cpuTempC,
    this.gpuTempC,
    this.memUsedMb,
    this.memTotalMb,
    this.disks = const [],
    this.uptimeS,
  });

  /// Measurement time (remote clock, Unix s) — information only.
  final int? at;
  final double? cpuPct;
  final double? gpuPct;
  final double? cpuTempC;
  final double? gpuTempC;
  final int? memUsedMb;
  final int? memTotalMb;
  final List<SensePeerDisk> disks;
  final int? uptimeS;

  static SensePeerHealth? fromJson(Object? json) {
    if (json is! Map) return null;
    return SensePeerHealth(
      at: _int(json['at']),
      cpuPct: _num(json['cpu_pct']),
      gpuPct: _num(json['gpu_pct']),
      cpuTempC: _num(json['cpu_temp_c']),
      gpuTempC: _num(json['gpu_temp_c']),
      memUsedMb: _int(json['mem_used_mb']),
      memTotalMb: _int(json['mem_total_mb']),
      disks: _list(json['disks'], SensePeerDisk.fromJson),
      uptimeS: _int(json['uptime_s']),
    );
  }

  bool get isEmpty =>
      cpuPct == null &&
      gpuPct == null &&
      cpuTempC == null &&
      gpuTempC == null &&
      memUsedMb == null &&
      disks.isEmpty &&
      uptimeS == null;
}

class SensePeerNetwork {
  const SensePeerNetwork({
    required this.name,
    required this.kind,
    this.ipv4 = const [],
    this.ipv6 = const [],
    this.up,
  });

  final String name;

  /// ethernet, wifi, other
  final String kind;
  final List<String> ipv4;
  final List<String> ipv6;
  final bool? up;

  static SensePeerNetwork? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = _str(json['name']) ?? '';
    final kind = _str(json['kind']) ?? 'other';
    return SensePeerNetwork(
      name: name,
      kind: kind,
      ipv4: _list(json['ipv4'], _str),
      ipv6: _list(json['ipv6'], _str),
      up: _bool(json['up']),
    );
  }
}

class SensePeerStatus {
  const SensePeerStatus({
    required this.online,
    this.lastSeenAt,
    this.appVersion,
    this.role,
    this.idleDisconnectMin,
    this.health,
    this.displays = const [],
    this.network = const [],
    this.wakeable,
  });

  final bool online;

  /// Panel time of the last heartbeat, Unix s.
  final int? lastSeenAt;

  /// Sense version number: 1, 2, 3 …
  final int? appVersion;
  final String? role;

  /// "Hareketsiz bağlantıyı kes" of the computer, minutes; null = off (or the
  /// panel did not send it).
  final int? idleDisconnectMin;
  final SensePeerHealth? health;
  final List<SensePeerDisplay> displays;

  /// Ethernet first, then Wi-Fi, then the rest (see [senseOrderNetwork]).
  final List<SensePeerNetwork> network;

  /// Sürüm 12 (Çevrimdışı kartı): the panel can wake this computer (Wake-on-LAN through an
  /// online computer at the same place). Null = the panel did not say (older panel).
  final bool? wakeable;

  static SensePeerStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final online = _bool(json['online']);
    if (online == null) return null;
    return SensePeerStatus(
      online: online,
      lastSeenAt: _int(json['last_seen_at']),
      appVersion: _int(json['app_version']),
      role: _str(json['role']),
      idleDisconnectMin: _int(json['idle_disconnect_min']),
      health: SensePeerHealth.fromJson(json['health']),
      displays: _list(json['displays'], SensePeerDisplay.fromJson),
      network: senseOrderNetwork(
          _list(json['network'], SensePeerNetwork.fromJson)),
      wakeable: _bool(json['wakeable']),
    );
  }

  /// Panel data of display [index] (RustDesk display order); null if the
  /// panel has nothing for it.
  SensePeerDisplay? display(int index) {
    for (final d in displays) {
      if (d.index == index) return d;
    }
    return null;
  }
}

/// Ethernet before Wi-Fi before the rest; the order inside a kind is kept
/// (the computer reports it in the operating system's order). The panel
/// already sends it this way; sorting again costs nothing and keeps the user's
/// request ("ethernet first") true even for an older panel.
List<SensePeerNetwork> senseOrderNetwork(List<SensePeerNetwork> list) {
  int rank(String kind) => kind == 'ethernet'
      ? 0
      : kind == 'wifi'
          ? 1
          : 2;
  final indexed = list.asMap().entries.toList()
    ..sort((a, b) {
      final r = rank(a.value.kind).compareTo(rank(b.value.kind));
      return r != 0 ? r : a.key.compareTo(b.key);
    });
  return indexed.map((e) => e.value).toList();
}

enum SensePeerStatusError {
  /// No panel address or no sign-in on this computer.
  noKey,

  /// 401/403: the key is not valid for this request.
  unauthorized,

  /// 404: not a Sense computer the panel knows (or not a Host).
  notFound,

  /// Network error, 429, 5xx or an unreadable answer.
  failed,
}

class SensePeerStatusResult {
  const SensePeerStatusResult.ok(SensePeerStatus this.status) : error = null;
  const SensePeerStatusResult.error(SensePeerStatusError this.error)
      : status = null;

  final SensePeerStatus? status;
  final SensePeerStatusError? error;

  /// "Panel bilgisi yok": the panel cannot have anything for this peer.
  bool get noPanelInfo =>
      error == SensePeerStatusError.noKey ||
      error == SensePeerStatusError.unauthorized ||
      error == SensePeerStatusError.notFound;
}

/// Maps an HTTP answer to a result. Pure; covered by tests.
SensePeerStatusResult senseParsePeerStatusResponse(int statusCode, String body) {
  if (statusCode == 401 || statusCode == 403) {
    return const SensePeerStatusResult.error(SensePeerStatusError.unauthorized);
  }
  if (statusCode == 404) {
    return const SensePeerStatusResult.error(SensePeerStatusError.notFound);
  }
  if (statusCode != 200) {
    return const SensePeerStatusResult.error(SensePeerStatusError.failed);
  }
  try {
    final status = SensePeerStatus.fromJson(jsonDecode(body));
    if (status == null) {
      return const SensePeerStatusResult.error(SensePeerStatusError.failed);
    }
    return SensePeerStatusResult.ok(status);
  } catch (_) {
    return const SensePeerStatusResult.error(SensePeerStatusError.failed);
  }
}

/// The RustDesk peer id without an "@server" or "?key" suffix.
String senseBarePeerId(String id) {
  var bare = id;
  final at = bare.indexOf('@');
  if (at >= 0) bare = bare.substring(0, at);
  final q = bare.indexOf('?');
  if (q >= 0) bare = bare.substring(0, q);
  return bare.trim();
}

typedef SenseHttpGet = Future<({int statusCode, String body})> Function(
    Uri url, Map<String, String> headers);

/// How long one peer-status request may take (P3, B8).
const Duration kSensePeerStatusTimeout = Duration(seconds: 8);

/// Reads peer-status with the key this app already holds (the same Bearer
/// key the address book uses). The key never leaves the HTTP header.

class SensePeerStatusClient {
  SensePeerStatusClient({
    Future<String> Function()? apiServer,
    String Function()? accessToken,
    SenseHttpGet? get,
  })  : _apiServer = apiServer ?? (() => bind.mainGetApiServer()),
        _accessToken = accessToken ??
            (() => bind.mainGetLocalOption(key: 'access_token')),
        _get = get ?? _defaultGet;

  final Future<String> Function() _apiServer;
  final String Function() _accessToken;
  final SenseHttpGet _get;

  static Future<({int statusCode, String body})> _defaultGet(
      Uri url, Map<String, String> headers) async {
    final resp = await http.get(url, headers: headers);
    return (statusCode: resp.statusCode, body: resp.body);
  }

  Future<SensePeerStatusResult> fetch(String peerId) async {
    final id = senseBarePeerId(peerId);
    try {
      final server = (await _apiServer()).trim();
      final token = _accessToken().trim();
      if (server.isEmpty || token.isEmpty || id.isEmpty) {
        return const SensePeerStatusResult.error(SensePeerStatusError.noKey);
      }
      final base = server.endsWith('/')
          ? server.substring(0, server.length - 1)
          : server;
      final url = Uri.parse('$base/api/sense/peer-status')
          .replace(queryParameters: {'id': id});
      // P3 (B8): a hung network ends in an error state, not in an endless load.
      final resp = await _get(url, {'Authorization': 'Bearer $token'})
          .timeout(kSensePeerStatusTimeout);
      return senseParsePeerStatusResponse(resp.statusCode, resp.body);
    } catch (_) {
      return const SensePeerStatusResult.error(SensePeerStatusError.failed);
    }
  }
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite && v == v.roundToDouble()) return v.toInt();
  return null;
}

double? _num(Object? v) {
  if (v is num && v.isFinite) return v.toDouble();
  return null;
}

bool? _bool(Object? v) => v is bool ? v : null;

String? _str(Object? v) => v is String ? v : null;

List<T> _list<T>(Object? v, T? Function(Object?) parse) {
  if (v is! List) return const [];
  final out = <T>[];
  for (final e in v) {
    final p = parse(e);
    if (p != null) out.add(p);
  }
  return out;
}
