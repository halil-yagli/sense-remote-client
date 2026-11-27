// Sense Remote: texts and small pure helpers of the Sense home screens
// (Controller home, Host home, About). Prototype: Calisma/prototip/uygulama.html,
// screens 2, 3 and 7. The UI is Turkish for now; role names stay English
// (Host / Controller / Host + Controller, decision 2026-11-16).

const Map<String, String> kSenseHomeTr = {
  'brand_bold': 'Sense',
  'brand_light': ' Remote',
  // Controller home
  'computers': 'Bilgisayarlarım',
  'search_hint': 'Proje, bilgisayar, konum ya da kimlik',
  'connect': 'Bağlan',
  'offline': 'Kapalı',
  'offline_tip': 'Kapalı görünüyor — yine de bağlanmayı dener',
  'connect_id': 'Kimlikle bağlan',
  'connect_id_hint': 'Kimlik — örn. 123 456 789',
  'connect_id_note':
      'Sense kurulu olmayan bir bilgisayar için. Şifre bağlantı penceresinde sorulur.',
  'cancel': 'Vazgeç',
  'refresh': 'Yenile',
  'loading': 'Bilgisayarlar yükleniyor…',
  'empty':
      'Hesabına atanmış bilgisayar yok. Projeler panelden yönetilir. Sense kurulu olmayan bir bilgisayar için “Kimlikle bağlan”.',
  'no_match': 'Aramaya uyan bilgisayar yok.',
  'load_error': 'Liste panelden alınamadı.',
  'no_project': 'Projesi olmayan',
  'screen_count': '{n} ekran',
  // Host home
  'this_computer': 'Bu bilgisayar',
  'ready': 'Hazır — Sense ekibi bağlanabilir',
  'connecting': 'Bağlantı sunucusuna bağlanıyor…',
  'not_ready': 'Hazır değil — bağlantı sunucusuna ulaşılamıyor',
  'service_stopped': 'Hazır değil — servis çalışmıyor',
  'start_service': 'Servisi başlat',
  'device_id': 'Kimlik',
  'locked_note':
      'Ayarlar bu bilgisayarda kilitli; Sense panelinden yönetilir. Erişim şifresi ekibin şifre yöneticisinde.',
  // macOS privacy permissions (Host status line, Controller card); the
  // permission names and the button text are the setup wizard's (perm-*).
  'mac_perm_missing_one': '{name} izni yok',
  'mac_perm_missing_many': '{names} izinleri yok',
  'mac_perm_and': ' ve ',
  'mac_not_ready': 'Hazır değil — {missing}',
  'mac_perm_note_host':
      'İzin verilmeden ekip bu bilgisayarı göremez ya da kullanamaz. İzin yalnızca bilgisayarın başında verilir.',
  'mac_perm_note_input':
      'Bu izin olmadan bazı klavye kısayolları bağlantıda iletilmez.',
  // About
  'about': 'Hakkında',
  'version': 'Sürüm {n}',
  'role': 'Bu bilgisayar',
  'panel': 'Panel',
  'panel_signed_in': 'Bağlı · {name}',
  'panel_managed': 'Panelden yönetilir',
  'panel_signed_out': 'Giriş yapılmadı',
  'role_none': 'Belirlenmedi',
  'copyright': '© {year} Sense Department',
  'licenses': 'Açık kaynak lisansları',
  'licenses_title': 'Açık kaynak lisansları',
  'licenses_body':
      'Sense Remote, GNU Affero Genel Kamu Lisansı sürüm 3 (AGPL-3.0) ile lisanslanan açık kaynak yazılım üzerine kuruludur. Değiştirilmiş kaynak kodun tamamı aşağıdaki depoda herkese açıktır.',
  'licenses_source': 'Kaynak kod',
  'licenses_text': 'Lisans metni',
  'licenses_base': 'Taban sürüm: {v}',
  'close': 'Kapat',
};

String senseHomeText(String key, [Map<String, String> args = const {}]) {
  var text = kSenseHomeTr[key] ?? key;
  args.forEach((k, v) => text = text.replaceAll('{$k}', v));
  return text;
}

/// Public source repository of this client (AGPL: the modified source must be
/// reachable from the app). No secret, no internal address.
const kSenseSourceUrl = 'https://github.com/halil-yagli/sense-remote-client';
const kSenseLicenseUrl = '$kSenseSourceUrl/blob/master/LICENCE';

/// Role of this computer as the home screen sees it.
enum SenseHomeRole { none, host, controller, both }

/// Pure: the installed role is applied as hard settings at start
/// (`src/sense.rs` role_settings): Host = incoming only + locked settings,
/// Controller = outgoing only, Host + Controller = locked settings only.
/// No role (portable run, not installed) keeps the stock screens.
SenseHomeRole senseHomeRoleFrom(
    {required bool incomingOnly,
    required bool outgoingOnly,
    required bool settingsDisabled}) {
  if (incomingOnly) return SenseHomeRole.host;
  if (outgoingOnly) return SenseHomeRole.controller;
  if (settingsDisabled) return SenseHomeRole.both;
  return SenseHomeRole.none;
}

String senseRoleLabel(SenseHomeRole role) {
  switch (role) {
    case SenseHomeRole.host:
      return 'Host';
    case SenseHomeRole.controller:
      return 'Controller';
    case SenseHomeRole.both:
      return 'Host + Controller';
    case SenseHomeRole.none:
      return senseHomeText('role_none');
  }
}

/// Sense version number (plain number, decision 2026-11-16). Null when the
/// build did not provide one; then no version line is shown (no made-up value).
int? senseVersionFrom(String raw) {
  final n = int.tryParse(raw.trim());
  return n != null && n > 0 ? n : null;
}

/// Build-time fallback: `--dart-define=SENSE_VERSION=<n>`.
const kSenseVersionDefine = String.fromEnvironment('SENSE_VERSION');

/// Turkish upper case for small caps labels (i -> İ, ı -> I).
String senseHomeUpper(String s) =>
    s.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();

/// Built-in option the build may carry with the Sense version number (moved
/// here from the old About file, B3).
const kSenseVersionOption = 'sense-version';
