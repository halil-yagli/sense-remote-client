// Sense Remote: words of the remote session bar, the Sense island and the four
// lists (YH O1–O7, T9; prototype "ÜST ÇUBUK", "SENSE ADASI", "ÜST ÇUBUK LİSTELERİ").
// Turkish only (T2, #59). "RustDesk" never appears here.

abstract final class SenseSessionStrings {
  // ---- Bar (O1) ----
  static const String screens = 'Ekranlar';
  static const String display = 'Görüntü';
  static const String keyboard = 'Klavye ve fare';
  static const String keyboardShort = 'Klavye';
  static const String actions = 'Eylemler';
  static const String status = 'Bilgisayar durumu';
  static const String statusShort = 'Durum';
  static const String info = 'Ekran bilgisi';
  static const String infoShort = 'Ekran';
  static const String ghost = 'Hayalet mod';
  static const String ghostShort = 'Hayalet';
  static const String ghostOn = 'Hayalet mod açık';
  static const String ghostOnShort = 'Hayalet · açık';
  static const String fullscreen = 'Tam ekran';
  static const String fullscreenShort = 'Tam';
  static const String fullscreenExit = 'Tam ekrandan çık';
  static const String end = 'Bitir';
  static const String endTooltip = 'Bağlantıyı bitir';
  static const String ghostTooltip = 'Sahadaki ekranlarda "Bakım yapılıyor" perdesi';

  // Status tags next to the lists (O1).
  static const String tagRecording = 'Kayıt';
  static const String tagViewOnly = 'Yalnız izle';
  static const String tagInputLocked = 'Giriş kilitli';

  // Connection line (O1, T6).
  static const String direct = 'Doğrudan';
  static const String relay = 'Aktarmalı';
  static const String wavy = 'Dalgalı';
  static const String noImage = 'Görüntü gelmiyor';
  static const String connecting = 'Bağlanıyor…';
  static const String linkDetail = 'Bağlantı ayrıntısı';
  static String fps(int v) => '$v fps';
  static String ms(int v) => '$v ms';

  // Remote image scale (O1).
  static String scaleNote(int w, int h, int pct) => '$w×$h · %$pct ölçekte';
  static String scaleNoteShort(int pct) => '%$pct ölçekte';

  // ---- Island (O2) ----
  static const String islandHide = 'Gizle';
  static const String islandShow = 'Göster';
  static const String islandLabel = 'Çubuğu gizle / göster';

  // ---- Ghost mode notes (S9-b; core event `sense_privacy_note`) ----
  static const String ghostDisplay1 = 'Hayalet mod için önce Ekran 1’e geç';
  static const String ghostUnavailable = 'Hayalet mod bu bağlantıda kullanılamıyor';
  static String ghostNote(String code) {
    switch (code) {
      case 'unsupported':
        return 'Hayalet mod bu bilgisayarda desteklenmiyor';
      case 'denied':
        return 'Hayalet mod reddedildi';
      case 'on_failed':
        return 'Hayalet mod açılamadı';
      case 'off_failed':
        return 'Hayalet mod kapatılamadı';
      case 'off_by_peer':
        return 'Hayalet mod sahadan kapatıldı';
      case 'off_unknown':
        return 'Hayalet mod kapandı';
    }
    return 'Hayalet mod durumu değişti';
  }

  // ---- Lists, shared (O7) ----
  static const String frequent = 'Sık kullanılan';
  static const String noRights = 'Yetkin yok · panelden';
  static const String saved = 'Uygulandı';
  static const String on = 'açık';
  static const String off = 'kapalı';
  static const String none = 'yok';
  static const String technical = 'teknik';

  // ---- Ekranlar (O3) ----
  static String screenN(int n) => 'Ekran $n';
  static const String primary = 'ana';
  static const String all = 'Tümü';
  static const String allSub = 'birlikte';
  static const String allScreens = 'Tüm ekranlar';
  static const String individualWindows = 'Her ekranı ayrı pencerede aç';
  static const String resolution = 'Uzak çözünürlük';
  static const String resolutionOriginal = 'Uzak bilgisayarın kendi çözünürlüğü';
  static const String resolutionFitLocal = 'Bu ekrana uydur';
  static const String multiMonitor = 'Çok monitör';
  static const String useAllMyDisplays = 'Tüm ekranlarımı kullan';

