// Sense Remote (Sürüm 12, #160–#163, #169): state of the "Sık kullanılanlar" list of one
// session. The choice belongs to the employee and is kept per operating system (#163):
// connecting to a Mac brings the Mac list, to a Windows PC the Windows list. It is read and
// written through the core's preference store (`main_sense_prefs_*`, keys `fav.items`,
// `fav.recent`); the core keeps a cache and syncs with the panel (FAV-Ç).
//
// While this build's core does not store preferences yet (`{"error":"unsupported"}`), the
// choice stays in memory for as long as the app runs and the footer says so. While the core
// has no catalogue (`[]`), every built-in entry is offered and the Host's answer decides; an
// older Host never answers, which ends as "yanıt vermedi" after [runTimeout].
//
// Runs: a `keys` entry is sent from here (Ctrl+Alt+Del, lock, Win+D); the rest go to the
// Host as `sense.shortcut-run {req, id}` (id only, never a command) and the result comes
// back as `sense_shortcut_result`. Sürüm 12 (#171): ping and the window list carry one
// checked argument (`arg`: the address, the process id to close) and the answer may carry a
// result body (`res`: ping counts, the window list, the IP card).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;

import '../../../../strings/favorites.dart';
import '../../data/health.dart' show SenseInventory, SenseInvNetwork;
import '../../data/sense_peer_status.dart' show SensePeerStatus;
import 'catalog.dart';
import 'favorites_io.dart';

/// Most chosen shortcuts per system (plan §2.2 `fav.items`).
const int kSenseFavMaxItems = 24;

/// Most recent ids kept (`fav.recent`) and shown.
const int kSenseFavMaxRecent = 8;
const int kSenseFavShownRecent = 3;

/// Message names (plan §2.1).
const String kSenseShortcutRunMsg = 'sense.shortcut-run';

/// One row the list can show: a built-in entry or a custom one from the panel.
@immutable
class SenseFavItem {
  const SenseFavItem({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.group,
    this.pane = SenseFavPane.none,
    this.ask,
    this.keys,
    this.custom = false,
    this.pending = false,
    this.available = true,
  });

  factory SenseFavItem.of(SenseFavDef d, {bool available = true}) => SenseFavItem(
        id: d.id,
        name: d.name,
        description: d.description,
        icon: d.icon,
        group: d.group,
        pane: d.pane,
        ask: d.ask,
        keys: d.keys,
        available: available,
      );

  final String id;
  final String name;
  final String description;
  final IconData icon;
  final SenseFavGroup group;
  final SenseFavPane pane;
  final SenseFavAsk? ask;
  final SenseFavKeys? keys;
  final bool custom;

  /// A custom shortcut waiting for a Yönetici (K8): shown, never run.
  final bool pending;

  /// The core said this computer cannot run it (e.g. no admin step on a portable copy).
  final bool available;
}

/// One chosen shortcut and its key slot (1–9, or none).
@immutable
class SenseFavChoice {
  const SenseFavChoice(this.id, [this.key]);
  final String id;
  final int? key;

  Map<String, Object?> toJson() => {'id': id, 'key': key};
}

/// The IP card under "IP bilgisi".
@immutable
class SenseFavIpInfo {
  const SenseFavIpInfo({this.ip, this.gateway = const [], this.dns = const []});
  final String? ip;
  final List<String> gateway;
  final List<String> dns;

  bool get empty => ip == null && gateway.isEmpty && dns.isEmpty;
}

/// The IP card from what the Bilgisayar durumu popup already reads: the first connected
/// adapter's address, its gateway and DNS (the same order as the status popup).
SenseFavIpInfo senseFavIpInfoFrom(SensePeerStatus? status, SenseInventory? inventory) {
  final inv = inventory?.network ?? const <SenseInvNetwork>[];
  int rank(String k) => k == 'ethernet' ? 0 : (k == 'wifi' ? 1 : 2);
  final adapters = List.of(status?.network ?? const [])..sort((a, b) => rank(a.kind).compareTo(rank(b.kind)));
  for (final a in adapters) {
    if (a.up == false || a.ipv4.isEmpty) continue;
    SenseInvNetwork? i;
    for (final x in inv) {
      if (x.name == a.name) i = x;
    }
    if (i?.connected == false) continue;
    return SenseFavIpInfo(ip: a.ipv4.first.split('/').first, gateway: i?.gateway ?? const [], dns: i?.dns ?? const []);
  }
  for (final i in inv) {
    if (i.connected == true && (i.gateway.isNotEmpty || i.dns.isNotEmpty)) {
      return SenseFavIpInfo(gateway: i.gateway, dns: i.dns);
    }
  }
  return const SenseFavIpInfo();
}

