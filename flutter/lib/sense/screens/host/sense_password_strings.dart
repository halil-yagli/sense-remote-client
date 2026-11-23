// Sense Remote: texts of the permanent password (plan 2026-11-21, §4, package U13).
// Turkish only; error codes of the native side map to short texts, internals
// are never shown.

const Map<String, String> kSensePasswordTr = {
  'title': 'Kalıcı şifre',
  'security': 'Güvenlik',
  'open': 'Aç',
  // About row and the Host home line.
  'summary_set': 'Ayarlı',
  'summary_set_at': 'Ayarlı · {date}',
  'summary_none': 'Ayarlı değil',
  'summary_unknown': 'Kilitli',
  'summary_controller': 'Bu bilgisayarda gerekmez',
  'summary_unsupported': 'Bu sürümde henüz açık değil',
  'host_set': 'Kalıcı şifre: ayarlı',
  'host_none': 'Kalıcı şifre: yok',
  'host_unknown': 'Kalıcı şifre',
  // States (§4 table).
  'locked_set': 'Kalıcı şifre ayarlı · son değişiklik {date}',
  'locked_set_nodate': 'Kalıcı şifre ayarlı.',
  'locked_hint': 'Değiştirmek için Sense hesabınla doğrula.',
  'locked_none':
      'Kalıcı şifre yok. Başında kimse yokken bağlanmak için kalıcı şifre belirle.',
  'locked_unknown':
      'Kalıcı şifreyi belirlemek ya da değiştirmek için Sense hesabınla doğrula.',
  'unlock': 'Kilidi aç',
  'requesting': 'Doğrulama hazırlanıyor…',
  'pairing_label': 'EŞLEŞTİRME KODU',
  'pairing_spoken': 'Eşleştirme kodu: ',
  'qr_label': 'Doğrulama bağlantısının karekodu',
  'verifying_hint':
      'Telefonunla ya da kendi bilgisayarınla okut; Sense Google hesabınla giriş yap, kodu karşılaştır, onayla.',
  'verifying_wait': 'Onay bekleniyor (en çok 3 dakika).',
  'copy_link': 'Bağlantıyı kopyala',
  'link_copied': 'Bağlantı kopyalandı.',
  'open_here': 'Bu bilgisayarda aç',
  'open_here_note': 'Müşteri bilgisayarında Google oturumu açık bırakma.',
  'open_browser': 'Tarayıcıda aç',
  'cancel': 'Vazgeç',
  'unlocked': 'Doğrulandı: {name} · {time} içinde kilitlenir',
  'new_password': 'Yeni şifre',
  'repeat_password': 'Yeniden yaz',
  'rules':
      '12–64 karakter; boşluk ve Türkçe karakter yok (İngilizce harf, rakam, işaret). Tek karakter tekrarı, 1234… gibi dizi ve bilgisayarın kimliği olmaz.',
  'save': 'Kaydet',
  'done':
      'Kalıcı şifre değiştirildi. Şifreyi şirket şifre yöneticisine kaydet; Sense Remote şifreyi bir daha göstermez. Süren bağlantılar kesilmedi.',
  'ok': 'Tamam',
  'expired': 'Süre doldu. Yeniden doğrula.',
  'controller':
      'Bu bilgisayar yalnız bağlanır; kalıcı şifre gerekmez. Bağlandığın bilgisayarın şifresi, o bilgisayardaki Sense Remote\'ta değiştirilir (bağlıyken de olur).',
  'unsupported': 'Bu özellik bu sürümde henüz açık değil.',
  // Errors (begin, login, unlock, set).
  'err_mismatch': 'İki şifre aynı değil.',
  'err_token_invalid': 'Giriş geçersiz, yeniden doğrula.',
  'err_password_scope': 'Giriş geçersiz, yeniden doğrula.',
  'err_replayed': 'Giriş geçersiz, yeniden doğrula.',
  'err_device_mismatch': 'Bu giriş bu bilgisayar için değil, yeniden doğrula.',
  'err_device_not_eligible': 'Bu bilgisayar panelde etkin değil.',
  'err_bad_request_signature': 'Doğrulama isteği kabul edilmedi, yeniden doğrula.',
  'err_validation': 'Doğrulama isteği kabul edilmedi, yeniden doğrula.',
  'err_request_expired': 'Doğrulamanın süresi doldu, yeniden doğrula.',
  'err_rate_limited': 'Çok fazla deneme. 1 saat içinde yeniden dene.',
  'err_signing_unavailable': 'Panel şu an izin veremiyor. Biraz sonra yeniden dene.',
  'err_network': 'Panele ulaşılamadı. Ağ bağlantısını denetleyip yeniden dene.',
  'err_panel_outdated': 'Panel bu özelliği henüz desteklemiyor.',
  'err_not_incoming': 'Bu bilgisayar yalnız bağlanır; kalıcı şifre gerekmez.',
  'err_unsupported': 'Bu özellik bu sürümde henüz açık değil.',
  'err_busy': 'Başka bir işlem sürüyor. Biraz sonra yeniden dene.',
  'err_ipc_failed': 'Sense Remote servisine ulaşılamadı. Biraz sonra yeniden dene.',
  'err_no_pending': 'Doğrulamanın süresi doldu, yeniden doğrula.',
  'err_grant_invalid': 'İzin doğrulanamadı, yeniden doğrula.',
  'err_nonce_mismatch': 'İzin doğrulanamadı, yeniden doğrula.',
  'err_write_failed': 'Şifre kaydedilemedi. Yeniden dene.',
  'err_login_timeout': 'Onay zamanında gelmedi. Yeniden doğrula.',
  'err_login_failed': 'Giriş tamamlanamadı. Yeniden dene.',
  'err_other': 'İşlem tamamlanamadı. Yeniden dene.',
  // Password rule (§3.8), shown for `weak_password:<rule>` and the check hint.
  'rule_length': 'Şifre 12–64 karakter olmalı.',
  'rule_charset':
      'Yalnız İngilizce harf, rakam ve işaret; boşluk ve Türkçe karakter olmaz.',
  'rule_repeated': 'Tek karakter tekrarı ya da 1234… gibi dizi olmaz.',
  'rule_contains_id': 'Şifre bilgisayarın kimliğini içermemeli.',
  'rule_common': 'Bu şifre çok yaygın; başka bir şifre seç.',
  'rule_other': 'Bu şifre kurala uymuyor; başka bir şifre seç.',
};

