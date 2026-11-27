// Sense Remote: words of the remote files window (#155, U168a) and of the shared
// Sense frame of the secondary windows (files, terminal, tunnel; ST 15, 16).
// Turkish only (YH T2, #59). Prototype: "Uzak dosyalar" and "S12 — terminal ve TCP
// tünel pencereleri" sections.

/// The frame of a secondary window (title bar, tabs, window buttons).
abstract final class SenseAuxStrings {
  static const String minimize = 'Küçült';
  static const String maximize = 'Büyüt';
  static const String restore = 'Önceki boyut';
  static const String close = 'Kapat';
  static const String newTab = 'Yeni sekme';
  static const String closeTab = 'Sekmeyi kapat';
  static const String closeOtherTabs = 'Diğer sekmeleri kapat';

  /// A computer whose name is not known yet (never its ID; ST 16).
  static const String unnamedComputer = 'Uzak bilgisayar';

  // Live line in the title bar.
  static const String connecting = 'Bağlanıyor';
  static const String noConnection = 'Bağlantı yok';
  static const String direct = 'Doğrudan';
  static const String relay = 'Aktarmayla';

  /// "Doğrudan · ekran açılmadı": the window never opens the screen.
  static const String screenNotOpened = 'ekran açılmadı';

  /// Window title (Alt+Tab, taskbar): "Uzak dosyalar · Giriş Salonu PC-2 — Sense Remote".
  static String windowTitle(String kind, String computer, String app) => '$kind · $computer — $app';
}

abstract final class SenseFilesStrings {
  /// Window and frame title.
  static const String title = 'Uzak dosyalar';

  // Panel headers.
  static const String thisComputer = 'Bu bilgisayar';
  static const String drives = 'Sürücüler';
  static String osTag(String os, {required bool remote}) => '$os · ${remote ? 'uzak' : 'bu bilgisayar'}';

  // Path row.
  static const String back = 'Geri';
  static const String up = 'Bir üst klasör';
  static const String refresh = 'Yenile';
  static const String more = 'Diğer işlemler';
  static const String typePath = 'Yol yaz';
  static const String home = 'Ana klasöre git';
  static const String search = 'Bu klasörde ara';
  static const String searchHint = 'Ada göre süz, Esc ile kapat';
  static const String pathHint = 'Klasör yolu, Enter ile aç';

  // Columns.
  static const String colName = 'Ad';
  static const String colSize = 'Boyut';
  static const String colModified = 'Değiştirilme';
  static const String openHint = 'Açmak için çift tıkla';

  // Footer.
  static String items(int n) => '$n öğe';
  static String selected(int n, String? size) => size == null ? '$n seçili' : '$n seçili · $size';
  static const String selectHint = 'seçmek için tıkla, çoklu seçim Ctrl / Shift';

  // Middle.
  static const String send = 'Gönder';
  static const String receive = 'Al';
  static String sendTip(String computer) => 'Seçilenleri $computer bilgisayarına gönder';
  static const String receiveTip = 'Seçilenleri bu bilgisayara al';
  static const String dragHint = 'Sürükle-bırak\nda olur';

  // States of a panel.
  static const String loading = 'Klasör okunuyor';
  static const String emptyTitle = 'Bu klasör boş';
  static const String emptyRemote = 'Dosyaları buraya sol panelden gönderebilirsin.';
  static const String emptyLocal = 'Dosyaları buraya sağ panelden alabilirsin.';
  static const String errorTitle = 'Bu klasör açılamadı';
  static String errorDenied(String path) => 'Erişim izni yok: $path. Bir üst klasöre dönebilirsin.';
  static const String errorTimeout =
      'Karşı bilgisayar 30 saniyede yanıt vermedi; bir kez daha denendi. Bağlantıyı kontrol edip yeniden dene.';
  static const String errorUnreadable = 'Klasör okunamadı; silinmiş ya da taşınmış olabilir.';
  static const String errorOther = 'Klasör okunurken bir hata oldu.';
  static const String goUp = 'Bir üst klasöre dön';
  static const String offlineTitle = 'Bağlantı kesildi';
  static String offlineBody(String computer) =>
      '$computer şu an ulaşılamıyor. Bağlantı gelince liste kendiliğinden yenilenir.';

  // Menu of a panel (right click or ⋯).
  static const String newFolder = 'Yeni klasör';
  static const String newFolderHint = 'Klasör adı';
  static const String create = 'Oluştur';
  static const String rename = 'Yeniden adlandır';
  static const String delete = 'Sil';
  static const String showHidden = 'Gizli dosyaları göster';
  static const String hideHidden = 'Gizli dosyaları gizle';
  static const String selectAll = 'Tümünü seç';
  static const String unselectAll = 'Seçimi kaldır';
  static const String sortName = 'Ada göre sırala';
  static const String sortSize = 'Boyuta göre sırala';
  static const String sortModified = 'Tarihe göre sırala';
  static const String invalidName = 'Geçersiz klasör adı';

  // Transfers.
  static const String transfers = 'Aktarımlar';
  static String transfersSummary(int running, int done) => '$running sürüyor · $done tamamlandı';
  static const String clearDone = 'Tamamlananları temizle';
  static const String transfersEmptyLead = 'Henüz aktarım yok. Bir panelde dosya seç, ortadaki ';
  static const String transfersEmptyOr = ' ya da ';
  static const String transfersEmptyTail = ' ile aktar.';
  static const String sending = 'Gönderiliyor';
  static const String receiving = 'Alınıyor';
  /// "Bu bilgisayar → PC · C:\…": the arrow is drawn (SenseGlyph; Poppins has no →).
  static String routeTail(String to, String path) => '$to · $path';
  static const String done = 'Tamamlandı';
  static const String stopped = 'Aktarım durdu';
  static const String paused = 'Duraklatıldı';
  static const String waiting = 'Bekliyor';
  static const String cancelled = 'İptal edildi';
  static const String skipped = 'Atlandı';
  static const String deleting = 'Siliniyor';
  static const String deleted = 'Silindi';
  static String percent(int p) => '%$p';
  static String speedLeft(String speed, int seconds) => '$speed/sn · $seconds sn kaldı';
  static String speed(String speed) => '$speed/sn';
  static const String resume = 'Sürdür';
  static const String cancel = 'İptal';
  static const String remove = 'Kaldır';
  static const String retry = 'Yeniden dene';

  /// Short month names for "28 Kas 2026 00:38".
  static const List<String> months = [
    'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz', 'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
  ];

  /// Drag feedback: "3 öğe".
  static String dragCount(int n) => '$n öğe';
}