/// The Host's answer to a pane request (ping, window list, IP card).
@immutable
class SenseFavAnswer {
  const SenseFavAnswer({required this.ok, this.err, this.res});
  final bool ok;
  final String? err;
  final Map<String, dynamic>? res;
}

/// One window (Windows) or app (macOS) of the Host's signed-in user (`res.windows`).
@immutable
class SenseFavWindow {
  const SenseFavWindow({required this.pid, required this.name, this.hung = false});
  final int pid;
  final String name;
  final bool hung;
}

/// `res.windows` → rows; entries without a process id or a name are left out.
List<SenseFavWindow>? senseFavWindowsFrom(Map<String, dynamic>? res) {
  final list = res?['windows'];
  if (list is! List) return null;
  final out = <SenseFavWindow>[];
  for (final w in list) {
    if (w is! Map) continue;
    final pid = int.tryParse('${w['pid']}');
    final name = '${w['name'] ?? ''}'.trim();
    if (pid == null || pid <= 0 || name.isEmpty) continue;
    out.add(SenseFavWindow(pid: pid, name: name, hung: w['hung'] == true || '${w['hung']}' == 'true'));
  }
  return out;
}

/// `res.ip` → the IP card; null when the body has none.
SenseFavIpInfo? senseFavIpFromRes(Map<String, dynamic>? res) {
  final ip = res?['ip'];
  if (ip is! Map) return null;
  List<String> list(Object? v) =>
      v is List ? [for (final e in v) if ('$e'.trim().isNotEmpty) '$e'.trim()] : const <String>[];
  final addr = ip['ip'];
  return SenseFavIpInfo(
    ip: addr == null || '$addr'.trim().isEmpty ? null : '$addr'.trim(),
    gateway: list(ip['gateway']),
    dns: list(ip['dns']),
  );
}

/// `res.ping` → "4/4 yanıt · ort. 18 ms · kayıp %0"; null when the body has none.
String? senseFavPingText(Map<String, dynamic>? res) {
  final p = res?['ping'];
  if (p is! Map) return null;
  int? n(Object? v) => v == null ? null : (v is num ? v.round() : int.tryParse('$v'));
  final sent = n(p['sent']), got = n(p['received']);
  if (sent == null || got == null) return null;
  final loss = n(p['loss']) ?? (sent == 0 ? 100 : ((sent - got) * 100 / sent).round());
  return SenseFavoritesStrings.pingLine(got, sent, got == 0 ? null : n(p['avg_ms']), loss);
}

/// The ping address as the Host takes it (`shortcuts::results::arg_problem`): 1–253 letters,
/// digits, `.`, `-`, `:`; not starting with `-` or `.`. Never put through a shell.
bool senseFavPingAddressOk(String a) =>
    a.isNotEmpty &&
    a.length <= 253 &&
    !a.startsWith('-') &&
    !a.startsWith('.') &&
    RegExp(r'^[A-Za-z0-9.:-]+$').hasMatch(a);

/// What the custom shortcut form sends (K3: no arguments; https only; absolute paths).
enum SenseFavCustomKind { program, folder, url }

enum SenseFavCustomScope { pc, project, all }

@immutable
class SenseFavCustomForm {
  const SenseFavCustomForm({
    required this.name,
    required this.os,
    required this.kind,
    required this.target,
    required this.scope,
  });
  final String name;
  final SenseFavOs os;
  final SenseFavCustomKind kind;
  final String target;
  final SenseFavCustomScope scope;
}

