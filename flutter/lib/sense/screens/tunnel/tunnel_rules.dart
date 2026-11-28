// Sense Remote (Sürüm 12, ST 7): the TCP tunnel rules — read from the computer's saved
// options (RustDesk `port_forwards: [[local, host, port], …]`), checked before adding, and
// the listen error RustDesk reports ("Failed to listen on N: …") turned into Turkish.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../strings/tunnel.dart';

@immutable
class SenseTunnelRule {
  const SenseTunnelRule({required this.localPort, required this.host, required this.remotePort});

  final int localPort;
  final String host;
  final int remotePort;

  /// "localhost:80".
  String get remote => '$host:$remotePort';

  @override
  bool operator ==(Object other) =>
      other is SenseTunnelRule && other.localPort == localPort && other.host == host && other.remotePort == remotePort;

  @override
  int get hashCode => Object.hash(localPort, host, remotePort);
}

/// The rules in a peer's saved options JSON (`mainGetPeerSync`). Bad entries are skipped.
List<SenseTunnelRule> senseTunnelRulesFrom(String peerJson) {
  try {
    final decoded = jsonDecode(peerJson);
    final list = decoded is Map ? decoded['port_forwards'] : null;
    if (list is! List) return const [];
    final out = <SenseTunnelRule>[];
    for (final e in list) {
      if (e is! List || e.length < 3) continue;
      final l = e[0], h = e[1], r = e[2];
      if (l is! int || r is! int || h is! String) continue;
      out.add(SenseTunnelRule(localPort: l, host: h.trim().isEmpty ? 'localhost' : h.trim(), remotePort: r));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

int? _port(String s) {
  final t = s.trim();
  if (!RegExp(r'^\d{1,5}$').hasMatch(t)) return null;
  final n = int.parse(t);
  return n >= 1 && n <= 65535 ? n : null;
}

/// Checks the add form (prototype `tunAdd`): a rule, or the Turkish reason.
({SenseTunnelRule? rule, String? error}) senseTunnelValidate(
    String localText, String remoteText, List<SenseTunnelRule> existing) {
  final local = _port(localText);
  if (local == null) return (rule: null, error: SenseTunnelStrings.errPort);
  final m = RegExp(r'^([^\s:]+):(\d{1,5})$').firstMatch(remoteText.trim());
  final remotePort = m == null ? null : _port(m.group(2)!);
  if (m == null || remotePort == null) return (rule: null, error: SenseTunnelStrings.errRemote);
  if (existing.any((r) => r.localPort == local)) {
    return (rule: null, error: SenseTunnelStrings.errDuplicate(local));
  }
  return (rule: SenseTunnelRule(localPort: local, host: m.group(1)!, remotePort: remotePort), error: null);
}

/// RustDesk's `on_error("Failed to listen on N: <os error>")` → (port, Turkish reason);
/// null = not a listen error.
({int port, String reason})? senseTunnelListenError(String text) {
  final m = RegExp(r'Failed to listen on (\d+):?\s*(.*)', caseSensitive: false, dotAll: true).firstMatch(text);
  if (m == null) return null;
  final port = int.tryParse(m.group(1)!);
  if (port == null) return null;
  final os = (m.group(2) ?? '').toLowerCase();
  final String reason;
  if (os.contains('in use') ||
      os.contains('10048') ||
      os.contains('only one usage') ||
      os.contains('addrinuse') ||
      os.contains('errno 48') ||
      os.contains('errno 98')) {
    reason = SenseTunnelStrings.inUse(port);
  } else if (os.contains('10013') || os.contains('permission') || os.contains('access')) {
    reason = SenseTunnelStrings.denied(port);
  } else {
    reason = SenseTunnelStrings.failed(port);
  }
  return (port: port, reason: reason);
}
