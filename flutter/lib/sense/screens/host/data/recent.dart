// Sense Remote: last incoming connections (YH H2 "Son bağlantılar": kişi · tarih
// · süre · ekran sayısı). There is no bridge for the Host's incoming history yet.
import 'dart:convert';

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

// TODO(bridge): plan §2.6 has no function for the Host's incoming history
// (asked in the B2 report); empty until then.
Future<String> senseRecentRaw() async => '[]';