/// Why the form cannot be sent, or null when it can (checked again by the panel).
String? senseFavCustomFormError(SenseFavCustomForm f) {
  final name = f.name.trim(), target = f.target.trim();
  if (name.isEmpty || target.isEmpty) return SenseFavoritesStrings.formMissing;
  if (name.length > 60) return SenseFavoritesStrings.formTooLong;
  if (f.kind == SenseFavCustomKind.url) {
    final u = Uri.tryParse(target);
    if (u == null || u.scheme != 'https' || u.host.isEmpty || target.contains(' ')) {
      return SenseFavoritesStrings.formBadUrl;
    }
    return null;
  }
  // An absolute path and nothing after it: no quotes, no switches, no second command.
  final windowsPath = RegExp(r'^([A-Za-z]:\\|\\\\)[^"<>|*?\r\n]*$');
  final unixPath = RegExp(r'^/[^"<>|*?\r\n]*$');
  final ok = windowsPath.hasMatch(target) || unixPath.hasMatch(target);
  if (!ok || RegExp(r'\s-{1,2}\w|\s/\w|&&|;').hasMatch(target)) return SenseFavoritesStrings.formBadPath;
  return null;
}

/// Description of a custom row: "Program · yalnız bu bilgisayar".
String senseFavCustomDescription(String kind, String scope) {
  final k = switch (kind) {
    'folder' => SenseFavoritesStrings.kindFolder,
    'url' => SenseFavoritesStrings.kindUrl,
    _ => SenseFavoritesStrings.kindProgram,
  };
  final s = switch (scope) {
    'project' => SenseFavoritesStrings.scopeProject,
    'all' => SenseFavoritesStrings.scopeAll,
    _ => SenseFavoritesStrings.scopePc,
  };
  return '$k · $s';
}

IconData _customIcon(String kind) => switch (kind) {
      'folder' => Icons.folder_outlined,
      'url' => Icons.public_rounded,
      _ => Icons.play_arrow_rounded,
    };

/// The text of a Host error code.
String senseFavErrorText(String? code) => switch (code) {
      'unknown_id' => SenseFavoritesStrings.errUnknownId,
      'no_permission' => SenseFavoritesStrings.errNoPermission,
      'unsupported_os' => SenseFavoritesStrings.errUnsupportedOs,
      'needs_admin' => SenseFavoritesStrings.errNeedsAdmin,
      'timeout' => SenseFavoritesStrings.errTimeout,
      _ => SenseFavoritesStrings.errFailed,
    };

/// Choices kept in memory while the core cannot store them (per system, for the app run).
final Map<SenseFavOs, (List<SenseFavChoice>, List<String>)> _memory = {};

/// Pending custom requests of this app run (the panel lists only approved ones).
final List<SenseFavItem> _pendingCustom = [];
final Map<String, SenseFavOs> _pendingOs = {};

/// Clears the in-memory choices (tests).
@visibleForTesting
void senseFavResetMemory() {
  _memory.clear();
  _pendingCustom.clear();
  _pendingOs.clear();
}

class SenseFavoritesModel extends ChangeNotifier {
  SenseFavoritesModel({
    required this.io,
    SenseFavOs? os,
    this.peerId = '',
    this.computerName = '',
    bool inputAllowed = true,
    this.localMac = false,
    this.runTimeout = const Duration(seconds: 8),
    this.pingTimeout = const Duration(seconds: 30),
    this.ipInfo,
    this.onNotice,
  })  : _os = os,
        _inputAllowed = inputAllowed {
    if (peerId.isNotEmpty) SenseFavoritesEvents.listen(peerId, _onResult);
    SenseFavoritesEvents.listenPrefs(_onPrefsChanged);
  }

  final SenseFavoritesIo io;
  final String peerId;

  /// Shown in "Görev Yöneticisi açıldı · Giriş Salonu PC-2".
  String computerName;

  /// This (Controller) computer is a Mac: key labels say Cmd+Option+Shift (K4).
  final bool localMac;
  final Duration runTimeout;

  /// Four pings to an address that does not answer take up to ~16 s on Windows.
  final Duration pingTimeout;

  /// The IP card's values (the session wires the status popup's data here).
  SenseFavIpInfo Function()? ipInfo;

  /// Short notification (T7 toast); the session bar shows it.
  ValueChanged<String>? onNotice;

