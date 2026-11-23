// Sense Remote: words shared by the component library and every screen (YH T2:
// Turkish only, #59). Screen-specific text lives in its own strings/<akış>.dart.

abstract final class SenseCommonStrings {
  /// App name (YH T2: always "Sense Remote").
  static const String appName = 'Sense Remote';

  // Popup header (T7, onaylı popup tasarımı).
  static const String close = 'Kapat';
  static const String minimize = 'Küçült';
  static const String expand = 'Aç';

  // In-place second step (T7).
  static const String cancel = 'Vazgeç';

  // Drop-down list (T7, #43).
  static const String choose = 'Seç';

  // Common buttons and states.
  static const String copy = 'Kopyala';
  static const String copied = 'Kopyalandı';
  static const String saved = 'Kaydedildi';
  static const String retry = 'Yeniden dene';
  static const String unreadable = 'okunamadı';

  /// Locked switch / option (T7).
  static const String managedByPanel = 'Panelden yönetilir';

  // Splash (T8).
  static const String splashOpening = 'Sense Remote açılıyor';

  /// After an update: "Sürüm N kuruluyor · Sense Remote yeniden açılıyor".
  static String splashUpdating(int version) =>
      'Sürüm $version kuruluyor · Sense Remote yeniden açılıyor';

  /// After a role change (A2c, prototype `splash(...)`).
  static const String splashRoleChange =
      'Rol uygulanıyor · Sense Remote yeni rolle açılıyor';
}
