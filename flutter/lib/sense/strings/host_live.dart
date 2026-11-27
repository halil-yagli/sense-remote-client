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

  // O6: the same Controller also opened a terminal, a file transfer or a TCP
  // tunnel. The card says how many connections are open and of which kind;
  // the button ends all of them.
  static const String endAll = 'Tümünü bitir';

  /// "2 bağlantı · ekran, terminal".
  static String connections(int count, List<String> kinds) =>
      '$count bağlantı · ${kinds.join(', ')}';

  // Kinds (the names of the Controller's menu: Dosya aktarımı, Terminal,
  // TCP tüneli), lower case inside the line.
  static const String kindScreen = 'ekran';
  static const String kindCamera = 'kamera';
  static const String kindFile = 'dosya aktarımı';
  static const String kindTerminal = 'terminal';
  static const String kindTunnel = 'TCP tüneli';

  /// "Halil Y. · 14 dk · ekran, fare ve klavye, dosya".
  static String who(String name, String duration, String permissions) =>
      [name, duration, permissions].where((s) => s.isNotEmpty).join(' · ');

  /// Connected time: "1 dk", "14 dk", "1 sa 5 dk", "2 sa" (TS-10: the same
  /// form as the Host home screen, SenseHostStrings.duration).
  static String minutes(Duration d) {
    final total = d.isNegative ? 0 : d.inMinutes;
    if (total < 60) return '${total < 1 ? 1 : total} dk';
    final h = total ~/ 60;
    final m = total % 60;
    return m == 0 ? '$h sa' : '$h sa $m dk';
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

  // Ended connection (#101; O14 wording): the card closes by itself.
  static const String ended = 'Bağlantı sona erdi';
  static String endedClosing(int seconds) => '$seconds sn sonra kapanıyor';
  static const String close = 'Kapat';

  // Icon (H3).
  static const String iconLabel = 'Sense Remote · bağlı';
  static const String iconTooltip = 'Sense Remote · basınca açılır, sürükleyerek taşınır';
  static const String edgeTooltip = 'Sense Remote · basınca geri gelir';
}
