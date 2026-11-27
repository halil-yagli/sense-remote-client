// Sense Remote: Host overlay state (YH H3, H4; plan §2.6 "D1 Host durumu"):
// who is connected and since when, which permissions, and whether the
// Controller records the connection (D1 CM event `sense_recording` {id, on},
// also in the client JSON as `sense_recording`).

import 'dart:convert';

import '../../../../models/platform_model.dart';
import '../../../../models/server_model.dart';
import '../../../strings/host_live.dart';
import '../sense_cm_style.dart' show senseCmKindText;

/// `sense_recording` of every connection in a `cm_get_clients_state` JSON.
/// Broken input gives an empty map, never an exception.
Map<int, bool> senseParseRecording(String raw) {
  try {
    final data = jsonDecode(raw);
    if (data is! List) return const {};
    final out = <int, bool>{};
    for (final c in data) {
      if (c is! Map) continue;
      final id = c['id'];
      if (id is! int) continue;
      out[id] = c['sense_recording'] == true;
    }
    return out;
  } catch (_) {
    return const {};
  }
}

/// Permissions of the who line, in a fixed order: only the ones that are on
/// ("ekran, fare ve klavye, dosya").
List<String> senseHostPermissions(Client c) => [
      if (c.type_() == ClientType.remote || c.type_() == ClientType.camera)
        SenseHostLiveStrings.permScreen,
      if (c.keyboard) SenseHostLiveStrings.permInput,
      if (c.file) SenseHostLiveStrings.permFile,
      if (c.clipboard) SenseHostLiveStrings.permClipboard,
      if (c.audio) SenseHostLiveStrings.permAudio,
      if (c.restart) SenseHostLiveStrings.permRestart,
      if (c.recording) SenseHostLiveStrings.permRecording,
    ];

/// "Halil Y. · 14 dk · ekran, fare ve klavye, dosya".
String senseHostWhoLine(Client c, Duration? connected) => SenseHostLiveStrings.who(
      c.name.trim(),
      connected == null ? '' : SenseHostLiveStrings.minutes(connected),
      senseHostPermissions(c).join(', '),
    );

/// O6: the connections that are on now (accepted, not ended). The same
/// Controller may hold several: the screen, then a terminal or a TCP tunnel
/// (S8 lets the same Controller in again).
List<Client> senseHostLive(Iterable<Client> clients) =>
    clients.where((c) => c.authorized && !c.disconnected).toList();

/// O6: "2 bağlantı · ekran, terminal" when more than one connection is on;
/// null for one (the who line says enough). Kinds once each, screen first.
String? senseHostConnectionsLine(List<Client> live) {
  if (live.length < 2) return null;
  const order = [
    SenseHostLiveStrings.kindScreen,
    SenseHostLiveStrings.kindCamera,
    SenseHostLiveStrings.kindFile,
    SenseHostLiveStrings.kindTerminal,
    SenseHostLiveStrings.kindTunnel,
  ];
  final kinds = live.map(senseCmKindText).toSet().toList()
    ..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
  return SenseHostLiveStrings.connections(live.length, kinds);
}

/// O6: "Bağlantıyı bitir" / "Tümünü bitir" ends every connection that is on,
/// not only the one the card shows; [shown] when none is on (still closing).
void senseHostEndAll(List<Client> live, Client shown, void Function(Client c) close) {
  for (final c in live.isEmpty ? [shown] : live) {
    close(c);
  }
}

/// When each connection was first seen authorized and when its recording
/// started (the event gives only on/off; the strip counts from the first "on").
class SenseHostClock {
  SenseHostClock({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<int, DateTime> _connected = {};
  final Map<int, DateTime> _recording = {};

  DateTime now() => _now();

  /// Takes the current client list.
  void update(Iterable<Client> clients) {
    final at = _now();
    final ids = clients.map((c) => c.id).toSet();
    _connected.removeWhere((id, _) => !ids.contains(id));
    _recording.removeWhere((id, _) => !ids.contains(id));
    for (final c in clients) {
      if (c.authorized && !c.disconnected) _connected.putIfAbsent(c.id, () => at);
      if (c.senseRecording && !c.disconnected) {
        _recording.putIfAbsent(c.id, () => at);
      } else {
        _recording.remove(c.id);
      }
    }
  }

  Duration? connectedFor(int id) {
    final s = _connected[id];
    return s == null ? null : _now().difference(s);
  }

  Duration? recordingFor(int id) {
    final s = _recording[id];
    return s == null ? null : _now().difference(s);
  }
}

/// Keeps `Client.senseRecording` current. Changes arrive as the CM event
/// `sense_recording` {id, on} (routed in models/model.dart to
/// `serverModel.senseUpdateRecording`); this reads the state once when the
/// card opens (`cm_get_clients_state` carries the same flag), for a recording
/// that started before.
class SenseHostRecordingWatch {
  SenseHostRecordingWatch({
    required this.onRecording,
    Future<String> Function()? readState,
  }) : _read = readState ?? (() => bind.cmGetClientsState());

  final void Function(int id, bool on) onRecording;
  final Future<String> Function() _read;
  bool _busy = false;

  /// One reading of the current state; later changes come as events.
  void start() {
    poll();
  }

  Future<void> poll() async {
    if (_busy) return;
    _busy = true;
    try {
      senseParseRecording(await _read()).forEach(onRecording);
    } catch (_) {
      // The CM may be closing; the events keep the state from here on.
    } finally {
      _busy = false;
    }
  }

  void stop() {}
}
