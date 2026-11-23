// Sense Remote: the Host state of the status box (YH H1, six states).
// Real sources: connection server state (`stateGlobal.svcStatus`), the stopped
// service flag, the video connection count and macOS permissions. Who is
// connected and since when comes with D1 (Host overlay: `connected_by`, `since`).
import 'dart:convert';

import '../../../../models/platform_model.dart';
import '../../../../common.dart' show gFFI;
import '../../../../models/server_model.dart' show Client;
import '../../../../models/state_model.dart';

enum SenseHostPhase { ready, connecting, down, stopped, mac, busy }

/// Pure: the state of the status box. A stopped service and a missing macOS
/// permission win over the rest; a connection shows as "Bağlı".
SenseHostPhase senseHostPhase({
  required SvcStatus svc,
  required bool stopped,
  required bool macBlocked,
  required int connections,
}) {
  if (stopped) return SenseHostPhase.stopped;
  if (macBlocked) return SenseHostPhase.mac;
  if (connections > 0) return SenseHostPhase.busy;
  switch (svc) {
    case SvcStatus.ready:
      return SenseHostPhase.ready;
    case SvcStatus.connecting:
      return SenseHostPhase.connecting;
    case SvcStatus.notReady:
      return SenseHostPhase.down;
  }
}

/// Who is connected (D1). Null fields = not known.
class SenseHostLive {
  const SenseHostLive({this.connectedBy, this.since});
  final String? connectedBy;

  /// Unix seconds.
  final int? since;

  factory SenseHostLive.parse(String raw) {
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return const SenseHostLive();
      final by = v['connected_by'];
      return SenseHostLive(
        connectedBy: by is String && by.isNotEmpty ? by : null,
        since: v['since'] is int ? v['since'] as int : null,
      );
    } catch (_) {
      return const SenseHostLive();
    }
  }
}

/// "Yeniden dene": asks the service to check the connection server again.
Future<void> senseHostRetry() async {
  stateGlobal.svcStatus.value = SvcStatus.connecting;
  await bind.mainCheckConnectStatus();
}

/// Pure: the "who is connected" JSON from the clients of the server model. Only an authorized,
/// open, remote-screen connection counts (not a file transfer, not a closed one). The start
/// time is not in the bridge (the Rust side keeps `since` only in the recent list), so
/// `since` stays out and the page counts from when it saw the connection (P3, B4).
String senseHostLiveFrom(Iterable<Client> clients) {
  for (final c in clients) {
    if (c.authorized &&
        !c.disconnected &&
        !c.isFileTransfer &&
        !c.isTerminal &&
        c.portForward.isEmpty &&
        c.name.isNotEmpty) {
      return jsonEncode({'connected_by': c.name});
    }
  }
  return '{}';
}

/// Who is connected now, read from the live server model (no bridge function needed).
Future<String> senseHostLiveRaw() async => senseHostLiveFrom(gFFI.serverModel.clients);

