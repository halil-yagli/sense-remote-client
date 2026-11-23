// Sense Remote: texts of the About page (YH C4; prototype `aboutView2`).
// Turkish only (YH T2, #59). The AGPL notice stays reachable (Açık kaynak
// lisansları category); the upstream product is never named.

abstract final class SenseAboutStrings {
  static const String titleBold = 'Sense';
  static const String titleThin = ' Remote';
  static String version(int n) => 'Sürüm $n';

  // Tiles.
  static const String role = 'Bu bilgisayar';
  static const String panel = 'Panel';
  static String panelSignedIn(String name) => 'bağlı · $name';
  static const String panelManaged = 'panelden yönetilir';
  static const String panelSignedOut = 'giriş yapılmadı';
  static const String account = 'Hesap';
  static String accountValue(String name) => '$name · Sense Department';
  static const String accountNone = 'yok';
  static const String id = 'Kimlik';
  static const String fingerprint = 'Parmak izi';

  // Licenses category.
  static const String licenses = 'Açık kaynak lisansları';
  static const String licensesSummary = 'AGPL-3.0 · kaynak kodu herkese açık';
  static const String licensesBody =
      'Sense Remote, açık kaynak bir uzaktan masaüstü altyapısı üzerine kuruludur (AGPL-3.0). '
      'Değiştirilmiş kaynak kodu herkese açık depodadır.';
  static const String source = 'Kaynak kodu';
  static const String licenseText = 'Lisans metni';
  static String base(String v) => 'Taban sürüm: $v';
  static const String open = 'Aç';

  static String copyright(int year) => '© $year Sense Department';
}
