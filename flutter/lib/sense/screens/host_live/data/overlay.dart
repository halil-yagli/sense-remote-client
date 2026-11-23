// Sense Remote: Host overlay state (YH H3, H4; plan §2.6 "D1 Host durumu"):
// who is connected and since when, which permissions, and whether the
// Controller records the connection (D1 CM event `sense_recording` {id, on},
// also in the client JSON as `sense_recording`).

import 'dart:async';
import 'dart:convert';

import '../../../../models/platform_model.dart';
import '../../../../models/server_model.dart';
import '../../../strings/host_live.dart';

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

/// Keeps `Client.senseRecording` current. D1 pushes `sense_recording` on the
/// CM event stream, but RustDesk's event switch (models/model.dart) does not
/// route it yet, so the state is read from `cm_get_clients_state` (which
/// carries the same flag) every [every].
// TODO(D1): route the `sense_recording` CM event in models/model.dart to
// `serverModel.senseUpdateRecording(id, on)`; then this poll can go.
class SenseHostRecordingWatch {
  SenseHostRecordingWatch({
    required this.onRecording,
    Future<String> Function()? readState,
    this.every = const Duration(seconds: 1),
  }) : _read = readState ?? (() => bind.cmGetClientsState());

  final void Function(int id, bool on) onRecording;
  final Future<String> Function() _read;
  final Duration every;
  Timer? _t;
  bool _busy = false;

  void start() {
    _t ??= Timer.periodic(every, (_) => poll());
  }

  Future<void> poll() async {
    if (_busy) return;
    _busy = true;
    try {
      senseParseRecording(await _read()).forEach(onRecording);
    } catch (_) {
      // The CM may be closing; the next tick tries again.
    } finally {
      _busy = false;
    }
  }

  void stop() {
    _t?.cancel();
    _t = null;
  }
}
