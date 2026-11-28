// Sense Remote: what the Controllers on this Host asked for (Sürüm 12, #151, #157). The core
// answers `main_sense_host_peer_state()`:
//   {"chat_visible": [conn_id], "admin_terminals": [{conn_id, by}]}
// `chat_visible`: the Controller asked to see this card in the screen it watches (#151).
// `admin_terminals`: a terminal on this computer runs as administrator, opened by `by`
// (the account's e-mail; #157). Only live connections are listed; both go away with the
// connection. Broken input is "nothing asked", never an exception.

import 'dart:async';
import 'dart:convert';

import '../../../../models/platform_model.dart';
import '../../../strings/host_live.dart';

class SenseHostAdminTerminal {
  const SenseHostAdminTerminal(this.connId, this.by);
  final int connId;
  final String by;

  @override
  bool operator ==(Object other) =>
      other is SenseHostAdminTerminal && other.connId == connId && other.by == by;

  @override
  int get hashCode => Object.hash(connId, by);
}

class SenseHostPeerState {
  const SenseHostPeerState({this.chatVisible = const {}, this.admins = const []});

  final Set<int> chatVisible;
  final List<SenseHostAdminTerminal> admins;

  static const SenseHostPeerState none = SenseHostPeerState();

  factory SenseHostPeerState.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return none;
      final chat = <int>{};
      final c = v['chat_visible'];
      if (c is List) {
        for (final id in c) {
          if (id is int) chat.add(id);
        }
      }
      final admins = <SenseHostAdminTerminal>[];
      final a = v['admin_terminals'];
      if (a is List) {
        for (final e in a) {
          if (e is! Map) continue;
          final id = e['conn_id'];
          if (id is! int) continue;
          final by = e['by'];
          admins.add(SenseHostAdminTerminal(id, by is String ? by.trim() : ''));
        }
      }
      return SenseHostPeerState(chatVisible: chat, admins: admins);
    } catch (_) {
      return none;
    }
  }

  /// #151: the card is in the picture the Controller watches.
  bool get chatShown => chatVisible.isNotEmpty;

  /// #157: "Yönetici terminali açık · mevlut@…" (the accounts once each, in order of
  /// appearance); null when no admin terminal is open.
  String? get adminLine {
    if (admins.isEmpty) return null;
    final who = <String>[];
    for (final a in admins) {
      if (a.by.isNotEmpty && !who.contains(a.by)) who.add(a.by);
    }
    return who.isEmpty
        ? SenseHostLiveStrings.adminTerminal
        : SenseHostLiveStrings.adminTerminalBy(who.join(', '));
  }

  @override
  bool operator ==(Object other) =>
      other is SenseHostPeerState &&
      other.chatVisible.length == chatVisible.length &&
      other.chatVisible.containsAll(chatVisible) &&
      _sameAdmins(other.admins);

  bool _sameAdmins(List<SenseHostAdminTerminal> o) {
    if (o.length != admins.length) return false;
    for (var i = 0; i < o.length; i++) {
      if (o[i] != admins[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(chatVisible), Object.hashAll(admins));
}

/// Reads the state now and then while the card is up; calls [onState] with each answer.
class SenseHostPeerWatch {
  SenseHostPeerWatch({
    required this.onState,
    Future<String> Function()? read,
    this.every = const Duration(seconds: 2),
  }) : _read = read ?? (() => bind.mainSenseHostPeerState());

  final void Function(SenseHostPeerState state) onState;
  final Future<String> Function() _read;
  final Duration every;
  Timer? _timer;
  bool _busy = false;

  void start() {
    poll();
    _timer ??= Timer.periodic(every, (_) => poll());
  }

  Future<void> poll() async {
    if (_busy) return;
    _busy = true;
    try {
      onState(SenseHostPeerState.parse(await _read()));
    } catch (_) {
      // The core may be closing; the next reading tries again.
    } finally {
      _busy = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
