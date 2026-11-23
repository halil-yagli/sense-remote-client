// Sense Remote: date and time words of the Host app (YH H2 "ayarlı · 12 Kas 2026",
// "dün · Mevlüt · 14 dk"). Pure, so tests pin them.
import '../../strings/host.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// "12 Kas 2026".
String senseHostDate(DateTime d) => '${d.day} ${SenseHostStrings.months[d.month - 1]} ${d.year}';

/// "bugün" / "dün" / "12 Kas" (this year) / "12 Kas 2025".
String senseHostDay(DateTime d, DateTime now) {
  final day = DateTime(d.year, d.month, d.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return SenseHostStrings.today;
  if (diff == 1) return SenseHostStrings.yesterday;
  final m = SenseHostStrings.months[d.month - 1];
  return d.year == now.year ? '${d.day} $m' : '${d.day} $m ${d.year}';
}

/// "dün 17:10".
String senseHostDayTime(DateTime d, DateTime now) =>
    '${senseHostDay(d, now)} ${_two(d.hour)}:${_two(d.minute)}';

/// 6-digit pairing code as "482 · 913"; other codes as they are.
String senseHostPairingCode(String code) =>
    code.length == 6 ? '${code.substring(0, 3)} · ${code.substring(3)}' : code;

/// "2:54"; never below zero.
String senseHostCountdown(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  return '${s ~/ 60}:${_two(s % 60)}';
}
