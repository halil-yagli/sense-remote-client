// Sense Remote: texts of the update strip, the version chip and the About
// update line (update plan 2026-11-21, §6). The UI is Turkish for now; English
// is kept next to it, like the setup wizard (sense_install_strings.dart).
// Internal details (`error_detail`) are never shown here; the panel shows them.

const Map<String, String> kSenseUpdateTr = {
  'version': 'Sürüm {n}',
  'version_tip': 'Hakkında',
  // Strip (§6 table).
  'available': 'Yeni sürüm hazır: Sürüm {n}',
  'session_active': 'Bağlantı sürüyor. Güncelleme bağlantı bitince kurulacak.',
  'scheduled_panel':
      'Sense ekibi bu bilgisayarı Sürüm {n}{dat} güncelliyor. Bağlantı yokken kendiliğinden kurulur.',
  'scheduled_local': 'Sürüm {n} kurulacak. Bağlantı yokken kendiliğinden kurulur.',
  'scheduled_night': 'Sürüm {n} bu gece 03:00–05:00 arasında kurulacak.',
  'downloading': 'Sürüm {n} indiriliyor…',
  'downloading_pct': 'Sürüm {n} indiriliyor… %{p}',
  'verifying': 'Sürüm {n} doğrulanıyor…',
  'installing':
      'Sürüm {n} kuruluyor. Sense Remote birkaç saniye kapanıp açılacak.',
  'installed': 'Sense Remote güncellendi: Sürüm {n}',
  'failed':
      'Güncelleme yapılamadı: {reason}. Bilgisayar Sürüm {cur} ile çalışmaya devam ediyor.',
  'rolled_back': 'Sürüm {n} kurulamadı; Sürüm {cur}{dat} geri dönüldü.',
  // Buttons.
  'update': 'Güncelle',
  'update_now': 'Şimdi güncelle',
  'notes': 'Neler yeni',
  'retry': 'Tekrar dene',
  'close': 'Kapat',
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
  'mac_title': 'İzinler yeniden istenebilir',
  'mac_body':
      'Güncellemeden sonra macOS, Ekran Kaydı, Erişilebilirlik ve Giriş İzleme izinlerini yeniden isteyebilir. Bilgisayarın başındaysan devam et.',
  // About (§6).
  'about_label': 'Güncelleme',
  'about_current': 'Güncel',
  'about_ready': 'Sürüm {n} hazır',
  'about_checked': 'Son denetim: {ago}',
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

const Map<String, String> kSenseUpdateEn = {
  'version': 'Version {n}',
  'version_tip': 'About',
  'available': 'New version ready: Version {n}',
  'session_active':
      'A connection is active. The update will install when it ends.',
  'scheduled_panel':
      'The Sense team is updating this computer to Version {n}. It installs by itself when no one is connected.',
  'scheduled_local':
      'Version {n} will install when no one is connected.',
  'scheduled_night': 'Version {n} will install tonight between 03:00 and 05:00.',
  'downloading': 'Downloading Version {n}…',
  'downloading_pct': 'Downloading Version {n}… {p}%',
  'verifying': 'Verifying Version {n}…',
  'installing':
      'Installing Version {n}. Sense Remote will close and reopen in a few seconds.',
  'installed': 'Sense Remote was updated: Version {n}',
  'failed':
      'The update failed: {reason}. This computer keeps running Version {cur}.',
  'rolled_back': 'Version {n} could not be installed; back to Version {cur}.',
  'update': 'Update',
  'update_now': 'Update now',
  'notes': "What's new",
  'retry': 'Try again',
  'close': 'Close',
  'cancel': 'Cancel',
  'install_no_release':
      'No version to install was found. It is checked again at the next check.',
  'install_not_newer': 'This computer is up to date.',
  'install_busy': 'An update is already running.',
  'install_ipc_failed':
      'The Sense Remote service did not answer. Try again in a moment.',
  'install_unsupported':
      'This computer can not be updated from the app; the Sense team updates it.',
  'install_other': 'The update could not be started.',
  'mac_title': 'Permissions may be asked again',
  'mac_body':
      'After the update, macOS may ask again for Screen Recording, Accessibility and Input Monitoring. Continue if you are at this computer.',
  'about_label': 'Update',
  'about_current': 'Up to date',
  'about_ready': 'Version {n} ready',
  'about_checked': 'Last check: {ago}',
  'ago_now': 'just now',
  'ago_min': '{n} min ago',
  'ago_hour': '{n} h ago',
  'ago_day': '{n} days ago',
  'err_manifest_invalid': 'the release could not be verified',
  'err_order_invalid': 'the update order could not be verified',
  'err_downgrade': 'an older version was refused',
  'err_download_failed': 'the download did not finish',
  'err_size_mismatch': 'the downloaded file could not be verified',
  'err_hash_mismatch': 'the downloaded file could not be verified',
  'err_disk_space': 'not enough free disk space',
  'err_install_failed': 'the installation did not finish',
  'err_version_mismatch': 'the installed version is not the expected one',
  'err_health_timeout': 'the new version did not start in time',
  'err_identity_changed': "the computer's identity changed",
  'err_rolled_back': 'went back to the previous version',
  'err_rollback_failed': 'could not go back to the previous version',
  'err_busy': 'another update is running',
  'err_unsupported': 'not supported on this computer',
  'err_unknown': 'an unknown problem',
};

/// Turkish first (the UI language for now), English when a key is missing.
String senseUpdateText(String key, [Map<String, String> args = const {}]) {
  var text = kSenseUpdateTr[key] ?? kSenseUpdateEn[key] ?? key;
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
