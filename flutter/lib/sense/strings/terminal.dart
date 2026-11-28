// Sense Remote (Sürüm 12, #157, FO-A5, ST 4–5): text of the terminal window, the admin
// terminal step and the session's terminal popup. Turkish only (YH T2, #59).
// Prototype: `auxTerm` (window), `termHTML` (popup), `.axask` (in-place second step).

abstract final class SenseTerminalStrings {
  /// Window, frame and popup title.
  static const String title = 'Terminal';

  /// Tab label: "Terminal 1".
  static String tabLabel(int n) => 'Terminal $n';

  // ---- footer (`.axfoot`) ----
  static const String normalUser = 'Normal kullanıcı';
  static const String adminRights = 'Yönetici yetkisi';

  /// Chip after the live line of the title bar.
  static const String adminChip = 'Yönetici';
  static const String footNote = 'Açılış denetim kaydına yazılır · komut çıktısı kaydedilmez';
  static const String copyOutput = 'Çıktıyı kopyala';
  static const String copied = 'Kopyalandı';
  static const String openAdmin = 'Yönetici olarak aç';
  static const String closeTerminal = 'Terminali kapat';
  static const String cancel = 'Vazgeç';

  // ---- in-place second step (`.axask`, T7) ----
  static const String askTitle = 'Yönetici olarak açılsın mı?';
  static String askBody(String computer) =>
      'Komutlar $computer üzerinde yönetici yetkisiyle çalışır; servis, sürücü ve program kurulumu '
      'yapılabilir, yanlış komut bilgisayarı bozabilir. Her açılış denetim kaydına yazılır.';

  /// The open terminals of this computer close first (the admin terminal is a new connection).
  static const String askReopenNote = 'Bu bilgisayardaki açık terminal sekmeleri kapanır.';

  // ---- admin request (#157) ----
  static const String requesting = 'Yönetici yetkisi isteniyor';
  static const String requestingBody = 'Panel izni ve bilgisayarın onayı bekleniyor; Windows parolası sorulmaz.';
  static const String failedTitle = 'Yönetici terminali açılamadı';
  static const String openNormal = 'Normal terminal aç';
  static const String windowsAccount = 'Windows hesabıyla aç';
  static const String retry = 'Yeniden dene';

  /// Error code (panel `TermAdminErrorCode`, Host `sense.term-admin-result.err`,
  /// `session_sense_term_admin_begin` codes) → Turkish sentence.
  static String error(String code) => switch (code) {
        // panel
        'token_invalid' => 'Sense hesabındaki oturumun süresi dolmuş. Yeniden giriş yap.',
        'not_admin' => 'Yönetici terminalini yalnız Yönetici rolündeki ekip üyeleri açabilir.',
        'no_terminal_permission' => 'Terminal yetkin yok. Yetkiler Sense panelinden verilir.',
        'device_not_accessible' => 'Bu bilgisayar senin projelerinde değil.',
        'policy_terminal_off' => 'Bu bilgisayarda terminal panelden kapatılmış.',
        'signing_unavailable' => 'Panel şu an izin veremiyor. Biraz sonra yeniden dene.',
        'rate_limited' => 'Çok sık denendi. Bir dakika sonra yeniden dene.',
        'panel_error' => 'Panel beklenmeyen bir yanıt verdi. Biraz sonra yeniden dene.',
        'network' => 'Panele ulaşılamadı. İnternet bağlantısını kontrol et.',
        // Host
        'bad_sig' => 'Bilgisayar izni doğrulayamadı.',
        'expired' => 'İznin süresi doldu. Yeniden dene.',
        'replay' => 'Bu izin daha önce kullanıldı. Yeniden dene.',
        'wrong_host' => 'İzin başka bir bilgisayar için verilmiş.',
        'policy_off' => 'Bu bilgisayarda terminal kapalı.',
        'unsupported' => 'Bu bilgisayarda Windows oturumu açık değil ya da Sense Remote sürümü eski. '
            'Yönetici terminali Windows yönetici hesabıyla açılabilir.',
        // this computer
        'signed_out' => 'Sense hesabına giriş yapılmamış.',
        'busy' => 'Yönetici izni zaten isteniyor.',
        'timeout' => 'Bilgisayar yanıt vermedi.',
        'not_terminal' || 'no_session' => 'Terminal bağlantısı hazır değil.',
        _ => 'Beklenmeyen bir hata oluştu.',
      };

  /// Codes worth a second try with the same rights.
  static bool retryable(String code) => const {
        'expired',
        'replay',
        'network',
        'panel_error',
        'rate_limited',
        'signing_unavailable',
        'timeout',
        'busy',
        'no_session',
      }.contains(code);

  // ---- tab menu ----
  static const String newTab = 'Yeni sekme';
  static const String keepSessionsOn = 'Bağlantı kesilince oturumları koru';
  static const String keepSessionsOff = 'Bağlantı kesilince oturumları koruma';

  // ---- clipboard notice (Sense colours; stock `terminal-clipboard-write-tip`) ----
  static const String clipTitle = 'Terminal panoya yazmak istiyor';
  static const String clipBody = 'Terminaldeki bir uygulama bu bilgisayarın panosuna metin kopyalamak istiyor.';
  static const String clipPersist =
      'İzin verirsen Ayarlar\'dan kapatana kadar bütün bağlantılardaki terminal uygulamaları için geçerli olur. '
      'Elle kopyalama ve yapıştırma etkilenmez.';
  static const String clipAllow = 'İzin ver';
  static const String clipDecline = 'İzin verme';
  static const String clipCopy = 'Panoya kopyala';
  static const String clipDismiss = 'Kapat';

  // ---- session popup (FO-A5) ----
  static const String popupId = 'terminal';
  static const String notOpenYet = 'Henüz açılmadı';
  static const String adminWillOpen = 'Yönetici yetkisiyle açılacak';
  static const String rowComputer = 'Bilgisayar';
  static const String rowRights = 'Yetki';
  static const String rowAudit = 'Denetim kaydı';
  static const String adminWindows = 'Yönetici (Windows)';
  static const String auditAdmin = 'Terminal · yönetici';
  static const String attention = 'Dikkat';
  static const String attentionSummary = 'yönetici yetkisi';
  static const String attentionNote =
      'Komutlar bu bilgisayarda yönetici yetkisiyle çalışır: servis, sürücü ve program kurulumu yapılabilir; '
      'yanlış komut bilgisayarı bozabilir. Yalnız bakım için aç.';
  static const String whoCan = 'Kim açabilir';
  static const String whoCanValue = 'Terminal yetkisi olan Yönetici';
  static const String inPanel = 'Panelde';
  static const String inPanelValue = 'Her açılış denetim kaydına yazılır';
  static const String popupHint = 'Terminal ayrı pencerede açılır; ekran açılmaz.';
  static const String connectedAdmin = 'Bağlı · yönetici';
  static const String connectedNormal = 'Bağlı · normal yetki';
}
