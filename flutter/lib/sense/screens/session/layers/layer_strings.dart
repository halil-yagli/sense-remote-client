// Sense Remote: text of the connection layers (YH O13, O14, O15). Turkish only (T2).

abstract final class SenseLayerStrings {
  // O13 — connection problem.
  static const String weakTitle = 'Bağlantı zayıf';
  static const String weakBody = 'Bağlantı bir süredir zayıf; tepkiler gecikiyor.';
  static const String lostTitle = 'Bağlantı kesildi';
  static String lostBody(int seconds) =>
      'Son görüntü $seconds sn önce geldi. Uzak bilgisayar çalışıyor olabilir.';
  static const String latency = 'gecikme';

  /// Loss is estimated, not measured (TK7, #69).
  static const String lossEstimated = 'tahmini kayıp';
  static const String frames = 'görüntü';
  static const String noValue = '—';
  static String ms(int v) => '$v ms';
  static String percent(double v) => '%${v.toStringAsFixed(1)}';
  static String fps(int v) => '$v fps';
  static const String betterPath = 'Daha iyi yol aranıyor (doğrudan / aktarma)…';
  static String reconnecting(int attempt, int closeIn) =>
      'Yeniden bağlanılıyor · $attempt. deneme · $closeIn sn sonra oturum kapanır';
  static String recovering(int seconds) => 'Bağlantı toparlandı · $seconds sn iyi kalırsa kapanır';
  static const String recovered = 'Bağlantı düzeldi';
  static const String endConnection = 'Bağlantıyı bitir';
  static const String endQuestion = 'Bağlantı bitirilsin mi?';
  static const String endConfirm = 'Bitir';

  /// Small word in the top bar while values shake but the layer is not up.
  static const String wavy = 'Dalgalı';

  // O14 — connection ended.
  static const String endedTitle = 'Bağlantı sona erdi';
  static const String reasonHost = 'Sahadaki kişi bağlantıyı bitirdi';
  static String reasonIdle(int minutes) => '$minutes dk hareketsiz kaldığı için kapandı';
  static const String reasonGone = 'Uzak bilgisayar kapandı ya da ağdan çıktı';
  static const String duration = 'süre';
  static String durationValue(Duration d) {
    final m = d.inMinutes;
    if (m >= 60) {
      final h = m ~/ 60;
      final r = m % 60;
      return r == 0 ? '$h sa' : '$h sa $r dk';
    }
    if (m >= 1) return '$m dk';
    return '${d.inSeconds} sn';
  }

  static String chatSummary(int messages, int files) => '$messages mesaj · $files dosya';
  static const String chatDeleted = 'sohbet silindi';
  static String backHome(int seconds) => '$seconds sn sonra ana ekrana dönülüyor';
  static const String close = 'Kapat';
  static const String reconnect = 'Yeniden bağlan';
  static const String reconnecting2 = 'Bağlanıyor…';
  static const String busy = 'Meşgul';

  // O15 — idle warning.
  static const String idlePrefix = 'Bağlantı hareketsiz · ';
  static String idleCount(int seconds) => '$seconds';
  static const String idleSuffix = ' sn içinde kesilecek';
  static const String keepGoing = 'Devam et';
}
