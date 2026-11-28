// Sense Remote (Sürüm 12, FO-A4, FO-A11): text of the session note popup and of the note
// row on the ended card. Turkish only (YH T2, #59). Prototype: `noteHTML`, `endSim`
// (`.endnote`, `.nsaved`), PANES.note.

abstract final class SenseNoteStrings {
  /// Popup id in the connection window's one popup place (T7).
  static const String popupId = 'sense-note';

  static const String title = 'Oturum notu';
  static const String subtitle = 'Denetim kaydına yazılır';

  /// Live line: while ending ("Bitir" was pressed) and in the middle of a session.
  static const String liveEnding = 'Bitirmeden önce';
  static String liveMid(String duration) => 'Oturum sürüyor · $duration';
  static const String liveAfterEnd = 'Bağlantı bitti';

  static const String boxTitle = 'Not isteğe bağlı';
  static const String rowComputer = 'Bilgisayar';
  static const String rowDuration = 'Süre';
  static const String rowSession = 'Bu oturumda';
  static String sessionCounts(int messages, int files) => '$messages mesaj · $files dosya';

  static const String category = 'Ne yaptın?';
  static const String empty = 'boş';
  static String chars(int n) => '$n karakter';
  static const String placeholder = 'Örn. Ekran 2 sürücüsü güncellendi, görüntü takılması bitti.';

  /// Ready chips; a tap adds the word to the note (" · " between).
  static const List<String> chips = [
    'Bakım',
    'Sürücü güncelleme',
    'Arıza giderme',
    'İçerik yükleme',
    'Kontrol',
  ];
  static const String chipJoin = ' · ';

  static const String hint = 'Not yalnız denetim kaydına yazılır ve Sense ekibine görünür; sahadaki kişi görmez.';

  // Buttons.
  static const String cancel = 'Vazgeç';
  static const String skipAndEnd = 'Notsuz bitir';
  static const String saveAndEnd = 'Notu kaydet ve bitir';
  static const String close = 'Kapat';
  static const String save = 'Notu kaydet';

  /// Toast after a note saved in the middle of a session (or an empty one).
  static const String savedToast = 'Not kaydedildi · denetim kaydına yazıldı';
  static const String emptyToast = 'Not boş';

  // Ended card (O14): "Not ekle" → a field in the card + Kaydet.
  static const String addNote = 'Not ekle';
  static const String endPlaceholder = 'Bu oturumda ne yaptın?';
  static const String endSave = 'Kaydet';
  static const String saved = 'Oturum notu kaydedildi · denetim kaydına yazıldı';

  /// While the note is typed the window does not go back by itself.
  static const String holdHome = 'Not yazılırken ana ekrana dönülmez';
}