  SenseFavOs? _os;
  bool _inputAllowed;
  bool _loading = false;
  bool _loaded = false;
  bool _accountSaves = true;
  Map<String, SenseFavCoreEntry> _core = const {};
  List<SenseFavChoice> _chosen = [];
  List<String> _recent = [];
  List<SenseFavItem> _approved = [];
  int _seq = 0;
  final Map<int, (String, Timer, Completer<SenseFavAnswer>?)> _waiting = {};
  bool _disposed = false;

  SenseFavOs? get os => _os;
  bool get inputAllowed => _inputAllowed;
  bool get loading => _loading;
  bool get loaded => _loaded;

  /// The choice is kept in the employee's account (false: only for this app run).
  bool get accountSaves => _accountSaves;

  /// The core sent a catalogue (FAV-Ç is in this build).
  bool get coreCatalog => _core.isNotEmpty;

  List<SenseFavChoice> get chosen => List.unmodifiable(_chosen);

  /// Chosen rows in their order (unknown ids are left out).
  List<SenseFavItem> get mine => [for (final c in _chosen) if (item(c.id) case final it?) it];

  /// The last used, newest first, at most [kSenseFavShownRecent].
  List<SenseFavItem> get recent =>
      [for (final id in _recent) if (item(id) case final it?) it].take(kSenseFavShownRecent).toList();

  /// Every row of the current system: built-in, approved custom, pending custom.
  List<SenseFavItem> get all {
    final os = _os;
    if (os == null) return const [];
    return [
      for (final d in senseFavCatalogOf(os)) SenseFavItem.of(d, available: _core[d.id]?.available ?? true),
      ..._approved,
      for (final p in _pendingCustom)
        if (_pendingOs[p.id] == os) p,
    ];
  }

  SenseFavItem? item(String id) {
    for (final it in all) {
      if (it.id == id) return it;
    }
    return null;
  }

  bool isChosen(String id) => _chosen.any((c) => c.id == id);

  int? keyOf(String id) {
    for (final c in _chosen) {
      if (c.id == id) return c.key;
    }
    return null;
  }

  String keyLabel(int n) => SenseFavoritesStrings.keyLabel(n, mac: localMac);

  void _notice(String m) => onNotice?.call(m);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Session facts
  // ---------------------------------------------------------------------------

  /// The peer's system became known or changed: load that system's list (#163).
  void setOs(SenseFavOs? os) {
    if (os == _os) return;
    _os = os;
    _loaded = false;
    _chosen = [];
    _recent = [];
    _approved = [];
    _core = const {};
    _changed();
    if (os != null) load();
  }

