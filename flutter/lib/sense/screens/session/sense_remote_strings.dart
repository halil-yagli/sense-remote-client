// Sense Remote: interface text and formatting of the connection window
// (display map, display info, status box, chat, ghost mode). Prototype:
// Calisma/prototip/uygulama.html, screen 4. Turkish first; the app UI is
// Turkish for now. Design tokens come from sense_cm_style.dart (one source).
//
// Rule: only values the remote computer reported to the panel are shown. No
// frame rate or latency figure appears here (they are not measured).

import 'package:flutter/painting.dart';

import '../../tokens/sense_tokens.dart';

/// The Sense items replace the stock monitor and chat buttons of the toolbar.
const bool kSenseRemoteWindow = true;

const Map<String, String> kSenseRemoteText = {
  'all': 'Tümü',
  'all_displays': 'Tüm ekranlar',
  'display': 'Ekran',
  'primary': 'ana',
  'map_tooltip': 'Ekranlar — tıkla',
  'info': 'Ekran bilgisi',
  'status': 'Bilgisayar durumu',
  'chat': 'Sohbet',
  'ghost': 'Hayalet mod',
  'ghost_on_tooltip': 'Hayalet modu kapat',
  'ghost_bar':
      'Hayalet mod açık — sahadaki ekranlarda bakım perdesi var, siz gerçek görüntüyü görüyorsunuz',
  'ghost_unavailable': 'Hayalet mod bu bağlantıda kullanılamıyor',
  'not_reported': 'Bildirilmedi',
  'no_panel_info': 'Panel bilgisi yok',
  'panel_failed': 'Panel bilgisine ulaşılamadı',
  'retry': 'Yeniden dene',
  'loading': 'Panelden okunuyor…',
  'online': 'çevrimiçi',
  'offline': 'çevrimdışı',
  'last_seen': 'son yoklama',
  'cpu': 'İşlemci',
  'gpu': 'Ekran kartı',
  'memory': 'Bellek',
  'disk': 'Disk',
  'uptime': 'Açık kalma',
  'displays': 'Ekranlar',
  'network': 'Ağ',
  'version': 'Sürüm',
  'health': 'Sağlık',
  'ethernet': 'Ethernet',
  'wifi': 'Wi-Fi',
  'other_net': 'Diğer',
  'not_connected': 'bağlı değil',
  'f_connection': 'Bağlantı',
  'f_resolution': 'Çözünürlük',
  'f_native': 'Yerel',
  'f_refresh': 'Yenileme',
  'f_color': 'Renk',
  'f_hdr': 'HDR',
  'f_scale': 'Ölçek',
  'f_position': 'Konum',
  'hdr_on': 'HDR açık',
  'hdr_off': 'SDR',
  'warn_ycbcr':
      'ince metin ve renk kenarları yumuşayabilir; RGB 4:4:4 önerilir',
  'chat_title_suffix': 'sahadaki kişi',
  'chat_sub': 'Sahadaki kişiyle yazışma',
  'chat_empty': 'Sahadaki kişiye buradan yazabilirsiniz.',
  'chat_hint': 'Karşı tarafa yaz…',
  'send': 'Gönder',
  'voice': 'Sesli görüşme iste',
  'close': 'Kapat',
};

String senseRemoteText(String key) => kSenseRemoteText[key] ?? key;

/// "59,94 Hz", "60 Hz" (Turkish decimal comma, at most two decimals).
String senseFormatHz(double hz) => '${senseFormatNumber(hz, 2)} Hz';

/// Turkish number: decimal comma, trailing zeros dropped.
String senseFormatNumber(double v, int decimals) {
  var s = v.toStringAsFixed(decimals);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s.replaceAll('.', ',');
}

/// "%34"
String senseFormatPct(double v) => '%${v.round()}';

/// "18,4/32 GB" — from megabytes.
String senseFormatMemory(int usedMb, int? totalMb) {
  String gb(int mb) => senseFormatNumber(mb / 1024, 1);
  return totalMb == null ? '${gb(usedMb)} GB' : '${gb(usedMb)}/${gb(totalMb)} GB';
}

/// "6 gün 4 sa", "3 sa 12 dk", "12 dk", "1 dk'dan az".
String senseFormatUptime(int seconds) {
  final d = seconds ~/ 86400;
  final h = (seconds % 86400) ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (d > 0) return h > 0 ? '$d gün $h sa' : '$d gün';
  if (h > 0) return m > 0 ? '$h sa $m dk' : '$h sa';
  if (m > 0) return '$m dk';
  return "1 dk'dan az";
}

/// "12 sn önce", "4 dk önce", "2 sa önce", "3 gün önce".
String senseFormatAgo(int seconds) {
  if (seconds < 0) seconds = 0;
  if (seconds < 60) return '$seconds sn önce';
  if (seconds < 3600) return '${seconds ~/ 60} dk önce';
  if (seconds < 86400) return '${seconds ~/ 3600} sa önce';
  return '${seconds ~/ 86400} gün önce';
}

/// Long name of a display connection; null when unknown (then it is hidden).
String? senseConnectionLabel(String? c) {
  switch (c) {
    case 'hdmi':
      return 'HDMI';
    case 'displayport':
      return 'DisplayPort';
    case 'dvi':
      return 'DVI';
    case 'vga':
      return 'VGA';
    case 'usb_c':
      return 'USB-C';
    case 'internal':
      return 'Dahili';
    case 'other':
      return 'Diğer';
    default:
      return null;
  }
}

/// Short name for a one-line list ("DP, HDMI").
String? senseConnectionShort(String? c) =>
    c == 'displayport' ? 'DP' : senseConnectionLabel(c);

/// "RGB 4:4:4", "YCbCr 4:2:2"; null when unknown.
String? senseColorFormatLabel(String? f) {
  switch (f) {
    case 'rgb':
      return 'RGB 4:4:4';
    case 'ycbcr444':
      return 'YCbCr 4:4:4';
    case 'ycbcr422':
      return 'YCbCr 4:2:2';
    case 'ycbcr420':
      return 'YCbCr 4:2:0';
    default:
      return null;
  }
}

String senseNetworkKindLabel(String kind) {
  switch (kind) {
    case 'ethernet':
      return senseRemoteText('ethernet');
    case 'wifi':
      return senseRemoteText('wifi');
    default:
      return senseRemoteText('other_net');
  }
}

/// Extra tokens of the connection window (prototype uygulama.html: warm bar,
/// amber note). Black/white and the navy→purple accent come from SenseCmTokens.
// Sense Remote (A1b, YH T1): bridge only, aliases of the one token set.
class SenseRemoteTokens {
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const warn = SenseColors.warn;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static final warnBorder = SenseColors.warn.withAlpha(0x80);
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static final warnFill = SenseColors.warn.withAlpha(0x14);
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const barTrack = SenseColors.raised;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const mapCell = SenseColors.line;
  @Deprecated('Sense Remote A1b: use SenseColors / tokens/sense_tokens.dart')
  static const mapText = SenseColors.textSecondary;
  @Deprecated('Sense Remote A1b: use SenseGradients / tokens/sense_tokens.dart')
  static const hot =
      LinearGradient(colors: [SenseColors.warn, SenseColors.hot]);
  @Deprecated('Sense Remote A1b: use SenseGradients / tokens/sense_tokens.dart')
  static const bar = SenseGradients.glow;
}
