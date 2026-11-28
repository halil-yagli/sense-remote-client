// Sense Remote (Sürüm 12, #160–#163, #167): words of the "Sık kullanılanlar" list of the
// session bar (prototype `favHTML`, `FAVCAT`, `FAVG`). Turkish only (T2, #59).
// "RustDesk" never appears here.
//
// The catalogue names are keyed by the shortcut id the core uses (`win.taskmgr`,
// `mac.actmon`); `favorites/catalog.dart` keeps the order, group and icon of each one.

abstract final class SenseFavoritesStrings {
  // ---- Bar button (#167) ----
  static const String title = 'Sık kullanılanlar';

  /// Tooltip of the star that stands for the list on a narrow window (#167).
  static const String starTooltip = 'Sık kullanılanlar';

  // ---- Header ----
  static String count(int n) => '$n kısayol';
  static const String linuxChip = 'Linux';

  /// System label under the title (`FOSLBL`).
  static const String osWin = 'Windows için kısayolların';
  static const String osMac = 'Mac için kısayolların';
  static const String osLinux = 'Linux için kısayolların';

  static const String searchHint = 'Kısayol ara…';

  // ---- Sections ----
  static const String mine = 'Kısayollarım';
  static const String recent = 'Son kullanılanlar';
  static const String addable = 'Eklenebilecek kısayollar';
  static const String mineEmpty = 'Aşağıdan kısayol ekle';
  static const String noMatch = 'Eşleşen kısayol yok';
  static const String linuxLater = 'Linux desteği geldiğinde';
  static const String osWaiting = 'Karşı bilgisayarın sistemi bekleniyor';
  static const String loading = 'Kısayollar yükleniyor';

  /// Footer when the choice is kept by the account (#163, #169).
  static const String footer = 'Seçimin hesabına, her işletim sistemi için ayrı kaydedilir.';

  /// Footer while this build cannot store the choice in the account yet.
  static const String footerLocal =
      'Seçimin şimdilik yalnız bu açık uygulamada kalır; hesaba kaydetme bu sürümde yok.';

  // ---- Row ----
  static const String open = 'Aç ›';
  /// Drawn with the library caret after it (Poppins has no ▾).
  static const String openPane = 'Aç';
  static const String ask = 'Sor ›';
  static const String addKey = '+ tuş';
  static const String keyTooltip = 'Klavye kısayolu ata';
  static const String keyNone = 'Yok';
  static const String dragTooltip = 'Sürükleyerek sırala';
  static const String needsInput = 'Klavye ve fare yetkisi gerekiyor';
  static const String pendingApproval = 'Yönetici onayı bekliyor';
  static const String pendingTag = 'Onay bekliyor';
  static const String unavailable = 'Bu bilgisayarda kullanılamaz';

  /// Key label of slot [n] (1–9): Ctrl+Alt+Shift+n, on a Mac Cmd+Option+Shift+n (K4, #71).
  static String keyLabel(int n, {required bool mac}) =>
      mac ? 'Cmd+Option+Shift+$n' : 'Ctrl+Alt+Shift+$n';

  // ---- Catalogue groups (`FAVG`) ----
  static const String gFiles = 'Dosya ve sistem';
  static const String gNetwork = 'Ağ ve sorun giderme';
  static const String gAdmin = 'Yönetim araçları';
  static const String gSettings = 'Ayarlar';
  static const String gCommand = 'Komut';
  static const String gActions = 'Sistem hareketleri';
  static const String gHealth = 'Sistem durumu';
  static const String gScreen = 'Ekran ve ses';
  static const String gMac = 'Mac’e özel';
  static const String gCustom = 'Özel kısayollar';

  /// "2 seçili · 9" when some are chosen, else "9".
  static String groupCount(int chosen, int all) => chosen > 0 ? '$chosen seçili · $all' : '$all';

