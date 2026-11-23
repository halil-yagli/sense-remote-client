// Sense Remote: data of the tray menu (YH C5, H6; #69: drawn by the operating
// system's own menu, D3e `src/tray.rs`). Flutter keeps the parts that are easy
// to test: the last 3 connections (`main_sense_tray_recent`, plan §2.6), their
// "2 sa önce / dün / 3 gün" labels and the menu items in order. The native menu
// draws exactly this list; a Host gets only "Sense Remote'u aç".
import 'dart:convert';

import '../../../../models/platform_model.dart';

abstract final class SenseTrayStrings {
  static const String title = 'Sense Remote';
  static const String ready = 'hazır';
  static String connections(int n) => '$n bağlantı';
  static const String open = "Sense Remote'u aç";
  static const String recent = 'SON BAĞLANTILAR';
  static const String logout = 'Çıkış yap';
  static const String now = 'az önce';
  static String minutes(int n) => '$n dk önce';
  static String hours(int n) => '$n sa önce';
  static const String yesterday = 'dün';
  static String days(int n) => '$n gün';

  /// Tooltip of the tray icon (H6).
  static String tooltip(int connections) =>
      connections > 0 ? '$title · ${SenseTrayStrings.connections(connections)}' : '$title · $ready';
}

/// One recent connection.
class SenseTrayRecent {
  const SenseTrayRecent({required this.peerId, required this.name, required this.at});

  final String peerId;
  final String name;

  /// Unix seconds.
  final int at;
}

/// Most items the menu shows (YH C5).
const int kSenseTrayRecentMax = 3;

/// Pure: `[{peer_id, name, at}]` → newest first, at most 3; bad rows are dropped.
List<SenseTrayRecent> senseParseTrayRecent(String raw) {
  try {
    final v = jsonDecode(raw);
    if (v is! List) return const [];
    final out = <SenseTrayRecent>[];
    for (final e in v) {
      if (e is! Map) continue;
      final id = e['peer_id'];
      final at = e['at'];
      if (id is! String || id.trim().isEmpty || at is! int) continue;
      final name = e['name'];
      out.add(SenseTrayRecent(
          peerId: id.trim(), name: name is String && name.trim().isNotEmpty ? name.trim() : id.trim(), at: at));
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out.take(kSenseTrayRecentMax).toList();
  } catch (_) {
    return const [];
  }
}

/// Pure: label next to a recent connection (prototype: "2 sa önce", "dün", "3 gün").
String senseTrayAgo(int at, int nowSeconds) {
  final s = nowSeconds - at;
  if (s < 60) return SenseTrayStrings.now;
  if (s < 3600) return SenseTrayStrings.minutes(s ~/ 60);
  if (s < 86400) return SenseTrayStrings.hours(s ~/ 3600);
  final d = s ~/ 86400;
  return d == 1 ? SenseTrayStrings.yesterday : SenseTrayStrings.days(d);
}

enum SenseTrayItemKind { header, open, group, recent, separator, logout }

class SenseTrayItem {
  const SenseTrayItem(this.kind, this.label, {this.detail, this.peerId});

  final SenseTrayItemKind kind;
  final String label;

  /// Header status ("hazır") or the time of a recent connection.
  final String? detail;
  final String? peerId;
}

/// Pure: the menu in order (YH C5). Host: header + "Sense Remote'u aç" only
/// (no Servisi durdur, H6). Controller: + SON BAĞLANTILAR (3) + red Çıkış yap.
List<SenseTrayItem> senseTrayMenu({
  required bool controller,
  required int connections,
  List<SenseTrayRecent> recent = const [],
  required int nowSeconds,
}) {
  final items = <SenseTrayItem>[
    SenseTrayItem(SenseTrayItemKind.header, SenseTrayStrings.title,
        detail: connections > 0 ? SenseTrayStrings.connections(connections) : SenseTrayStrings.ready),
    const SenseTrayItem(SenseTrayItemKind.open, SenseTrayStrings.open),
  ];
  if (!controller) return items;
  if (recent.isNotEmpty) {
    items.add(const SenseTrayItem(SenseTrayItemKind.group, SenseTrayStrings.recent));
    for (final r in recent.take(kSenseTrayRecentMax)) {
      items.add(SenseTrayItem(SenseTrayItemKind.recent, r.name,
          detail: senseTrayAgo(r.at, nowSeconds), peerId: r.peerId));
    }
  }
  items.add(const SenseTrayItem(SenseTrayItemKind.separator, ''));
  items.add(const SenseTrayItem(SenseTrayItemKind.logout, SenseTrayStrings.logout));
  return items;
}

/// Where the recent list comes from; tests pass a fake.
abstract class SenseTraySource {
  Future<String> recentJson();
}

class SenseTrayBridge implements SenseTraySource {
  const SenseTrayBridge();

  /// `main_sense_tray_recent` (D3e): the same list the native tray menu shows.
  @override
  Future<String> recentJson() => bind.mainSenseTrayRecent();
}

/// Reads the recent connections for the menu.
Future<List<SenseTrayRecent>> senseTrayRecent([SenseTraySource source = const SenseTrayBridge()]) async {
  try {
    return senseParseTrayRecent(await source.recentJson());
  } catch (_) {
    return const [];
  }
}
