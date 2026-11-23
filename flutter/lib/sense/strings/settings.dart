// Sense Remote: texts of the Controller settings page (YH C3; prototype
// `setView2`). Turkish only (YH T2, #59). Category order and keys follow the
// TK9 §4 table (lib/sense/data/option_keys.dart).

abstract final class SenseSettingsStrings {
  // Page header.
  static const String title = 'Ayarlar';
  static const String live = 'değişiklik hemen uygulanır';

  /// "Controller · 14 ayar senin, 6 ayar panelden".
  static String overviewTitle(String role, int mine, int locked) =>
      '$role · $mine ayar senin, $locked ayar panelden';
  static const String overviewBody =
      'Kilitli ayarlar Sense panelinden imzalı gelir; burada görünür ama değişmez. '
      'Oturum içindeki seçimler (kalite, imleç, klavye) uzak oturumun üst çubuğunda; '
      'burada yalnız yeni bağlantıların başlangıcı.';

  // Categories.
  static const String catRole = 'Bu bilgisayarın rolü';
  static const String catConnections = 'Bağlantılar';
  static const String catNew = 'Yeni bağlantılar nasıl başlasın';
  static const String catIncoming = 'Gelen dosyalar ve kayıt';
  static const String catSecurity = 'Güvenlik';
  static const String catPerformance = 'Performans';
  static const String catNetwork = 'Ağ ve sunucu';
  static const String catUpdate = 'Güncelleme';

  // Bağlantılar.
  static const String openInTabs = 'Bağlantıları sekmede aç';
  static const String openInTabsHint = 'Kapalıysa her bilgisayar ayrı pencerede.';
  static const String confirmClosingTabs = 'Birden çok sekmeyi kapatmadan önce sor';
  static const String keepAwake = 'Bağlantı sürerken bu bilgisayarı uyanık tut';
  static const String syncClipboard = 'Sekmeler arasında panoyu eşitle';
  static const String shortcuts = 'Uzak oturumda klavye kısayolları';
  static const String shortcutsHint = 'Ctrl+Alt+Shift+B çubuğu gizler / gösterir, Ctrl+Alt+Shift+Q bağlantıyı bitirir (Mac: Cmd+Option+Shift). Tüm liste oturumda Klavye › Kısayollar.';
  static const String passThrough = 'Kısayolları karşı tarafa ilet';
  static const String sumTabs = 'sekmede aç';
  static const String sumWindows = 'ayrı pencere';
  static const String sumAwake = 'uyanık tut';

  // Yeni bağlantılar.
  static const String viewStyle = 'Uzak ekranı göster';
  static const String viewFit = 'Sığdır';
  static const String viewOriginal = '1:1';
  static const String quality = 'Görüntü kalitesi';
  static const String qualityBest = 'İyi';
  static const String qualityBalanced = 'Dengeli';
  static const String qualityFast = 'Hızlı';
  static const String viewOnly = 'Yalnız izleyerek başla';
  static const String privacy = 'Hayalet modla başla';
  static const String privacyHint = 'Ziyaretçi saatinde bağlanırken.';
  static const String sumViewOnly = 'yalnız izleme';
  static const String sumPrivacy = 'Hayalet mod';

  // Gelen dosyalar ve kayıt.
  static const String incomingDir = 'Sohbetten gelen dosyalar';
  static const String incomingDirHint = 'Seçilen klasöre ulaşılamazsa İndirilenler’e kaydedilir.';
  static const String downloads = 'İndirilenler';
  static const String change = 'Değiştir';
  static const String autoRecord = 'Bağlantıları otomatik kaydet';
  static const String recordDir = 'Kayıt klasörü';

  /// #57: recordings never leave this computer.
  static const String recordDirHint = 'Kayıtlar yalnız bu bilgisayarda kalır; panele yüklenmez';
  static const String sumRecordOn = 'kayıt açık';
  static const String sumRecordOff = 'kayıt kapalı';

  // Güvenlik.
  static const String password = 'Kalıcı şifre';
  static const String passwordController = 'Bu bilgisayar yalnız bağlanır; kalıcı şifre gerekmez.';
  static const String acceptConn = 'Bağlantıyı kabul etme';
  static const String acceptConnHost = 'Şifreyle ya da sahadaki kişinin onayıyla';
  static const String acceptConnNone = 'Kabul etmez · yalnız bağlanır';
  static const String idleDisconnect = 'Hareketsiz bağlantıyı kes';
  static String idleMinutes(int m) => '$m dk sonra';
  static const String lanDiscovery = 'Yerel ağda keşfedilme';
  // Two different settings: this one accepts connections made to the computer's IP + port
  // (`direct-server`); "Ağ ve sunucu › Doğrudan bağlantı" is the relay-less path
  // (`force-always-relay`). The names and the hint keep them apart (golden review, C3).
  static const String directIp = 'IP adresiyle erişim';
  static const String directIpHint =
      'Bu bilgisayara IP ve portla gelen bağlantılar. Ağ ve sunucu’daki doğrudan bağlantıdan ayrıdır.';
  static String directIpPort(String port) => 'Açık · port $port';
  static const String login = 'Giriş';
  static const String loginValue = 'Sense Google hesabı + iki adımlı doğrulama';
  static const String sumSecurity = 'iki adımlı giriş · Sense hesabı';

  // Performans.
  static const String hwcodec = 'Donanım kod çözücüyü kullan';
  static const String hwcodecHint = 'Görüntüyü ekran kartıyla çözer; işlemci rahatlar.';
  static const String hostEncoder = 'Kodlayıcı tercihi';
  static const String directx = 'Ekranı DirectX ile yakala';
  static const String wallpaper = 'Bağlantıda duvar kâğıdını kaldır';
  static const String codecAuto = 'Otomatik';
  static String sumHwcodec(bool on) => 'donanım kod çözücü ${on ? 'açık' : 'kapalı'}';
  static const String sumPanel = 'panelden';

  // Ağ ve sunucu.
  static const String server = 'Bağlantı sunucusu';
  static const String serverSense = 'Sense sunucusu';
  static const String serverPublic = 'Genel sunucu';
  static const String serverHint = 'Genel sunucuya geri düşüş kapalı.';
  static const String panelAddress = 'Panel adresi';
  static const String panelSense = 'Sense paneli';
  static const String panelNone = 'Ayarlı değil';
  static const String proxy = 'Vekil sunucu';
  static const String proxyNone = 'Yok';
  static const String proxySet = 'Ayarlı';
  static const String direct = 'Doğrudan bağlantı (TCP · UDP · IPv6)';
  static const String directRelay = 'Kapalı · hep aktarmalı';
  static String sumNetwork(bool direct) =>
      'Sense sunucusu · doğrudan bağlantı ${direct ? 'açık' : 'kapalı'}';

  // Güncelleme.
  static const String autoUpdate = 'Otomatik güncelleme';
  static const String autoUpdateController = 'Açık · onayla kurulur';
  static const String autoUpdateHost = 'Açık · bağlantı yokken kurulur';
  static const String autoUpdateHint = 'Sürümler panelden, imza ve SHA-256 doğrulamasıyla gelir.';
  static const String sumUpdate = 'panelden · otomatik';

  // Shared values.
  static const String on = 'Açık';
  static const String off = 'Kapalı';
}
