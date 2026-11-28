// Sense Remote: texts of the Host app (YH H1, H2; prototype "Bu bilgisayar").
// Turkish only (YH T2, #59). The permanent password texts stay in
// screens/host/sense_password_strings.dart (kept, plan B2).

import 'format.dart';

abstract final class SenseHostStrings {
  // Shell (H1): left menu.
  static const String thisComputer = 'Bu bilgisayar';
  static const String thisComputerBold = 'Bu';
  static const String thisComputerThin = ' bilgisayar';
  static const String about = 'Hakkında';
  static const String roleHost = 'Host';
  static const String managedByPanel = 'Panelden yönetilir';
  static String version(int n) => 'Sürüm $n';

  // Status box (H1, six states).
  static const String ready = 'Hazır';
  static const String connecting = 'Bağlanıyor';
  static const String notReady = 'Hazır değil';
  static const String connected = 'Bağlı';
  static const String readyText = 'Sense ekibi bu bilgisayara bağlanabilir.';
  static const String connectingText = 'Bağlantı sunucusuna bağlanıyor…';
  static const String downText =
      'Bağlantı sunucusuna ulaşılamıyor. İnternet bağlantısını denetle.';
  static const String stoppedText = 'Sense Remote servisi çalışmıyor; ekip bağlanamaz.';
  static String macText(List<String> names) => names.length == 1
      ? '${names.single} izni verilmemiş.'
      : '${names.sublist(0, names.length - 1).join(', ')} ve ${names.last} izinleri verilmemiş.';

  /// "Halil bu bilgisayarda · 14 dk"; without a name "Sense ekibi bu bilgisayarda".
  static String busyText(String? who, String? duration) =>
      '${who ?? 'Sense ekibi'} bu bilgisayarda${duration == null ? '' : ' · $duration'}';
  static const String retry = 'Yeniden dene';
  static const String startService = 'Servisi başlat';
  static const String openPermissions = 'İzinleri aç';
  static String titleWithName(String state, String name) => '$state — $name';

  // Tiles (H1).
  static const String id = 'Kimlik';
  static const String place = 'Yer';
  static const String panel = 'Sense paneli';
  static const String panelOk = 'bağlı';
  static const String panelDown = 'ulaşılamıyor';
  static const String activeConnection = 'Etkin bağlantı';
  static const String none = 'yok';
  static String activeCount(int n, String? who) => who == null ? '$n' : '$n · $who';
  static const String idCopied = 'Kimlik kopyalandı';
  static const String editName = 'Adı değiştir';
  static const String editPlace = 'Yeri değiştir';
  static const String noPlace = 'Yer yok';

  // Name and place (#33).
  static const String identitySaved = "Kaydedildi · panel ve Controller'lar güncellendi";
  static const String errInvalid = 'Ad 1–64 karakter olmalı.';
  static const String errNetwork = 'Panele ulaşılamadı; değişiklik kaydedilmedi. Yeniden dene.';
  static const String errLocation = 'Bu yer bu bilgisayarın projesinde yok.';
  static const String errUnavailable = 'Servis yanıt vermiyor; birazdan yeniden dene.';
  static const String errOther = 'Kaydedilemedi. Yeniden dene.';

  /// Minutes / hours of a connection ("14 dk", "1 sa 5 dk").
  static String duration(int seconds) => senseShortDuration(seconds ~/ 60);

  // Categories (H2).
  static const String permissions = 'Yetkiler';
  static String permissionsSummary(int open) => 'panelden · imzalı · $open açık';
  static const String permissionsHint =
      'Yetkiler yalnız Sense panelinden imzalı gelir ve hemen uygulanır; burada değiştirilemez.';
  static const String permScreen = 'Ekran';
  static const String permInput = 'Fare ve klavye';
  static const String permClipboard = 'Pano';
  static const String permFile = 'Dosya';
  static const String permAudio = 'Ses';
  static const String permRestart = 'Yeniden başlatma';
  static const String permRecord = 'Oturum kaydı';
  static const String permGhost = 'Hayalet mod';
  // #166 (FU-B10): the panel's other five (its order: ... Hayalet mod, Terminal, Tünel, Kamera, ...).
  static const String permBlockInput = 'Yerel girişi engelleme';
  static const String permTerminal = 'Terminal';
  static const String permTunnel = 'Tünel';
  static const String permCamera = 'Kamera';
  static const String permPrinter = 'Uzak yazıcı';
  static const String permWallpaper = 'Duvar kâğıdını kaldırma';

  // Audio and network (FU-A4): locked, the panel's signed Host settings.
  static const String net = 'Ses ve ağ';
  static const String netSummary = 'panelden · kilitli';
  static const String netHint = 'Yalnız Sense panelinden imzalı gelir; burada değiştirilemez.';
  static const String netAudioIn = 'Ses girişi';
  static const String netAudioSystem = 'Sistem sesi';
  static const String netAudioMic = 'Mikrofon';
  static const String netAwake = 'Gelen oturumda uyanık tut';
  static const String netRelay = 'Aktarmaya düşme gecikmesi';
  static const String netRelayDefault = 'Varsayılan';
  static const String netRelayNow = 'Hemen';
  static String netRelaySeconds(int s) => '$s sn';
  static const String netUdp = 'UDP';
  static const String netTcpOnly = 'Yalnız TCP / WebSocket';
  static const String valueOn = 'Açık';
  static const String valueOff = 'Kapalı';

  /// The setting could not be read: no value is made up.
  static const String unreadable = 'okunamadı';