  /// Keyboard and mouse permission (and not "Yalnız izle"): without it every row is grey.
  void setInputAllowed(bool v) {
    if (v == _inputAllowed) return;
    _inputAllowed = v;
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Load and store
  // ---------------------------------------------------------------------------

  static Object? _decode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  Future<void> load() async {
    final os = _os;
    if (os == null || os == SenseFavOs.linux) {
      _loaded = true;
      _changed();
      return;
    }
    _loading = true;
    _changed();
    Map<String, SenseFavCoreEntry> core = const {};
    try {
      core = senseFavParseCoreCatalog(_decode(await io.catalog(os)));
    } catch (_) {}
    String prefs = '';
    try {
      prefs = await io.prefsGet(os);
    } catch (_) {}
    if (_disposed || os != _os) return;
    _core = core;
    _applyPrefs(os, _decode(prefs));
    _loading = false;
    _loaded = true;
    _changed();
  }

  void _applyPrefs(SenseFavOs os, Object? decoded) {
    if (decoded is! Map || decoded['error'] != null || decoded['entries'] is! List) {
      // The core cannot keep preferences yet: this app run's memory.
      _accountSaves = false;
      final m = _memory[os];
      _chosen = List.of(m?.$1 ?? const []);
      _recent = List.of(m?.$2 ?? const []);
      _approved = [];
      return;
    }
    _accountSaves = true;
    List<SenseFavChoice> chosen = [];
    List<String> recent = [];
    for (final e in decoded['entries'] as List) {
      if (e is! Map || e['os'] != os.code) continue;
      final v = e['value'];
      if (e['key'] == 'fav.items' && v is List) {
        final seenKeys = <int>{};
        for (final x in v) {
          if (x is! Map || x['id'] is! String) continue;
          final id = x['id'] as String;
          if (chosen.any((c) => c.id == id)) continue;
          var k = x['key'] is int ? x['key'] as int : null;
          if (k != null && (k < 1 || k > 9 || !seenKeys.add(k))) k = null;
          chosen.add(SenseFavChoice(id, k));
          if (chosen.length >= kSenseFavMaxItems) break;
        }
      } else if (e['key'] == 'fav.recent' && v is List) {
        recent = [for (final x in v) if (x is String) x].take(kSenseFavMaxRecent).toList();
      }
    }
    final approved = <SenseFavItem>[];
    final custom = decoded['custom'];
    if (custom is List) {
      for (final c in custom) {
        if (c is! Map || c['os'] != os.code) continue;
        final id = c['id'], label = c['label'];
        if (id is! String || label is! String) continue;
        final cid = id.startsWith(kSenseFavCustomPrefix) ? id : '$kSenseFavCustomPrefix$id';
        final kind = '${c['kind']}', scope = '${c['scope']}';
        approved.add(SenseFavItem(
          id: cid,
          name: label,
          description: senseFavCustomDescription(kind, scope),
          icon: _customIcon(kind),
          group: SenseFavGroup.custom,
          custom: true,
        ));
        _pendingCustom.removeWhere((p) => p.name == label && _pendingOs[p.id] == os);
      }
    }
    _chosen = chosen;
    _recent = recent;
    _approved = approved;
  }

  void _onPrefsChanged() {
    if (_os != null && _loaded) load();
  }

  Future<void> _store({bool items = true, bool recent = false}) async {
    final os = _os;
    if (os == null) return;
    _memory[os] = (List.of(_chosen), List.of(_recent));
    if (!_accountSaves) return;
    final entries = [
      if (items) {'os': os.code, 'key': 'fav.items', 'value': [for (final c in _chosen) c.toJson()]},
      if (recent) {'os': os.code, 'key': 'fav.recent', 'value': _recent},
    ];
    try {
      final r = await io.prefsSet(jsonEncode({'entries': entries}));
      if (r == 'unsupported' && !_disposed) {
        _accountSaves = false;
        _changed();
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Choosing
  // ---------------------------------------------------------------------------

  /// Adds [id] to "Kısayollarım" or takes it out (the catalogue's tick).
  void toggle(String id) {
    final it = item(id);
    if (it == null) return;
    final i = _chosen.indexWhere((c) => c.id == id);
    if (i >= 0) {
      _chosen.removeAt(i);
      _notice(SenseFavoritesStrings.removed(it.name));
    } else {
      if (_chosen.length >= kSenseFavMaxItems) {
        _notice(SenseFavoritesStrings.tooMany);
        return;
      }
      _chosen.add(SenseFavChoice(id));
      _notice(SenseFavoritesStrings.added(it.name));
    }
    _changed();
    _store();
  }

  /// Drag to reorder (indexes of [mine]).
  void reorder(int from, int to) {
    final ids = [for (final m in mine) m.id];
    if (from < 0 || from >= ids.length || to < 0 || to > ids.length) return;
    final id = ids.removeAt(from);
    ids.insert(to > from ? to - 1 : to, id);
    final byId = {for (final c in _chosen) c.id: c};
    final rest = _chosen.where((c) => !ids.contains(c.id));
    _chosen = [for (final x in ids) byId[x]!, ...rest];
    _changed();
    _store();
  }

  /// Gives [id] key slot [n] (1–9) or none; a slot belongs to one shortcut only.
  void setKey(String id, int? n) {
    if (n != null && (n < 1 || n > 9)) return;
    _chosen = [
      for (final c in _chosen)
        if (c.id == id) SenseFavChoice(id, n) else if (n != null && c.key == n) SenseFavChoice(c.id) else c,
    ];
    _changed();
    _store();
  }

  void _markRecent(String id) {
    _recent.remove(id);
    _recent.insert(0, id);
    if (_recent.length > kSenseFavMaxRecent) _recent = _recent.sublist(0, kSenseFavMaxRecent);
    _changed();
    _store(items: false, recent: true);
  }

  /// A pane row was opened (IP card, ping, window list): it counts as used.
  void opened(String id) {
    if (item(id) != null) _markRecent(id);
  }

  // ---------------------------------------------------------------------------
  // Running
  // ---------------------------------------------------------------------------

  /// Runs [id] (a row that asks has been confirmed already). Grey rows do nothing.
  Future<void> run(String id) async {
    final it = item(id);
    if (it == null || !_inputAllowed) return;
    if (it.pending) {
      _notice(SenseFavoritesStrings.pendingRun(it.name));
      return;
    }
    if (!it.available) {
      _notice(SenseFavoritesStrings.failed(it.name, SenseFavoritesStrings.unavailable));
      return;
    }
    _markRecent(id);
    final core = _core[id];
    final keys = it.keys;
    if (keys != null && (core == null || core.kind == 'keys')) {
      final ok = io.sendKeys(keys);
      _notice(ok
          ? SenseFavoritesStrings.opened(it.name, computerName)
          : SenseFavoritesStrings.failed(it.name, SenseFavoritesStrings.errNotSent));
      return;
    }
    final req = ++_seq;
    String sent;
    try {
      sent = await io.send(kSenseShortcutRunMsg, jsonEncode({'req': req, 'id': id}));
    } catch (_) {
      sent = 'failed';
    }
    if (_disposed) return;
    if (sent.isNotEmpty) {
      _notice(SenseFavoritesStrings.failed(it.name, SenseFavoritesStrings.errNotSent));
      return;
    }
    _waiting[req] = (id, Timer(runTimeout, () => _onResult(req, false, 'timeout', null)), null);
  }

  /// Asks the Host for a pane's answer (ping, window list, IP card, closing a window): the
  /// answer comes back here instead of a toast. `err` is a Host code, `not_sent` when the
  /// message could not go, `timeout` when no answer came (an older Host never answers).
  Future<SenseFavAnswer> request(String id, {String? arg, Duration? timeout}) async {
    if (!_inputAllowed) return const SenseFavAnswer(ok: false, err: 'no_permission');
    final req = ++_seq;
    String sent;
    try {
      sent = await io.send(kSenseShortcutRunMsg, jsonEncode({'req': req, 'id': id, if (arg != null) 'arg': arg}));
    } catch (_) {
      sent = 'failed';
    }
    if (_disposed) return const SenseFavAnswer(ok: false, err: 'failed');
    if (sent.isNotEmpty) return const SenseFavAnswer(ok: false, err: 'not_sent');
    final done = Completer<SenseFavAnswer>();
    _waiting[req] = (id, Timer(timeout ?? runTimeout, () => _onResult(req, false, 'timeout', null)), done);
    return done.future;
  }

  /// The IP card from the Host (`res.ip`); null when it did not answer with one.
  Future<SenseFavIpInfo?> hostIpInfo(String id) async {
    final a = await request(id);
    return a.ok ? senseFavIpFromRes(a.res) : null;
  }

  /// The Host's windows / apps (`res.windows`), or the reason they are not there.
  Future<(List<SenseFavWindow>?, String?)> windows(String id) async {
    final a = await request(id);
    if (!a.ok) return (null, a.err == 'timeout' ? SenseFavoritesStrings.windowsUnsupported : _paneError(a.err));
    final list = senseFavWindowsFrom(a.res);
    return list == null ? (null, SenseFavoritesStrings.windowsUnsupported) : (list, null);
  }

  /// Closes one window / app on the Host (`arg`: its process id); null when closed, else why.
  Future<String?> closeWindow(String id, SenseFavWindow w) async {
    final a = await request(id, arg: '${w.pid}');
    if (!a.ok) return _paneError(a.err);
    _notice(SenseFavoritesStrings.windowClosed(w.name, computerName));
    return null;
  }

  String _paneError(String? err) =>
      err == 'not_sent' ? SenseFavoritesStrings.errNotSent : senseFavErrorText(err);

  /// Hotkey slot [n] (Ctrl+Alt+Shift+n): true when a shortcut holds it (the key is used).
  bool runSlot(int n) {
    for (final c in _chosen) {
      if (c.key != n) continue;
      final it = item(c.id);
      if (it == null) return false;
      if (!_inputAllowed) {
        _notice(SenseFavoritesStrings.needsInput);
      } else if (it.ask != null || it.pane != SenseFavPane.none) {
        _notice(SenseFavoritesStrings.fromList(it.name));
      } else {
        run(c.id);
      }
      return true;
    }
    return false;
  }

  void _onResult(int req, bool ok, String? err, Map<String, dynamic>? res) {
    final w = _waiting.remove(req);
    if (w == null || _disposed) return;
    w.$2.cancel();
    final done = w.$3;
    if (done != null) {
      if (!done.isCompleted) done.complete(SenseFavAnswer(ok: ok, err: err, res: res));
      return;
    }
    final it = item(w.$1);
    final name = it?.name ?? w.$1;
    _notice(ok
        ? SenseFavoritesStrings.opened(name, computerName)
        : SenseFavoritesStrings.failed(name, senseFavErrorText(err)));
  }

  /// Ping from the Host (#171): the address goes as `arg`, the counts come back in `res.ping`.
  /// A Host without the result body (or one that never answers) says so calmly.
  Future<String> ping(String id, String address) async {
    final a = address.trim();
    if (a.isEmpty) return SenseFavoritesStrings.pingEmpty;
    if (!senseFavPingAddressOk(a)) return SenseFavoritesStrings.pingBadAddress;
    final r = await request(id, arg: a, timeout: pingTimeout);
    if (!r.ok) return r.err == 'timeout' ? SenseFavoritesStrings.pingUnsupported : _paneError(r.err);
    return senseFavPingText(r.res) ?? SenseFavoritesStrings.pingUnsupported;
  }

  // ---------------------------------------------------------------------------
  // Custom shortcuts (#161, K3, K8)
  // ---------------------------------------------------------------------------

  /// Sends the form to the panel; null when sent (then it waits for a Yönetici), else the
  /// reason shown under the form.
  Future<String?> requestCustom(SenseFavCustomForm f) async {
    final bad = senseFavCustomFormError(f);
    if (bad != null) return bad;
    final kind = f.kind.name;
    final body = {
      'os': f.os.code,
      'kind': kind,
      'label': f.name.trim(),
      'target': f.target.trim(),
      // Plan §2.2 scope person | project | all; "yalnız bu bilgisayar" is asked for this one.
      'scope': switch (f.scope) {
        SenseFavCustomScope.pc => 'person',
        SenseFavCustomScope.project => 'project',
        SenseFavCustomScope.all => 'all',
      },
      if (f.scope == SenseFavCustomScope.pc && peerId.isNotEmpty) 'scope_ref': peerId,
    };
    String r;
    try {
      r = await io.customRequest(jsonEncode(body));
    } catch (_) {
      return SenseFavoritesStrings.formFailed;
    }
    final d = _decode(r);
    if (d is Map && d['error'] == 'unsupported') return SenseFavoritesStrings.formUnsupported;
    if (d is! Map || d['id'] is! String) return SenseFavoritesStrings.formFailed;
    final id = '${kSenseFavCustomPrefix}pending-${d['id']}';
    final scope = body['scope'] as String;
    _pendingCustom.add(SenseFavItem(
      id: id,
      name: f.name.trim(),
      description: senseFavCustomDescription(kind, scope),
      icon: _customIcon(kind),
      group: SenseFavGroup.custom,
      custom: true,
      pending: true,
    ));
    _pendingOs[id] = f.os;
    _notice(SenseFavoritesStrings.customSent(f.os.label));
    _changed();
    return null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final w in _waiting.values) {
      w.$2.cancel();
      final done = w.$3;
      if (done != null && !done.isCompleted) done.complete(const SenseFavAnswer(ok: false, err: 'failed'));
    }
    _waiting.clear();
    if (peerId.isNotEmpty) SenseFavoritesEvents.forget(peerId, _onResult);
    SenseFavoritesEvents.forgetPrefs(_onPrefsChanged);
    if (identical(SenseFavoritesHotkeysRegistry.active, this)) SenseFavoritesHotkeysRegistry.active = null;
    super.dispose();
  }
}

/// The model the hotkeys go to: the session window that is in front (set by its list).
abstract final class SenseFavoritesHotkeysRegistry {
  static SenseFavoritesModel? active;
}
