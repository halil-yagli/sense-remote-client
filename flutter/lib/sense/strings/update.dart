// Sense Remote: texts of the update strip, the version chip and the About
// update box (update plan 2026-11-21, §6; YH C4). Turkish only (YH T2, #59).
// Internal details (`error_detail`) are never shown here; the panel shows them.

const Map<String, String> kSenseUpdateTr = {
  'version': 'Sürüm {n}',
  'version_tip': 'Hakkında',
  // Strip (§6 table).
  'available': 'Yeni sürüm hazır: Sürüm {n}',
  'session_active': 'Bağlantı sürüyor; Sürüm {n} bağlantı bitince kurulacak.',
  'scheduled_panel':
      'Sense ekibi bu bilgisayarı Sürüm {n}{dat} güncelliyor. Bağlantı yokken kendiliğinden kurulur.',
  'scheduled_local': 'Sürüm {n} kurulacak. Bağlantı yokken kendiliğinden kurulur.',
  'scheduled_night': 'Sürüm {n} bu gece 03:00–05:00 arasında kurulacak.',
  'downloading': 'Sürüm {n} indiriliyor…',
  'downloading_pct': 'Sürüm {n} indiriliyor · %{p}',
  'verifying': 'Sürüm {n} doğrulanıyor (imza + SHA-256)…',
  'installing':
      'Sürüm {n} kuruluyor. Sense Remote birkaç saniye kapanıp açılacak.',
  'installed': 'Güncellendi: Sürüm {n}',
  'failed':
      'Güncelleme yapılamadı: {reason}. Sürüm {cur} ile çalışmaya devam ediliyor.',
  'rolled_back': 'Sürüm {n} kurulamadı; Sürüm {cur}{dat} geri dönüldü.',
  // Buttons.
  'update': 'Güncelle',
  'update_now': 'Şimdi güncelle',
  'notes': 'Neler yeni',
  'retry': 'Tekrar dene',
  'close': 'Tamam',
  'cancel': 'Vazgeç',
  // Answer of `main_sense_update_install` (§3.7); "" is accepted.
  'install_no_release':
      'Kurulacak sürüm bulunamadı. Bir sonraki denetimde yeniden bakılır.',
  'install_not_newer': 'Bu bilgisayar zaten güncel.',
  'install_busy': 'Güncelleme zaten sürüyor.',
  'install_ipc_failed':
      'Sense Remote servisine ulaşılamadı. Biraz sonra yeniden dene.',
  'install_unsupported':
      'Bu bilgisayar uygulamadan güncellenemiyor; güncellemeyi Sense ekibi yapar.',
  'install_other': 'Güncelleme başlatılamadı.',
  // macOS Host warning (§6, §7).
  // In-place second step of the strip (YH C4, T7): no separate window.
  'mac_body':
      'macOS güncellemeden sonra Ekran Kaydı, Erişilebilirlik ve Giriş İzleme izinlerini yeniden isteyebilir. Bilgisayarın başındaysan devam et.',
  'mac_go': 'Yine de güncelle',
  'mac_short': 'macOS izinleri yeniden isteyebilir; başındaysan devam et.',
  // About (§6).
  'about_label': 'Güncelleme',
  'about_current': 'Güncel',
  'about_ready': 'Sürüm {n} hazır',
  'about_checked': 'Son denetim: {ago}',
  // About box (YH C4; prototype `aboutView2`).
  'box_ready': 'Yeni sürüm hazır: Sürüm {n}',
  'box_ready_body_controller': 'Güncelleme imzalı ve doğrulanmış; onayınla kurulur.',
  'box_ready_body_host': 'Güncelleme imzalı ve doğrulanmış; bağlantı yokken kendiliğinden kurulur.',
  'box_checked': 'Son denetim {ago} · panelden otomatik',
  'box_not_checked': 'Henüz denetlenmedi · panelden otomatik',
  'check': 'Denetle',
  'checked_current': 'Sense Remote güncel',
  'ago_now': 'az önce',
  'ago_min': '{n} dk önce',
  'ago_hour': '{n} sa önce',
  'ago_day': '{n} gün önce',
  // Error reasons (`SenseUpdateError`, §3.5), short and without internals.
  'err_manifest_invalid': 'sürüm bilgisi doğrulanamadı',
  'err_order_invalid': 'güncelleme emri doğrulanamadı',
  'err_downgrade': 'daha eski bir sürüm reddedildi',
  'err_download_failed': 'indirme tamamlanamadı',
  'err_size_mismatch': 'indirilen dosya doğrulanamadı',
  'err_hash_mismatch': 'indirilen dosya doğrulanamadı',
  'err_disk_space': 'diskte yeterli boş alan yok',
  'err_install_failed': 'kurulum tamamlanamadı',
  'err_version_mismatch': 'kurulan sürüm beklenen sürüm değil',
  'err_health_timeout': 'yeni sürüm zamanında açılmadı',
  'err_identity_changed': 'bilgisayarın kimliği değişti',
  'err_rolled_back': 'önceki sürüme dönüldü',
  'err_rollback_failed': 'önceki sürüme dönülemedi',
  'err_busy': 'başka bir güncelleme sürüyor',
  'err_unsupported': 'bu bilgisayarda desteklenmiyor',
  'err_unknown': 'bilinmeyen bir sorun',
};

/// Text for [key] with its `{arg}` places filled.
String senseUpdateText(String key, [Map<String, String> args = const {}]) {
  var text = kSenseUpdateTr[key] ?? key;
  args.forEach((k, v) => text = text.replaceAll('{$k}', v));
  return text;
}

/// Turkish dative suffix after a number, with the apostrophe: "Sürüm 3'e",
/// "Sürüm 6'ya", "Sürüm 10'a". It follows how the last spoken word of the
/// number ends (vowel harmony; buffer -y- after a vowel).
String senseTurkishDative(int n) {
  const ones = ["'a", "'e", "'ye", "'e", "'e", "'e", "'ya", "'ye", "'e", "'a"];
  //            sıfır bir  iki   üç   dört beş  altı  yedi  sekiz dokuz
  const tens = ['', "'a", "'ye", "'a", "'a", "'ye", "'a", "'e", "'e", "'a"];
  //               on   yirmi otuz kırk elli  altmış yetmiş seksen doksan
  final v = n.abs();
  if (v == 0) return ones[0];
  if (v % 10 != 0) return ones[v % 10];
  if (v % 100 != 0) return tens[(v ~/ 10) % 10];
  return "'e"; // yüz, bin
}

/// Short reason of a `SenseUpdateError`; unknown names get a generic text.
String senseUpdateReason(String? error) {
  final key = 'err_$error';
  return error != null && kSenseUpdateTr.containsKey(key)
      ? senseUpdateText(key)
      : senseUpdateText('err_unknown');
}

/// Text for the answer of `main_sense_update_install`; null when accepted.
String? senseInstallAnswerText(String answer) {
  if (answer.isEmpty) return null;
  final key = 'install_$answer';
  return kSenseUpdateTr.containsKey(key)
      ? senseUpdateText(key)
      : senseUpdateText('install_other');
}

/// "Son denetim" age, from Unix seconds.
String senseAgoText(int checkedAt, int nowSeconds) {
  final s = nowSeconds - checkedAt;
  if (s < 60) return senseUpdateText('ago_now');
  if (s < 3600) return senseUpdateText('ago_min', {'n': '${s ~/ 60}'});
  if (s < 86400) return senseUpdateText('ago_hour', {'n': '${s ~/ 3600}'});
  return senseUpdateText('ago_day', {'n': '${s ~/ 86400}'});
}
