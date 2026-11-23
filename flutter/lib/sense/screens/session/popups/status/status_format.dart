// Sense Remote: Turkish number and size formats of the session popups (YH O8,
// O9; T2). "14,1 / 32 GB", "%62", "2,10 GHz", "1.840", "05.12.2025".
// Pure functions, covered by tests.

/// Decimal with a comma; [digits] decimals, trailing ",0" dropped when [trim].
String senseNum(double v, {int digits = 1, bool trim = true}) {
  var s = v.toStringAsFixed(digits);
  if (trim && digits > 0) {
    s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  }
  final neg = s.startsWith('-');
  if (neg) s = s.substring(1);
  final parts = s.split('.');
  final grouped = _group(parts[0]);
  final out = parts.length > 1 ? '$grouped,${parts[1]}' : grouped;
  return neg ? '-$out' : out;
}

/// Thousands with a dot: 1840 → "1.840".
String _group(String digits) {
  if (digits.length <= 3) return digits;
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write('.');
    b.write(digits[i]);
  }
  return b.toString();
}

/// "%23" (whole), "%0,2" under 1.
String sensePct(double v) => v > 0 && v < 1 ? '%${senseNum(v, digits: 1)}' : '%${v.round()}';

/// "58 °C".
String senseTemp(double c) => '${c.round()} °C';

/// MB → "14,1 GB" style number (no unit) in GB.
double senseGb(num mb) => mb / 1024;

/// "14,1 / 32 GB": one unit for both, chosen by the total.
String senseUsedOfTotalMb(num usedMb, num totalMb) {
  final total = senseGb(totalMb);
  final used = senseGb(usedMb);
  return '${senseNum(used)} / ${senseNum(total)} GB';
}

/// "17,9 GB" / "512 MB".
String senseSizeMb(num mb) => mb >= 1024 ? '${senseNum(senseGb(mb))} GB' : '${mb.round()} MB';

/// Disk sizes from GB: "577 / 931 GB", "1,75 / 1,82 TB".
String senseUsedOfTotalGb(double usedGb, double totalGb) {
  if (totalGb >= 1000) {
    return '${senseNum(usedGb / 1000, digits: 2)} / ${senseNum(totalGb / 1000, digits: 2)} TB';
  }
  return '${usedGb.round()} / ${totalGb.round()} GB';
}

/// "1 TB", "512 GB".
String senseDiskSize(double gb) => gb >= 1000 ? '${senseNum(gb / 1000)} TB' : '${gb.round()} GB';

/// MHz → "2,10" (GHz, two decimals).
String senseGhz(int mhz) => senseNum(mhz / 1000, digits: 2, trim: false);

/// Bytes per second → megabit per second (contract §3: rx_bps * 8 / 1e6).
double senseMbit(int bps) => bps * 8 / 1e6;

/// Bytes per second → "24" MB/s (decimal megabytes, whole).
String senseMBps(int bps) => '${(bps / 1e6).round()}';

/// Link speed: "1 Gbit/s", "866 Mbit/s".
String senseLinkSpeed(int mbps) =>
    mbps >= 1000 ? '${senseNum(mbps / 1000)} Gbit/s' : '$mbps Mbit/s';

/// "↓ 12 · ↑ 3 Mbit/s".
String senseTraffic(double rxMbit, double txMbit) =>
    '↓ ${_mbit(rxMbit)} · ↑ ${_mbit(txMbit)} Mbit/s';

String _mbit(double v) => v >= 10 || v == 0 ? '${v.round()}' : senseNum(v);

/// "05.12.2025".
String senseDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

/// "3 gün 4 sa", "5 sa 12 dk", "14 dk".
String senseUptime(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return h > 0 ? '$d gün $h sa' : '$d gün';
  if (h > 0) return m > 0 ? '$h sa $m dk' : '$h sa';
  return '$m dk';
}

/// "8 sn önce", "3 dk önce", "2 sa önce", "4 gün önce".
String senseAgo(Duration age) {
  final s = age.inSeconds < 0 ? 0 : age.inSeconds;
  if (s < 60) return '$s sn önce';
  if (s < 3600) return '${s ~/ 60} dk önce';
  if (s < 86400) return '${s ~/ 3600} sa önce';
  return '${s ~/ 86400} gün önce';
}

/// "3840×2160" (summary) or "3840 × 2160" (row).
String senseRes(int w, int h, {bool spaced = false}) => spaced ? '$w × $h' : '$w×$h';

/// "60 Hz", "59,94 Hz".
String senseHz(double hz) => '${senseNum(hz, digits: 2)} Hz';

/// Short CPU name for the summary: "12th Gen Intel Core i7-12700" → "i7-12700",
/// "AMD Ryzen 7 5800X 8-Core Processor" → "Ryzen 7 5800X", "Apple M2 Pro" → "M2 Pro".
String senseShortCpu(String model) {
  var s = model
      .replaceAll(RegExp(r'\((R|TM|tm|r)\)'), '')
      .replaceAll(RegExp(r'@.*$'), '')
      .replaceAll(RegExp(r'\b\d+(st|nd|rd|th) Gen\b'), '')
      .replaceAll(RegExp(r'\b\d+-Core\b'), '')
      .replaceAll(RegExp(r'\b(Intel|AMD|Apple|CPU|Processor|Core)\b'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? model.trim() : s;
}

/// Short GPU name: "NVIDIA GeForce RTX 4070" → "RTX 4070", "Intel UHD Graphics 770" → "UHD Graphics 770".
String senseShortGpu(String name) {
  final s = name
      .replaceAll(RegExp(r'\((R|TM)\)'), '')
      .replaceAll(RegExp(r'\b(NVIDIA|GeForce|AMD|Radeon\(TM\)|Intel|Apple)\b'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s.isEmpty ? name.trim() : s;
}

/// "3 ekran · 2× 4K + 1× 1080p" body: resolution class counts in first-seen order.
String senseResolutionMix(List<({int w, int h})> sizes) {
  String cls(int w, int h) {
    if (w == 3840 && h == 2160) return '4K';
    if (w == 2560 && h == 1440) return '1440p';
    if (w == 1920 && h == 1080) return '1080p';
    if (w == 1280 && h == 720) return '720p';
    return senseRes(w, h);
  }

  final counts = <String, int>{};
  for (final s in sizes) {
    final c = cls(s.w, s.h);
    counts[c] = (counts[c] ?? 0) + 1;
  }
  return counts.entries.map((e) => '${e.value}× ${e.key}').join(' + ');
}
