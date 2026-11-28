// Sense Remote (Sürüm 12, ST 7): text of the TCP tunnel window. Turkish only (YH T2, #59).
// Prototype: `auxTun` (rules, "Dinleniyor", empty list, listen error, add form).

abstract final class SenseTunnelStrings {
  /// Window and frame title.
  static const String title = 'TCP tünel';

  // ---- list ----
  static const String colLocal = 'Yerel';
  static const String colRemote = 'Uzak';
  static const String colStatus = 'Durum';
  static const String listening = 'Dinleniyor';
  static const String notListening = 'Dinlenemiyor';
  static const String close = 'Kapat';

  /// "Giriş Salonu PC-2 › localhost:80".
  static String remote(String computer, String address) => '$computer › $address';

  static const String emptyTitle = 'Henüz tünel yok';
  static String emptyBody(String computer) =>
      'Bu bilgisayardaki bir portu, $computer üzerindeki bir porta bağlamak için aşağıdan kural ekle. '
      'Ekran açılmaz; tüneller pencere kapanınca kapanır.';

  // ---- add form ----
  static const String localPort = 'Yerel port';
  static const String remoteAddress = 'Uzak adres';
  static const String localPortHint = '8080';
  static const String remoteAddressHint = 'localhost:80';
  static const String add = 'Tünel ekle';
  static String listeningCount(int n) => '$n dinleniyor';

  static const String errPort = 'Yerel port 1–65535 arasında olmalı.';
  static const String errRemote = 'Uzak adres “ad:port” biçiminde olmalı, örn. localhost:80.';
  static String errDuplicate(int port) => 'Yerel port $port zaten listede.';

  // ---- listen errors (RustDesk "Failed to listen on N: …") ----
  static String inUse(int port) => 'Yerel port $port başka bir program tarafından kullanılıyor.';
  static String denied(int port) => 'Yerel port $port için Windows izin vermiyor; port ayrılmış olabilir.';
  static String failed(int port) => 'Yerel port $port dinlenemedi.';

  static const String note =
      'Tüneller yalnız bu bilgisayardan (127.0.0.1) erişilir. Her tünel denetim kaydına yazılır; '
      'aktarılan veri kaydedilmez.';

  /// Live line before the first tunnel connection (RustDesk connects on first use).
  static const String ready = 'Hazır';
}