  // ---- Panes under a row ----
  static const String ipAddress = 'IP adresi';
  static const String ipGateway = 'Ağ geçidi';
  static const String ipDns = 'DNS';
  static const String ipUnknown = 'Ağ bilgisi henüz gelmedi';
  static const String pingHint = 'Adres ya da IP';
  static const String pingStart = 'Başlat';
  static const String pingResult = 'Sonuç';
  static const String pingRunning = 'Ping atılıyor…';
  static const String pingDefault = '8.8.8.8';
  static const String pingUnsupported = 'Karşı bilgisayar ping sonucunu henüz göndermiyor';
  static const String pingEmpty = 'Adres yaz';

  /// `4/4 yanıt · ort. 18 ms · kayıp %0`.
  static String pingLine(int got, int sent, int? avgMs, int lossPct) =>
      '$got/$sent yanıt · ort. ${avgMs == null ? '—' : '$avgMs'} ms · kayıp %$lossPct';
  static const String windowList = 'Pencere listesi';
  static const String windowsUnsupported = 'Pencere listesi karşı bilgisayardan henüz alınamıyor';
  static const String windowClose = 'Kapat';
  static const String windowQuit = 'Çık';

  // Sürüm 12 (#171): the Host's own answers (ping, window list, IP card).
  static const String pingBadAddress = 'Yalnız ad ya da IP adresi yaz (harf, rakam, nokta, tire)';
  static const String windowsLoading = 'Pencereler alınıyor…';
  static const String windowsEmpty = 'Açık pencere yok';
  static const String windowHung = 'yanıt vermiyor';

  /// "Sergi uygulaması — yanıt vermiyor".
  static String windowName(String name, {required bool hung}) => hung ? '$name — $windowHung' : name;

  /// Toast after a window / app was closed: "Medya oynatıcı kapatıldı · Giriş Salonu PC-2".
  static String windowClosed(String name, String computer) =>
      computer.isEmpty ? '$name kapatıldı' : '$name kapatıldı · $computer';

  // ---- Custom shortcut form (#161, K3, K8) ----
  static const String addCustom = '+ Özel kısayol ekle';
  static const String formName = 'Kısayol adı';
  static const String formOsWin = 'İşletim sistemi: Windows';
  static const String formOsMac = 'İşletim sistemi: macOS';
  static const String formOsLinux = 'İşletim sistemi: Linux';
  static const String formKindProgram = 'Tür: Program yolu';
  static const String formKindFolder = 'Tür: Klasör';
  static const String formKindUrl = 'Tür: Web adresi';
  static const String formPathProgram = r'C:\Program\uygulama.exe';
  static const String formPathProgramMac = '/Applications/Uygulama.app';
  static const String formPathFolder = r'C:\Klasör';
  static const String formPathFolderMac = '/Users/Paylaşılan';
  static const String formPathUrl = 'https://…';
  static const String formScopePc = 'Kapsam: yalnız bu bilgisayar';
  static const String formScopeProject = 'Kapsam: projedeki tüm bilgisayarlar';
  static const String formScopeAll = 'Kapsam: herkes';
  static const String formNote = 'Eklenince “Yönetici onayı bekliyor” durumuna girer; onaylanana kadar çalışmaz.';
  static const String formAdd = 'Ekle';
  static const String formMissing = 'Ad ve yol / adres gerekli';
  static const String formBadUrl = 'Web adresi https:// ile başlamalı';
  static const String formBadPath = 'Tam yol yaz (ör. C:\\… ya da /…); komut satırı eklenmez';
  static const String formTooLong = 'Ad en çok 60 harf';
  static const String formSending = 'Gönderiliyor…';
  static const String formUnsupported = 'Özel kısayol isteği bu sürümde gönderilemiyor';
  static const String formFailed = 'İstek gönderilemedi; biraz sonra yeniden dene';

  /// Descriptions of a custom shortcut row: "Program · yalnız bu bilgisayar".
  static const String kindProgram = 'Program';
  static const String kindFolder = 'Klasör';
  static const String kindUrl = 'Web adresi';
  static const String scopePc = 'yalnız bu bilgisayar';
  static const String scopeProject = 'projedeki tüm bilgisayarlar';
  static const String scopeAll = 'herkes';

