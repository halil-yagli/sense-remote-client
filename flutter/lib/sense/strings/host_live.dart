// Sense Remote: words of the Host-side Sense icon and card (YH H3, H4).
// Turkish only (T2, #59). The chat inside the card uses SenseChatStrings and
// SenseChatLabels.host.

abstract final class SenseHostLiveStrings {
  // Card header (H4): "Sense Remote · Sense Department ile · –".
  static const String brand = 'Sense Remote';
  static const String subtitle = 'Sense Department ile';
  static const String minimize = 'Simgeye küçült';

  // Recording strip (S7, #37).
  static String recording(String mmss) => 'Bu bağlantı kaydediliyor · $mmss';

  // Who is connected (H4).
  static const String connected = 'Sense Department bağlı';
  static const String endConnection = 'Bağlantıyı bitir';

  /// "Halil Y. · 14 dk · ekran, fare ve klavye, dosya".
  static String who(String name, String duration, String permissions) =>
      [name, duration, permissions].where((s) => s.isNotEmpty).join(' · ');

  /// Connected time: "1 dk", "14 dk", "1 sa 05 dk".
  static String minutes(Duration d) {
    final total = d.isNegative ? 0 : d.inMinutes;
    if (total < 60) return '${total < 1 ? 1 : total} dk';
    final h = total ~/ 60;
    final m = total % 60;
    return '$h sa ${m.toString().padLeft(2, '0')} dk';
  }

  // Permissions in the who line, in a fixed order (only the ones that are on).
  static const String permScreen = 'ekran';
  static const String permInput = 'fare ve klavye';
  static const String permClipboard = 'pano';
  static const String permAudio = 'ses';
  static const String permFile = 'dosya';
  static const String permRestart = 'yeniden başlatma';
  static const String permRecording = 'kayıt';

  // Access request (approve mode "click"): a peer waits for an answer.
  static String wantsToConnect(String name) => '$name bağlanmak istiyor';
  static const String accept = 'Kabul et';
  static const String reject = 'Reddet';

  // Incoming voice call: SenseChatLabels.host.incomingCall (shared box, #73).

  // Ended connection.
  static const String ended = 'Bağlantı bitti';
  static const String close = 'Kapat';

  // Icon (H3).
  static const String iconLabel = 'Sense Remote · bağlı';
  static const String iconTooltip = 'Sense Remote · basınca açılır, sürükleyerek taşınır';
  static const String edgeTooltip = 'Sense Remote · basınca geri gelir';
}
