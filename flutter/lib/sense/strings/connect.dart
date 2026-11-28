// Sense Remote (Sürüm 12, #162, #164, #159): text of the connecting cards, the Sense dialog
// pattern that replaces RustDesk's stock boxes, window titles and the screenshot notice.
// Turkish only (YH T2, #59). Prototype: `cstSim` (#164), `.recnote`, stok kart çizimleri.

abstract final class SenseConnectStrings {
  // ---- #164 connecting cards ----
  static const String connectingTitle = 'Bağlanılıyor';
  static const String stepFind = 'Bilgisayar aranıyor';
  static const String stepLink = 'Bağlantı kuruluyor';
  static const String stepImage = 'Görüntü bekleniyor';

  /// The Host asks the person there to accept (stock `wait-remote-accept-nook`).
  static const String stepAccept = 'Karşı tarafın onayı bekleniyor';
  static const String cancel = 'İptal';

  /// The computer's name is not known yet (never the id, #162-8).
  static const String remoteFallback = 'Uzak bilgisayar';

  static const String busyTitle = 'Meşgul';
  static String busyBody(String name) => '$name şu an başka biri tarafından kullanılıyor.';
  static const String busyHint = 'Bir bilgisayara aynı anda tek kişi bağlanır';
  static const String later = 'Sonra dene';

  static const String offlineTitle = 'Çevrimdışı';
  static const String offlineBody = 'Bilgisayar kapalı ya da internete bağlı değil.';
  static const String notFoundBody = 'Bu kimlikte bir bilgisayar bulunamadı.';

  static const String passwordTitle = 'Parola gerekiyor';
  static String passwordBody(String name) => '$name bağlantı için parola istiyor.';
  static const String passwordWrongTitle = 'Parola yanlış';
  static String passwordWrongBody(String name) => 'Girdiğin parola $name ile eşleşmedi.';
  static const String passwordWrongLine = 'Parola yanlış. Tekrar dene.';
  static const String passwordHint = 'Parola';

  /// K5: the stock "remember password" stays (off by default); the password never goes to the panel.
  static const String rememberPassword = 'Parolayı bu bilgisayarda hatırla';
  static const String connect = 'Bağlan';
  static const String giveUp = 'Vazgeç';

  static const String otpTitle = '2 adımlı kod';
  static const String otpBody = 'Kimlik doğrulama uygulamandaki 6 haneli kodu gir.';
  static const String otpWrongLine = 'Kod yanlış. Tekrar dene.';
  static const String otpHint = '000 000';
  static const String trustDevice = 'Bu bilgisayara güven';
  static const String verify = 'Doğrula';

  static const String deniedTitle = 'İzin reddedildi';
  static const String deniedBody = 'Karşı taraf bağlantıyı reddetti.';
  static const String noPermissionTitle = 'Yetkin yok';
  static const String noPermissionBody = 'Bu bilgisayara bu türde bağlanma yetkin yok. Panelden yetki iste.';
  static const String timeoutTitle = 'Zaman aşımı';
  static String timeoutBody(String name) => '$name zamanında yanıt vermedi.';
  static const String networkTitle = 'Ağ hatası';
  static const String networkBody = 'Bağlantı sunucusuna ulaşılamadı. İnternet bağlantını kontrol et.';
  static const String failedTitle = 'Bağlanılamadı';
  static const String failedBody = 'Bağlantı kurulurken yarıda kesildi.';

  /// RustDesk retries some errors by itself; the card says when.
  static String retryIn(int seconds) => '$seconds sn sonra yeniden denenecek';
  static const String retry = 'Yeniden dene';
  static const String close = 'Kapat';

  /// What the window connects for (only the connecting card says it).
  static const String kindFile = 'Uzak dosyalar';
  static const String kindTerminal = 'Terminal';
  static const String kindTunnel = 'TCP tünel';
  static const String kindCamera = 'Kamera';

  // ---- Window titles (ST 16): Turkish, without the computer's id ----
  static const String windowRemote = 'Uzak masaüstü';
  static const String windowFiles = 'Uzak dosyalar';
  static const String windowCamera = 'Kamera';
  static const String windowTunnel = 'TCP tünel';
  static const String windowTerminal = 'Terminal';
  static String windowTitle(String what, String app) => '$what · $app';

  // ---- Stock boxes in the Sense dialog pattern (ST 6, 14, 17, 18) ----
  static const String ok = 'Tamam';
  static const String wait = 'Bekle';
  static const String uacTitle = 'Yönetici onayı bekleniyor';
  static const String uacBody =
      'Uzak bilgisayarda yönetici onayı (UAC) penceresi açık. Sahadaki kişi onaylayana kadar fare ve klavye çalışmayabilir.';
  static const String waitUacTitle = 'Onay bekleniyor';
  static const String waitUacBody = 'Uzak bilgisayarda yönetici onayı isteniyor. Sahadaki kişinin onaylaması bekleniyor.';
  static const String elevatedTitle = 'Yönetici penceresi önde';
  static const String elevatedBody =
      'Uzak bilgisayarda yönetici yetkisiyle çalışan bir pencere önde. Fare ve klavye o pencereye ulaşmayabilir.';
  static const String elevationTip = 'Yetki yükseltirsen bu pencerelere de erişebilirsin.';
  static const String requestElevation = 'Yetki yükselt';
  static const String elevationErrorTitle = 'Yetki yükseltilemedi';
  static const String elevationNoPermission = 'Bu bilgisayarda yetki yükseltme iznin yok.';
  static const String waitAcceptTitle = 'Onay bekleniyor';
  static const String waitAcceptBody = 'Karşı tarafın bağlantıyı kabul etmesi bekleniyor…';

  static const String closeTabsTitle = 'Bütün bağlantılar kapatılsın mı?';
  static String closeTabsBody(int n) => 'Bu pencerede $n bağlantı açık; hepsi kapanır.';
  static const String closeTabsAskAgain = 'Birden çok sekme kapanırken yine sor';
  static const String closeAll = 'Hepsini kapat';

  static const String relayTitle = 'Bağlantı koptu';
  static const String relayBody = 'Doğrudan bağlantı kurulamadı. Aktarma sunucusu üzerinden bağlanmayı deneyebilirsin.';
  static const String viaRelay = 'Aktarmayla bağlan';

  static const String privacyTitle = 'Hayalet mod açılamadı';
  static const String privacyMore = 'Ayrıntı';

  static const String sessionsTitle = 'Hangi Windows oturumuna bağlanılsın?';
  static const String sessionsBody = 'Uzak bilgisayarda birden çok Windows oturumu açık.';

  static const String printerTitle = 'Uzaktan yazdırma isteği';
  static const String printerBody = 'Uzak bilgisayar bu bilgisayarın yazıcısına bir belge göndermek istiyor.';
  static const String printerDefault = 'Varsayılan yazıcı';
  static const String printerSave = 'Seçimimi kaydet';
  static const String printerDontAsk = 'Bir daha sorma, gelen işi doğrudan yazdır';
  static const String print = 'Yazdır';

  // ---- #159 screenshot ----
  static const String screenshotSaved = 'Bu bilgisayara kaydedildi';
  static const String openFolder = 'Klasörü aç';
  static String screenshotFailed(String why) => 'Ekran görüntüsü kaydedilemedi · $why';
  static const String screenshotNoFolder = 'İndirilenler klasörü bulunamadı';
  static const String screenshotNoImage = 'görüntü alınamadı';
  static const String screenshotWriteFailed = 'dosya yazılamadı';
  static const String screenshotFallbackName = 'bilgisayar';
}