/// Turkish only (the app UI is Turkish only); a missing key returns the key.
String sensePasswordText(String key, [Map<String, String> args = const {}]) {
  var text = kSensePasswordTr[key] ?? key;
  args.forEach((k, v) => text = text.replaceAll('{$k}', v));
  return text;
}

/// Text of a rule code (`length`, `charset`, …) of `main_sense_password_check`
/// or of `weak_password:<rule>`.
String sensePasswordRuleText(String rule) {
  final key = 'rule_$rule';
  return kSensePasswordTr.containsKey(key)
      ? sensePasswordText(key)
      : sensePasswordText('rule_other');
}

/// Text of an error code of begin / unlock / set / sign-in. Codes with a
/// detail (`grant_invalid:<reason>`, `weak_password:<rule>`) show no detail
/// except the rule; unknown codes get a generic text.
String sensePasswordErrorText(String code) {
  final i = code.indexOf(':');
  final head = i < 0 ? code : code.substring(0, i);
  if (head == 'weak_password') {
    return sensePasswordRuleText(i < 0 ? '' : code.substring(i + 1));
  }
  final key = 'err_$head';
  return kSensePasswordTr.containsKey(key)
      ? sensePasswordText(key)
      : sensePasswordText('err_other');
}

/// "21.11.2026 14:05" (local time is the caller's business).
String senseShortDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Countdown "4:59"; never below zero.
String senseCountdown(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