  /// Sürüm 10 (#116): the change could not be applied in this session.
  static const String appliesNextConnection = 'yeni bağlantıda geçerli';
  static const String singleScreen = 'tek ekran';
  static const String allMine = 'tüm ekranlarım';
  static const String virtualDisplay = 'Sanal ekran';
  static const String virtualAdd = 'Sanal ekran ekle';
  static const String virtualRemoveAll = 'Tüm sanal ekranları çıkar';
  static String virtualCount(int n) => '$n sanal ekran';
  static const String customResolution = 'Özel çözünürlük';
  static const String customResolutionHint = 'sanal ekran';
  static const String customResolutionWidth = 'Genişlik';
  static const String customResolutionHeight = 'Yükseklik';
  static const String customResolutionApply = 'Uygula';
  static String customResolutionRange(int min, int max) => 'Genişlik ve yükseklik $min–$max arası olmalı';

  // ---- Görüntü (O4) ----
  static const String size = 'Boyut';
  static const String fit = 'Sığdır';
  static const String original = '1:1';
  static const String quality = 'Kalite';
  static const String qualityBest = 'İyi';
  static const String qualityBalanced = 'Dengeli';
  static const String qualityLow = 'Hızlı';
  static const String refresh = 'Görüntüyü yenile';
  static const String scaleScroll = 'Ölçek ve kaydırma';
  static const String fitWindow = 'Pencereye sığdır';
  static const String originalSize = 'Gerçek boyut';
  static const String customScale = 'Özel ölçek';
  static const String scroll = 'Kaydırma';
  static const String scrollAuto = 'İmleçle';
  static const String scrollBar = 'Çubukla';
  static const String scrollEdge = 'Kenara gelince';
  static const String resetView = 'Görünümü sıfırla';
  static const String adjustWindow = 'Pencereyi uzak ekran boyutuna getir';
  static const String customQuality = 'Özel kalite';
  static const String qualityPct = 'Kalite';
  static const String frameRate = 'Kare hızı';
  static const String trueColor = 'Gerçek renk (4:4:4)';
  static const String codec = 'Kodek';
  static const String codecAuto = 'Otomatik';
  static const String audio = 'Ses';
  static const String mute = 'Uzak bilgisayarın sesini kapat';
  static const String remoteImage = 'Uzak ekran';
  static String scalePct(int pct) => '%$pct';
  static const String renderSection = 'Gelişmiş';
  static const String textureRender = 'Doku ile çiz';
  static const String d3dRender = 'D3D ile çiz';
  static const String nextConnection = 'yeni bağlantıda';
  static const String d3dHint = 'Windows · yeni bağlantıda';
  static const String renderTexture = 'doku';
  static const String renderD3d = 'D3D';
  static const String renderDefault = 'varsayılan';

