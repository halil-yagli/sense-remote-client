// Sense Remote: last incoming connections (YH H2 "Son bağlantılar": kişi · tarih
// · süre · ekran sayısı). Bridge `main_sense_host_recent_conns` (D3c).
import 'dart:convert';

import '../../../../models/platform_model.dart';

class SenseRecentConnection {
  const SenseRecentConnection({required this.who, required this.at, this.seconds, this.screens});
  final String who;
  final DateTime at;
  final int? seconds;
  final int? screens;
}

/// `[{name, at, seconds, screens}]` (unix seconds), newest first; bad rows skipped.
List<SenseRecentConnection> senseRecentParse(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is! List) return const [];
    final out = <SenseRecentConnection>[];
    for (final r in v) {
      if (r is! Map || r['name'] is! String || r['at'] is! int) continue;
      out.add(SenseRecentConnection(
        who: r['name'] as String,
        at: DateTime.fromMillisecondsSinceEpoch((r['at'] as int) * 1000),
        seconds: r['seconds'] is int ? r['seconds'] as int : null,
        screens: r['screens'] is int ? r['screens'] as int : null,
      ));
    }
    return out;
  } catch (_) {
    return const [];
  }
}

// D3c: the service keeps the Host's last 20 incoming connections (no secrets).
Future<String> senseRecentRaw() => bind.mainSenseHostRecentConns();