  // ---- Notifications ----
  static String opened(String name, String computer) =>
      computer.isEmpty ? '$name açıldı' : '$name açıldı · $computer';
  static String added(String name) => '$name · kısayollara eklendi';
  static String removed(String name) => '$name · kısayollardan çıkarıldı';
  static const String tooMany = 'En çok 24 kısayol eklenir';
  static String customSent(String os) => 'Yönetici onayına gönderildi · $os';
  static String pendingRun(String name) => 'Yönetici onayı bekleniyor · $name';

  /// A hotkey on a row that asks first or opens a pane: it is done from the list.
  static String fromList(String name) => '$name · listeden aç';

  /// Why the Host did not run it (`sense.shortcut-result.err`, plan §2.1).
  static const String errUnknownId = 'Karşı bilgisayar bu kısayolu tanımıyor; sürümü eski olabilir';
  static const String errNoPermission = 'Klavye ve fare yetkisi gerekiyor';
  static const String errUnsupportedOs = 'Bu kısayol karşı bilgisayarın sisteminde yok';
  static const String errNeedsAdmin = 'Karşı bilgisayarda yönetici onayı gerekiyor';
  static const String errFailed = 'Kısayol açılamadı';
  static const String errTimeout = 'Karşı bilgisayar yanıt vermedi; kısayolları desteklemiyor olabilir';
  static const String errNotSent = 'Kısayol gönderilemedi';

  static String failed(String name, String why) => '$name · $why';

  // ---- Questions asked in place (`ask`) ----
  static const String askResetNic = 'Ağ bağdaştırıcısı sıfırlansın mı?';
  static const String askResetNicDetail = 'Bağlantı birkaç saniye kopar, kendiliğinden geri gelir.';
  static const String askResetNicOk = 'Sıfırla';
  static const String askLogoff = 'Oturum kapatılsın mı?';
  static const String askLogoffDetail = 'Açık programlardaki kaydedilmemiş işler kaybolabilir.';
  static const String askLogoffOk = 'Oturumu kapat';