  // ---- Klavye ve fare (O5) ----
  static const String keyboardMode = 'Klavye';
  static const String modeMap = 'Tuş eşleme';
  static const String modeTranslate = 'Çeviri';
  static const String modeLegacy = 'Eski klavye modu';
  static const String viewOnly = 'Yalnız izle';
  static const String viewOnlyHint = 'fare ve klavye gitmez';
  static const String swapCtrlCmd = 'Ctrl ile Cmd yer değiştirsin';
  static const String swapCtrlCmdHint = 'Mac';
  static const String keyboardSection = 'Klavye';
  static const String localKeyboard = 'Bu bilgisayarın klavyesi';
  static const String kbIso = 'ISO';
  static const String kbNotIso = 'ISO değil';
  static const String shortcuts = 'Kısayollar';
  static String shortcutsSummary(int n) => '$n kısayol · salt okunur';
  static const String shortcutsOff = 'kapalı · Ayarlar’dan açılır';
  static const String shortcutUnbound = 'atanmadı';
  static const String scFullscreen = 'Tam ekran';
  static const String scToolbar = 'Çubuğu gizle / göster';
  static const String scNextScreen = 'Sonraki ekran';
  static const String scCtrlAltDel = 'Ctrl+Alt+Del gönder';
  static const String scScreenshot = 'Ekran görüntüsü al';
  static const String scEnd = 'Bağlantıyı bitir';
  static const String mouse = 'Fare ve imleç';
  static const String mouseSummary = 'uzak imleç';
  static const String showRemoteCursor = 'Uzak imleci göster';
  static const String showMyCursor = 'Kendi imlecimi göster';
  static const String followRemoteCursor = 'Uzak imleci izle';
  static const String followRemoteWindow = 'Uzak pencere odağını izle';
  static const String zoomCursor = 'İmleci ölçekle';
  static const String relativeMouse = 'Göreli fare modu';
  static const String relativeMouseHint = '3B / oyun motoru';
  static const String reverseWheel = 'Fare tekerini ters çevir';
  static const String swapMouse = 'Sol ve sağ tuş yer değiştirsin';
  static const String trackpadSpeed = 'Trackpad hızı';

  // ---- Eylemler (O6) ----
  static const String ctrlAltDel = 'Ctrl + Alt + Del gönder';
  static const String screenshot = 'Ekran görüntüsü al';
  static const String screenshotBusy = 'Ekran görüntüsü alınıyor…';
  static const String screenshotAll = 'Tümü görünümünde alınamaz; tek ekrana geç';
  static const String lockScreen = 'Uzak ekranı kilitle';
  static const String restart = 'Uzak bilgisayarı yeniden başlat…';
  static const String restartConfirm = 'Uzak bilgisayar yeniden başlatılsın mı?';
  static const String restartGo = 'Yeniden başlat';
  static const String blockInput = 'Sahadaki fare ve klavyeyi kilitle';
  static const String record = 'Oturumu kaydet';
  static const String clipboardFiles = 'Pano ve dosya';
  static const String clipboardOpen = 'pano açık';
  static const String clipboardOff = 'pano kapalı';
  static const String typeClipboard = 'Panodaki metni tuşlarla yaz';
  static const String fileCopyPaste = 'Dosya kopyala-yapıştır';
  static const String disableClipboard = 'Panoyu kapat';
  static const String remoteFiles = 'Uzak dosyalara göz at';
  static const String remoteFilesHint = 'sahada kimse yokken';
  static const String session = 'Oturum';
  static const String elevation = 'Yönetici yetkisi iste';
  static const String lockAfterEnd = 'Oturum bitince uzak ekranı kilitle';
  static const String note = 'Oturuma not ekle';
  static const String advanced = 'Gelişmiş';
  static const String advancedSummary = 'terminal, tünel…';
  static const String advancedSummaryCamera = 'terminal, tünel, kamera…';
  static const String terminal = 'Terminal aç';
  static const String terminalAdmin = 'Terminal aç (yönetici)';
  static const String terminalAdminHint = 'Windows';
  static const String camera = 'Kamerayı görüntüle';
  static const String cameraHint = 'ayrı pencere';
  static const String forceRelay = 'Bu bilgisayara hep aktarmayla bağlan';
  static const String forceRelayHint = 'sonraki bağlantıda';
  static const String forceRelayEverywhere = 'panelden açık';
  static const String tunnel = 'TCP tüneli';
  static const String fingerprint = 'Parmak izini kopyala';
  static const String fingerprintCopied = 'Parmak izi kopyalandı';
  static const String fingerprintNone = 'Parmak izi yok';
  static const String typed = 'Panodaki metin yazıldı';

  // ---- Kamera penceresi (O6 "Kamerayı görüntüle") ----
  static const String cameraWindow = 'Kamera';
  static String cameraN(int n) => 'Kamera $n';
  static const String cameraConnecting = 'Kamera bağlanıyor…';
  static const String cameraNone = 'Kamera bulunamadı';
  static String cameraCount(int n) => '$n kamera';
  static const String cameraEndTooltip = 'Kamera bağlantısını bitir';
}