  static const String password = 'Kalıcı şifre';
  static const String passwordNone = 'ayarlı değil';
  static String passwordSet(String? date) => date == null ? 'ayarlı' : 'ayarlı · $date';
  static const String passwordLocked = 'kilitli';
  static const String passwordUnsupported = 'bu sürümde yok';
  static const String passwordRowSet = 'Ayarlı. Şifre ekibin şifre yöneticisinde.';
  static String passwordRowSetAt(String date) =>
      'Ayarlı · son değişiklik $date. Şifre ekibin şifre yöneticisinde.';
  static const String passwordRowNone =
      'Ayarlı değil. Başında kimse yokken bağlanmak için gerekli.';
  static const String change = 'Değiştir';
  static const String set = 'Belirle';
  static const String passwordVerifyTitle = 'Kalıcı şifre · doğrulama';
  static const String passwordVerifyHint =
      'Telefonunla okut, Sense Google hesabınla gir, kodu karşılaştır ve onayla.';
  static const String pairingCode = 'Eşleştirme kodu';
  static String waiting(String left) => 'Onay bekleniyor · $left';
  static const String preparing = 'Doğrulama hazırlanıyor…';
  static const String passwordNewTitle = 'Yeni kalıcı şifre';
  static String passwordUnlocked(String who, String left) =>
      'Doğrulandı: $who · $left içinde kilitlenir. Şifre panele gitmez; yalnız “değiştirildi” kaydı düşer.';
  static const String passwordChangedToast = 'Kalıcı şifre değişti · şifre yöneticisine kaydet';
  static const String passwordInSettings = 'Başında kimse yokken bağlanmak için';
  static const String passwordInSettingsHint =
      'Şifre ekibin şifre yöneticisinde durur; burada gösterilmez.';
  static const String openInSettings = "Ayarlar'da aç";
  static const String openRow = 'Aç';
  static const String closeRow = 'Kapat';

  // Live password rules (YH H2; same rule as the service, src/sense/password/rule.rs).
  static const String ruleLength = '12–64 karakter';
  static const String ruleCharset = 'Boşluk yok, İngilizce harf/rakam/işaret';
  static const String ruleSequence = '1234 ya da aaaa gibi dizi yok';
  static const String ruleId = 'Kimliği içermiyor';
  static const String ruleSame = 'İki şifre aynı';

  // Role (H2, S4).
  static const String role = 'Bu bilgisayarın rolü';
  static const String roleChanging = 'değişiyor';
  static const String roleHint =
      'Bu bilgisayara Host ya da Controller eklenebilir, biri kaldırılabilir. Değişiklik Sense hesabıyla doğrulanır ve panelin denetim kaydına düşer.';
  static const String roleController = 'Controller';
  static const String roleHostText = 'Ekip bu bilgisayara uzaktan bağlanabilir.';
  static const String roleControllerText = 'Bu bilgisayardan başka bilgisayarlara bağlanırsın.';
  static const String installed = 'kurulu';
  static String willAdd(List<String> names) => '${names.join(', ')} eklenecek';
  static String willRemove(List<String> names) => '${names.join(', ')} kaldırılacak';
  static const String hostRemoveNote =
      'Host kaldırılınca Sense ekibi bu bilgisayara artık bağlanamaz; panelde “Host kaldırıldı” görünür. ';
  static const String hostAddNote =
      'Host eklenince ayarlar kilitlenir, yetkiler panelden gelir; kalıcı şifre belirlenmeli. ';
  static const String controllerAddNote =
      'Controller eklenince bu bilgisayardan, hesabına atanmış projelere bağlanabilirsin. ';
  static const String restartNote =
      'Uygulanırken Sense Remote yeniden açılır; süren bağlantı varsa kesilir. ';
  static String verifyNote(bool mac) =>
      'Değişiklik için Sense hesabınla doğrula; ${mac ? 'macOS yönetici parolası' : 'Windows yönetici onayı'} istenir.';
  static const String lastRole =
      "En az bir rol kalmalı. Sense Remote'u kaldırmak için bilgisayarın uygulama kaldırma ekranını kullan.";
  static const String verifyWithSense = 'Sense hesabıyla doğrula';
  static const String roleVerifyHint =
      'Tarayıcıda Sense Google hesabınla gir, kodu karşılaştır, onayla.';
  static const String roleWaitLong = 'Onay bekleniyor · en çok 3 dakika';
  static String roleApplying(bool mac) => mac
      ? 'Rol uygulanıyor… macOS yönetici parolasını isteyecek.'
      : 'Rol uygulanıyor… Windows yönetici onayı isteyecek.';
  static const String roleErrAdminDenied = 'Yönetici onayı verilmedi; rol değişmedi.';
  static const String roleErrDenied =
      'Hesabının bu bilgisayarda rol değiştirme yetkisi yok (panelde “Bilgisayar kurma”).';
  static const String roleErrTimeout = 'Onay zamanında gelmedi. Yeniden doğrula.';
  static const String roleErrNetwork = 'Panele ulaşılamadı. Ağ bağlantısını denetleyip yeniden dene.';
  static const String roleErrOther = 'Rol değiştirilemedi. Yeniden dene.';

  // Recent connections (H2).
  static const String recent = 'Son bağlantılar';
  static const String recentNone = 'henüz yok';
  static const String recentEmpty = 'Bu bilgisayara henüz bağlanılmadı.';
  static String screens(int n) => '$n ekran';
  static const String today = 'bugün';
  static const String yesterday = 'dün';
  static const List<String> months = [
    'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', 'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara', //
  ];
}
