// Sense Remote: text of the connection layers (YH O13, O14, O15). Turkish only (T2).

import '../popups/status/status_format.dart' show sensePctDecimal;

abstract final class SenseLayerStrings {
  // O13 — connection problem.
  static const String weakTitle = 'Bağlantı zayıf';
  static const String weakBody = 'Bağlantı bir süredir zayıf; tepkiler gecikiyor.';
  static const String lostTitle = 'Bağlantı kesildi';
  static String lostBody(int seconds) =>
      'Son görüntü $seconds sn önce geldi. Uzak bilgisayar çalışıyor olabilir.';
  static const String latency = 'gecikme';

  /// "x" on the weak card; the card shrinks into the logo area (karar #94).
  static const String minimize = 'Kapat (durum alanına küçülür)';

  /// Loss is estimated, not measured (TK7, #69).
  static const String lossEstimated = 'tahmini kayıp';
  static const String frames = 'görüntü';
  static const String noValue = '—';
  static String ms(int v) => '$v ms';
  /// Turkish: percent sign first, decimal comma, "%100" / "%5,1".
  static String percent(double v) => sensePctDecimal(v);
  static String fps(int v) => '$v fps';
  static const String betterPath = 'Daha iyi yol aranıyor (doğrudan / aktarma)…';
  /// Sürüm 11 (O1): [attempt] is a real reconnect attempt (0 = the first one is on its way).
  static String reconnecting(int attempt, int closeIn) => attempt < 1
      ? 'Yeniden bağlanılıyor · $closeIn sn sonra oturum kapanır'
      : 'Yeniden bağlanılıyor · $attempt. deneme · $closeIn sn sonra oturum kapanır';
  static String recovering(int seconds) => 'Bağlantı toparlandı · $seconds sn iyi kalırsa kapanır';
  static const String recovered = 'Bağlantı düzeldi';
  static const String endConnection = 'Bağlantıyı bitir';
  static const String endQuestion = 'Bağlantı bitirilsin mi?';
  static const String endConfirm = 'Bitir';

  // Sürüm 10 (#110): the same card opened from the logo area while the link is good.
  static const String goodTitle = 'Bağlantı iyi';
  static const String wavyTitle = 'Bağlantı dalgalı';
  static const String pathDirect = 'Doğrudan bağlantı (aktarma yok)';
  static const String pathRelay = 'Aktarma sunucusu üzerinden';
  static const String pathUnknown = 'Bağlantı türü ölçülüyor';
  static const String closeCard = 'Kapat';

  /// Sürüm 12 (FO-A12): the line under the computer name while the transport is lost
  /// (prototype `netRender`: at least "1. deneme").
  static String barReconnecting(int attempt) =>
      'Kesildi · Yeniden bağlanılıyor (${attempt < 1 ? 1 : attempt}. deneme)';

  /// Small word in the top bar while values shake but the layer is not up.
  static const String wavy = 'Dalgalı';

  // O14 — connection ended.
  static const String endedTitle = 'Bağlantı sona erdi';
  static const String reasonHost = 'Sahadaki kişi bağlantıyı bitirdi';
  static String reasonIdle(int minutes) => '$minutes dk hareketsiz kaldığı için kapandı';
  static const String reasonGone = 'Uzak bilgisayar kapandı ya da ağdan çıktı';
  /// Sürüm 11 (O7): instead of RustDesk's "Login Error · sense_busy".
  static const String reasonBusy = 'Meşgul — şu an başka biri bağlı';
  /// Sürüm 12 (FO-A11): this side pressed "Bağlantıyı bitir".
  static const String reasonSelf = 'Bağlantıyı sen bitirdin';
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
  /// Sürüm 11 (O7): "Yeniden bağlan" got no answer in time.
  static const String reconnectFailed = 'Bağlanılamadı';

  // Sürüm 11 (#121): logged in, no picture yet (instead of a black screen).
  static const String waitingTitle = 'Görüntü bekleniyor';
  static const String waitingRelay = 'Aktarma sunucusu üzerinden; yavaş olabilir';
  static const String waitingDirect = 'Doğrudan bağlantı';
  static const String waitingUnknown = 'Bağlantı türü ölçülüyor';
  static const String waitingStatus = 'Uzak bilgisayardan ilk görüntü isteniyor…';

  // O15 — idle warning.
  static const String idlePrefix = 'Bağlantı hareketsiz · ';
  static String idleCount(int seconds) => '$seconds';
  static const String idleSuffix = ' sn içinde kesilecek';
  static const String keepGoing = 'Devam et';
}