  // ---- Catalogue: id → (name, description) (`FAVCAT`, #160, #161) ----
  static const Map<String, (String, String)> names = {
    // Windows · Dosya ve sistem
    'win.thispc': ('Bu bilgisayar', 'Sürücüler ve cihazlar'),
    'win.explorer': ('Dosya Gezgini', 'Klasörleri aç'),
    'win.taskmgr': ('Görev Yöneticisi', 'Süreçler ve kaynak kullanımı'),
    'win.sysprop': ('Sistem özellikleri (gelişmiş)', 'Ad, ortam değişkenleri, performans'),
    'win.programs': ('Programlar ve Özellikler', 'Kurulu uygulamalar, kaldır'),
    // Windows · Ağ ve sorun giderme
    'win.netadapt': ('Ağ bağdaştırıcıları', 'Denetim Masası › Ağ Bağlantıları'),
    'win.netset': ('Ağ ve İnternet ayarları', 'Wi-Fi, Ethernet, proxy'),
    'win.ipinfo': ('IP bilgisi', 'IP, ağ geçidi, DNS kartı'),
    'win.flushdns': ('DNS önbelleğini temizle', 'ipconfig /flushdns'),
    'win.resetnic': ('Ağ bağdaştırıcısını sıfırla', 'Kapatıp açar; bağlantı kısa süre kopar'),
    'win.ping': ('Ping', 'Adres yaz, ms ve kayıp gör'),
    'win.firewall': ('Güvenlik Duvarı', 'Windows Defender Güvenlik Duvarı'),
    'win.shares': ('Paylaşılan klasörler', 'Ağda paylaşılanlar'),
    'win.printers': ('Yazıcılar', 'Yazıcılar ve tarayıcılar'),
    // Windows · Yönetim araçları
    'win.services': ('Hizmetler', 'Windows hizmetlerini yönet'),
    'win.devmgr': ('Aygıt Yöneticisi', 'Sürücüler ve donanım'),
    'win.diskmgmt': ('Disk Yönetimi', 'Bölümler ve sürücüler'),
    'win.eventvwr': ('Olay Görüntüleyicisi', 'Sistem günlükleri'),
    'win.tasksch': ('Görev Zamanlayıcı', 'Zamanlanmış görevler'),
    'win.regedit': ('Kayıt Defteri Düzenleyicisi', 'Dikkatli kullan'),
    // Windows · Ayarlar
    'win.ctrlpanel': ('Denetim Masası', 'Klasik ayar sayfaları'),
    'win.winset': ('Windows Ayarları', 'Yeni ayarlar uygulaması'),
    'win.dispset': ('Ekran ayarları', 'Çözünürlük, ölçek, monitörler'),
    'win.sndset': ('Ses ayarları', 'Çıkış ve giriş aygıtları'),
    // Windows · Komut
    'win.cmd': ('Komut istemi', 'cmd.exe'),
    'win.ps': ('PowerShell', 'Windows PowerShell'),
    // Windows · Sistem hareketleri
    'win.showdesk': ('Masaüstünü göster', 'Tüm pencereleri geçici gizle'),
    'win.cad': ('Ctrl+Alt+Del', 'Güvenli ekranı aç'),
    'win.restexp': ('Gezgini yeniden başlat', 'Görev çubuğu donunca'),
    'win.killhung': ('Yanıt vermeyen programı kapat', 'Açılınca pencere listesi gelir'),
    'win.lock': ('Ekranı kilitle', 'Sahadaki kişi şifresiyle açar'),
    'win.logoff': ('Oturumu kapat', 'Açık programlar kapanır'),
    'win.clip': ('Panoyu temizle', 'Kopyalanan her şeyi sil'),
    'win.minall': ('Tüm pencereleri küçült / geri getir', 'Win+D gibi, ikisi arasında geçer'),
    // Windows · Sistem durumu
    'win.winupd': ('Windows Update', 'Güncellemeler ve geçmiş'),
    'win.power': ('Güç seçenekleri', 'Uyku, ekran kapanma, güç planı'),
    'win.startup': ('Başlangıç programları', 'Açılışta çalışanlar'),
    'win.temp': ('Temp klasörü', 'Geçici dosyalar'),
    'win.resmon': ('Kaynak İzleyicisi', 'İşlemci, bellek, disk, ağ'),
    'win.perfmon': ('Performans İzleyicisi', 'Sayaçlar ve grafikler'),
    'win.datetime': ('Tarih ve saat', 'Saat dilimi ve eşitleme'),
    // Windows · Ekran ve ses
    'win.gpu': ('NVIDIA / AMD kontrol paneli', 'Ekran kartı ayarları'),
    'win.mixer': ('Ses karıştırıcı', 'Uygulama başına ses'),
    'win.defout': ('Varsayılan ses çıkışı', 'Çıkış aygıtını seç'),
    'win.night': ('Gece ışığı / ölçek', 'Renk sıcaklığı ve yazı ölçeği'),
    // macOS
    'mac.finder': ('Finder', 'Klasörleri aç'),
    'mac.actmon': ('Etkinlik Monitörü', 'Süreçler ve kaynak kullanımı'),
    'mac.net': ('Ağ', 'Ağ ayarları'),
    'mac.diskutil': ('Disk İzlencesi', 'Sürücüler ve bölümler'),
    'mac.console': ('Konsol', 'Sistem günlükleri'),
    'mac.sysset': ('Sistem Ayarları', 'Ana ayarlar sayfası'),
    'mac.mdisp': ('Ekranlar', 'Çözünürlük ve düzen'),
    'mac.msnd': ('Ses', 'Çıkış ve giriş aygıtları'),
    'mac.term': ('Terminal', 'zsh'),
    'mac.forcequit': ('Uygulamadan çıkmaya zorla', 'Açılınca uygulama listesi gelir'),
    'mac.privacy': ('Gizlilik ve güvenlik', 'Ekran kaydı ve erişilebilirlik izinleri'),
    'mac.energy': ('Enerji / uyku', 'Uyku ve ekran kapanma'),
    'mac.downloads': ('İndirilenler', 'İndirilenler klasörü'),
    'mac.maclock': ('Ekranı kilitle', 'Sahadaki kişi şifresiyle açar'),
  };
}
