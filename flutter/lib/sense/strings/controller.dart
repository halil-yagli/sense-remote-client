// Sense Remote: texts of the Controller app (YH C1 sign-in and account, C2
// Bilgisayarlar; prototype `loginRender`, `pcsView`, `pcRow`, `ledTip`).
// Turkish only (YH T2, #59).

abstract final class SenseControllerStrings {
  // Shell: left menu.
  static const String thisComputer = 'Bu bilgisayar';
  static const String computers = 'Bilgisayarlar';
  static const String settings = 'Ayarlar';
  static const String about = 'Hakkında';
  static String version(int n) => 'Sürüm $n';

  // Account box (C1).
  static const String signOut = 'Çıkış yap';
  static const String signOutQuestionIdle = 'Çıkış yapılsın mı? Açık bağlantı yok.';
  static const String signOutQuestionBusy = 'Çıkış yapılsın mı? Açık bağlantı var.';

  // Sign-in (C1).
  static const String loginTitleBold = 'Sense';
  static const String loginTitleThin = ' hesabınla gir';
  static const String loginLead =
      'Bu bilgisayarı kim kullanıyorsa kendi Sense hesabıyla girer. Listede yalnız o kişinin panelde üyesi olduğu projeler görünür.';
  static const String loginGoogle = 'Google ile giriş yap';
  static const String loginSteps = 'Tarayıcıda açılır · eşleştirme kodu karşılaştırılır · iki adımlı doğrulama';
  static const String loginWithoutAccount = 'Giriş yapmadan da kimlikle bağlanabilirsin.';
  static const String loginPairingLabel = 'Eşleştirme kodu';
  static const String loginPairingHint = 'Tarayıcıda Sense Google hesabınla gir, kodu karşılaştır, onayla.';
  static const String loginWaiting = 'Onay bekleniyor';
  static const String loginOpening = 'Tarayıcı açılıyor…';
  static const String loginCopyLink = 'Bağlantıyı kopyala';
  static const String loginLinkCopied = 'Giriş bağlantısı kopyalandı';
  static const String loginNoProvider = 'Sense paneline ulaşılamadı. İnternet bağlantısını denetle.';
  static const String loginFailed = 'Giriş tamamlanamadı. Yeniden dene.';
  static const String loginDone = 'Giriş yapıldı';
  static String pairingCode(String code) {
    final digits = code.replaceAll(RegExp(r'\D'), '');
    return digits.length == 6 ? '${digits.substring(0, 3)} · ${digits.substring(3)}' : code;
  }

  // Bilgisayarlar header (C2).
  static String panelOnline(int online, int total) => 'Panel bağlı · $online/$total çevrimiçi';
  static const String searchHint = 'Bilgisayar, proje, konum ya da kimlik';
  static const String connectById = 'Kimlikle bağlan';
  static const String idHint = 'Kimlik, örn. 482 913 207';
  static const String idHelp =
      'Sense kurulu olmayan ya da listende bulunmayan bir bilgisayar için. Şifre ekibin şifre yöneticisinden girilir.';
  static const String idInvalid = 'Kimlik 6–12 rakam olmalı.';

  // Number tiles (#26: no title, no computer names).
  static const String online = 'Çevrimiçi';
  static const String offline = 'Kapalı';
  static const String attention = 'Dikkat isteyen';
  static const String projects = 'Proje';

  // Location filter.
  static const String location = 'Yer';
  static const String all = 'Tümü';

  // Project group.
  static String groupSummary(int online, int offline) => '$online çevrimiçi · $offline kapalı';
  static const String noProject = 'Projesiz';
  static const String dragToSort = 'Sürükleyerek sırala';
  static const String orderSaved = 'Sıra kaydedildi';
  static const String orderFailed = 'Sıra kaydedilemedi; panele ulaşılamadı.';
  static const String connectFailed = 'Bağlantı penceresi açılamadı; yeniden dene.';

  /// B16: a click that cannot connect says why.
  static const String busyNow = 'Bilgisayar meşgul; aynı anda tek kişi bağlanır.';
  static const String rightRevoked = 'Bağlanma yetkin kaldırıldı.';
  static const String crossProject = 'Projeler arası taşıma panelde yapılır';

  // Tile.
  static const String offTag = 'kapalı';
  static String screens(int n) => '$n ekran';
  static const String connect = 'Bağlan';
  static const String tryAnyway = 'Yine de dene';
  static const String connecting = 'Bağlanıyor…';
  static const String busy = 'Meşgul';
  static String busyBy(String who) => 'Meşgul · $who bağlı';
  static const String busyTip = 'Bir bilgisayara aynı anda tek kişi bağlanır';
  static String lastSeen(String ago) => 'Son görülme $ago';
  static const String noRight = 'Yetkin yok';
  static const String noRightTip = 'Bağlanma yetkin panelde kapalı';

  // "⋯" menu of a tile (R6).
  static const String moreConnect = 'Ekranı açmadan bağlan';
  static const String openFileTransfer = 'Dosya aktarımı';
  static const String openTerminal = 'Terminal';
  static const String openTcpTunnel = 'TCP tünel';

  // LED detail (250 px box).
  static const String healthOk = 'Sağlıklı';
  static const String healthWarn = 'Uyarı var';
  static const String healthHot = 'Dikkat gerekiyor';
  static const String healthNone = 'Veri yok';
  static String healthOffline(String? ago) =>
      ago == null ? 'Bilgisayar kapalı.' : 'Bilgisayar kapalı; son veri $ago.';
  static const String healthMissing = 'Bu bilgisayardan henüz sağlık verisi gelmedi.';
  static String healthFooter(String ago) => 'Son veri $ago · panel';
  static const String healthLoading = 'Panelden alınıyor…';

  // States.
  static const String loading = 'Bilgisayarlar panelden alınıyor…';
  static const String errorTitle = 'Liste panelden alınamadı';
  static const String errorText = 'Ağ bağlantısını denetle. Kimliğini biliyorsan yine bağlanabilirsin.';
  static const String retry = 'Yeniden dene';
  static const String emptyTitle = 'Hesabına atanmış bilgisayar yok';
  static const String emptyText =
      'Bilgisayarlar Sense panelinden projelere atanır. Listede olmayan bir bilgisayar için “Kimlikle bağlan”.';
  static String noMatch(String q) => '“$q” için bilgisayar yok';
  static const String clearSearch = 'Aramayı temizle';

  // Grants (S11, plan §2.4).
  static const String grantsMissing = 'Yetkiler panelden alınamadı';
  static const String grantsMissingText =
      'Bağlanma şimdilik kilitli. Ağ bağlantısını denetle; yetkiler birkaç saniye içinde yeniden istenir.';
}
