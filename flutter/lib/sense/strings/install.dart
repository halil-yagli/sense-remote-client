// Sense Remote: texts of the setup wizard (YH K1–K7). Turkish only (T2, #59).
// Also used by the home screens (macOS permissions) and the sign-in (pairing code).

const Map<String, String> kSenseInstallTr = {
  // ---- Window and steps (K1) ----
  'window-title': 'Sense Remote Kurulum',
  'title-suffix': '· Kurulum',
  'close': 'Kapat',
  'version': 'Sürüm',
  'os-windows': 'Windows',
  'os-mac': 'macOS',
  'step-apps': 'Uygulamalar klasörü',
  'step-account': 'Sense hesabı',
  'step-role': 'Bu bilgisayarın rolü',
  'step-info': 'Bilgisayar bilgisi',
  'step-summary': 'Özet ve kurulum',
  'step-permissions': 'macOS izinleri',
  'step-done': 'Kuruldu',
  'step-upgrade': 'Güncelleme',
  'back': 'Geri',
  'next': 'Devam',
  'retry': 'Yeniden dene',

  // ---- Sense account (K2) ----
  'account-title-a': 'Sense',
  'account-title-b': ' hesabınla gir',
  'account-lead':
      'Kurulumu yalnız Sense Department çalışanı yapabilir. Bilgisayar senin hesabın üzerinden panele bağlanır.',
  'google-sign-in': 'Google ile giriş yap',
  'sign-in-note': 'Tarayıcıda açılır · iki adımlı doğrulama istenir',
  'domain-note': 'Yalnız @sensedepartment.com hesapları kabul edilir',
  'requesting': 'Panele bağlanılıyor…',
  'pairing-label': 'Eşleştirme kodu',
  'pairing-spoken': 'Eşleştirme kodu: ',
  'pairing-hint':
      'Tarayıcıdaki onay ekranında aynı kod görünmeli. Farklıysa onaylama.',
  'open-browser': 'Tarayıcıda onayla',
  'copy-link': 'Bağlantıyı kopyala',
  'link-copied': 'Kopyalandı',
  'cancel': 'Vazgeç',
  'waiting': 'Tarayıcıdaki onay bekleniyor · en çok 3 dakika',
  'verified': 'doğrulandı · iki adımlı',
  'other-account': 'Başka hesap',
  'login-timeout': 'Giriş süresi doldu (3 dakika)',
  'login-timeout-hint': 'Yeni kodla yeniden dene.',
  'new-code': 'Yeni kod al',
  'login-failed': 'Giriş tamamlanamadı',
  'login-failed-hint': 'Yeniden dene; sorun sürerse Sense ekibine bildir.',
  'login-domain': 'Bu hesap kabul edilmedi',
  'login-domain-hint':
      'Yalnız @sensedepartment.com hesapları kabul edilir. Şirket hesabınla yeniden gir.',

  // ---- Role (K3) ----
  'role-title-a': 'Bu bilgisayarın ',
  'role-title-b': 'rolü',
  'role-lead':
      'Birini ya da ikisini seç. Kurulumdan sonra uygulamanın içinden, Sense hesabıyla doğrulayarak eklenip kaldırılabilir.',
  'host': 'Host',
  'controller': 'Controller',
  'host-desc':
      'Ekip bu bilgisayara uzaktan bağlanabilir. Müze, mekân ve marka kurulumları için.',
  'controller-desc':
      'Bu bilgisayardan, hesabının yönettiği bilgisayarlara bağlanırsın. Ekip bilgisayarları için.',
  'role-none': 'Henüz seçim yok.',
  'role-sum-host':
      'Host — ekip bu bilgisayara bağlanabilir. Ayarlar kilitlenir, panelden yönetilir.',
  'role-sum-controller':
      'Controller — bu bilgisayardan hesabının yönettiği bilgisayarlara bağlanırsın.',
  'role-sum-both':
      'Host + Controller — ekip bu bilgisayara bağlanabilir, sen de buradan başka bilgisayarlara bağlanabilirsin.',
  'role-locked': 'Bilgisayar kuruldu; rol artık uygulamanın içinden değişir.',

  // ---- Computer details (K4) ----
  'info-title-a': 'Bilgisayar ',
  'info-title-b': 'bilgisi',
  'info-lead':
      'Bilgisayara yalnız ad verirsin. Proje ve yer panelde tanımlıdır; burada seçilir.',
  'name': 'Bilgisayar adı',
  'name-hint': 'Örn. Galeri kioskı',
  'projects-label': 'Proje · sana atanmış {n} proje',
  'projects-loading': 'Projeler okunuyor…',
  'projects-hint':
      'Birden fazla seçilebilir. Listede olmayan proje için panelde proje sahibinden seni üye yapmasını iste.',
  'projects-none': 'Hesabına atanmış proje yok',
  'projects-none-hint':
      'Kurulumu sürdürmek için panelde bir proje sahibi ya da yönetici seni bir projeye üye yapmalı. Üye yapılınca bu sayfa kendiliğinden güncellenir.',
  'projects-error': 'Proje listesi alınamadı',
  'projects-error-network':
      'Panele ulaşılamadı. İnternet bağlantısını kontrol et; liste kendiliğinden yeniden denenir.',
  'projects-error-token_invalid':
      'Giriş geçersiz ya da süresi doldu. Sense hesabınla yeniden gir.',
  'projects-error-retry': 'Panel şu anda yanıt veremedi; liste kendiliğinden yeniden denenir.',
  'projects-max': 'En çok 10 proje seçilebilir.',
  'relogin': 'Yeniden giriş yap',
  'location-label': 'Yer · panelde projeye tanımlı salon / bölüm',
  'location-first': 'Önce proje seç; o projenin yerleri burada çıkar.',
  'location-none': 'Bu projede yer tanımlı değil',
  'location-none-hint':
      'Panelde Projeler › {project} › Yerler\'den ekle; eklenince bu liste kendiliğinden güncellenir.',
  'note': 'Not · isteğe bağlı',
  'note-hint': 'Örn. 2 ekran, LED işlemciye bağlı',
  'info-missing': 'Ad, proje ve yer gerekli',

  // ---- Summary and install (K5) ----
  'summary-title': 'Özet',
  'summary-lead':
      'Kurulumdan sonra ayarlar bu bilgisayarda kilitlenir; değişiklik panelden yapılır.',
  'summary-lead-controller':
      'Kurulumdan sonra bu bilgisayardan başka bilgisayarlara bağlanabilirsin.',
  'sum-account': 'Hesap',
  'sum-role': 'Rol',
  'sum-computer': 'Bilgisayar',
  'sum-projects': 'Projeler',
  'sum-location': 'Yer',
  'sum-update': 'Güncelleme',
  'sum-update-value': 'Otomatik · panelden',
  'sum-password': 'Erişim şifresi',
  'sum-password-value': 'Kurulumdan sonra; şifre yöneticisinde',
  'none': '—',
  'advanced': 'Gelişmiş',
  'advanced-start-menu': 'Başlat menüsü',
  'advanced-desktop': 'masaüstü',
  'advanced-printer': 'yazıcı',
  'install-path': 'Kurulum klasörü',
  'change-path': 'Değiştir',
  'path-not-empty': 'Seçilen klasör boş değil',
  'path-not-empty-hint':
      '{path} — kurulum içindeki dosyaları silebilir. Boş bir klasör seç.',
  'start-menu': 'Başlat menüsüne ekle',
  'desktop-icon': 'Masaüstüne kısayol',
  'printer': 'Sense Remote yazıcısı',
  'install-note': 'Kurulumda Windows yönetici onayı sorulur',
  'install-note-mac': 'Kurulumda yönetici parolası sorulur',
  'install': 'Kur',
  'register-save': 'Panele kaydet',
  'installing': 'Kuruluyor… Windows yönetici onayı isteyecek.',
  'installing-mac': 'Kuruluyor… macOS yönetici parolasını isteyecek.',
  'registering': 'Bilgisayar panele kaydediliyor…',
  'error-cancelled': 'Yönetici onayı verilmedi; kurulum yapılmadı',
  'error-cancelled-hint': 'Yeniden dene ve açılan pencerede onay ver.',
  'error-cancelled-hint-mac': 'Yeniden dene ve yönetici parolasını gir.',
  'error-failed': 'Kurulum tamamlanamadı',
  'error-failed-hint': 'Yeniden dene; sorun sürerse Sense ekibine bildir.',
  // Install codes of src/sense (shown under "Kurulum tamamlanamadı").
  'error-not-in-applications':
      'Sense Remote Uygulamalar klasöründen çalışmıyor. Uygulamayı Uygulamalar klasörüne sürükle, oradan yeniden aç.',
  'error-daemon-timeout':
      'Arka plan hizmeti başlatılamadı. Kurulumu yeniden dene; sorun sürerse Sense ekibine bildir.',
  'error-not-signed-in': 'Önce Sense hesabınla giriş yap.',
  'error-invalid-name': 'Bilgisayar adı boş ya da çok uzun.',
  'error-invalid-location': 'Yer adı çok uzun.',
  'error-invalid-note': 'Not çok uzun.',
  'error-invalid-project': 'Proje seçimi geçersiz.',
  'error-info-too-long': 'Bilgiler çok uzun; adı kısalt.',
  'register-failed': 'Kurulum tamamlandı, panele kayıt yapılamadı',
  'skip-register': 'Kaydı atla',
  'edit-details': 'Bilgileri düzenle',
  'seconds-short': 'sn',
  // Panel `EnrollErrorCode` and the local checks of src/sense/enroll.rs.
  'enroll-token_invalid':
      'Giriş geçersiz ya da süresi doldu. Yeniden giriş yapıp kaydı tamamla.',
  'enroll-install_scope':
      'Giriş 30 dakikadan eski. Yeniden giriş yapıp kaydı tamamla.',
  'enroll-device_mismatch':
      'Giriş bu bilgisayarın kimliğiyle yapılmamış. Yeniden giriş yapıp kaydı tamamla.',
  'enroll-permission_denied':
      'Hesabında "Bilgisayar kurma" yetkisi kapalı. Panelde yöneticiden bu yetkiyi iste, sonra yeniden dene.',
  'enroll-validation':
      'Panel bilgileri kabul etmedi. Adı ve notu düzeltip yeniden kaydet.',
  'enroll-project_not_found':
      'Seçilen projelerden biri artık yok ya da üyeliğin kaldırılmış. Projeleri yeniden seç.',
  'enroll-location_not_found':
      'Seçilen yer artık projede tanımlı değil. Yeri yeniden seç.',
  'enroll-uuid_mismatch':
      'Bu kimlikle başka bir bilgisayar kayıtlı; panelde uyarı oluştu. Kaydı atla ve yöneticiye haber ver.',
  'enroll-rate_limited': 'Çok fazla deneme. 1 dakika bekleyip yeniden dene.',
  'enroll-retry': 'Panel şu anda yanıt veremedi. Yeniden dene.',
  'enroll-network':
      'Panele ulaşılamadı. İnternet bağlantısını kontrol edip yeniden dene.',
  'enroll-other': 'Kayıt yapılamadı. Yeniden dene.',
  'enroll-invalid-name': 'Bilgisayar adı geçersiz. Adı düzeltip yeniden kaydet.',
  'enroll-invalid-location': 'Yer geçersiz. Yeri yeniden seçip kaydet.',
  'enroll-invalid-note': 'Not çok uzun ya da geçersiz. Notu düzeltip yeniden kaydet.',
  'enroll-invalid-project': 'Proje seçimi geçersiz. Projeleri yeniden seç.',
  'enroll-not-installed':
      'Kurulum tamamlanmamış görünüyor. Kaydı atla ve Sense ekibine bildir.',
  'enroll-build':
      'Bu kurulum dosyası eksik derlenmiş. Kaydı atla ve Sense ekibine bildir.',
  'enroll-identity':
      'Bu bilgisayarın kimliği okunamadı. Kaydı atla ve Sense ekibine bildir.',
  'enroll-identity-store':
      'Bu bilgisayarın kimliği kaydedilemedi. Kaydı atla ve Sense ekibine bildir.',

  // ---- macOS (K1, K6) ----
  'apps-title-a': 'Uygulamalar',
  'apps-title-b': ' klasörüne taşı',
  'apps-lead':
      'Sense Remote\'u Uygulamalar klasörüne sürükle ve oradan aç. Kurulum, indirilen disk görüntüsünün içinden yapılamaz.',
  'apps-outside': 'Uygulama şu an disk görüntüsünün içinden çalışıyor',
  'apps-outside-hint':
      'Bu pencereyi kapat, Sense Remote\'u Uygulamalar klasörüne sürükle, oradan yeniden aç.',
  'apps-checking': 'Uygulamanın yeri denetleniyor…',
  'apps-recheck': 'Yeniden denetle',
  'perm-title-a': 'macOS ',
  'perm-title-b': 'izinleri',
  'perm-lead':
      'macOS bu izinleri yalnız bilgisayarın başında, bir kez onaylatır. Sırayla aç; durum burada kendiliğinden güncellenir.',
  'perm-lead-one':
      'macOS bu izni yalnız bilgisayarın başında, bir kez onaylatır. Durum burada kendiliğinden güncellenir.',
  'perm-screen': 'Ekran Kaydı',
  'perm-screen-desc': 'Ekip bu bilgisayarın ekranını görebilsin.',
  'perm-accessibility': 'Erişilebilirlik',
  'perm-accessibility-desc': 'Ekip faresini ve klavyesini kullanabilsin.',
  'perm-input': 'Giriş İzleme',
  'perm-input-desc': 'Klavye kısayolları bağlantıda doğru iletilsin.',
  'perm-granted': 'Verildi',
  'perm-missing': 'Bekleniyor',
  'perm-reading': 'Durum okunuyor…',
  'perm-open': 'Sistem Ayarları\'nı aç',
  'perm-hint':
      'Açılan listede Sense Remote\'un anahtarını aç. Listede yoksa + ile Uygulamalar klasöründen ekle.',
  'perm-later': 'Daha sonra',
  'perm-later-confirm': 'Yine de devam et',
  'perm-later-warning':
      'İzinler olmadan ekip bu bilgisayarın ekranını göremez ya da kullanamaz',
  'perm-later-warning-hint':
      'Panelde izin eksik görünür. İzinler daha sonra yine bu bilgisayarın başında verilmek zorunda.',
  'perm-later-warning-controller':
      'Giriş İzleme olmadan bazı klavye kısayolları karşı bilgisayara iletilmez',
  'perm-later-warning-controller-hint':
      'İzin daha sonra Sistem Ayarları › Gizlilik ve Güvenlik bölümünden verilebilir.',
  'perm-agent-failed':
      'Ekran Kaydı izni verildi ama arka plan hizmeti yeniden başlatılamadı. Görüntü gelmezse bilgisayarı yeniden başlat.',

  // ---- Done (K7) ----
  'done-title': 'Kuruldu',
  'done-lead': 'Sense Remote bu bilgisayara kuruldu.',
  'done-panel': 'Bilgisayar panelde etkin: {projects} · {location}.',
  'done-panel-skipped': 'Panele kayıt yapılmadı; Sense ekibine bildir.',
  'done-locked': 'Ayarlar kilitlendi; değişiklikler panelden yapılır.',
  'done-host':
      'Sense Remote arka planda çalışıyor; bağlantı sırasında ekranın sağ altında Sense simgesi görünür.',
  'done-permissions-missing':
      'macOS izinleri eksik: Sistem Ayarları › Gizlilik ve Güvenlik bölümünden verilmeden bağlantı tam çalışmaz.',
  'open-app': 'Sense Remote\'u aç',

  // ---- Move from an older version (K7) ----
  'upgrade-title-a': 'Sense Remote ',
  'upgrade-title-b': 'güncellemesi',
  'upgrade-lead':
      'Bu bilgisayarda Sense Remote Sürüm {from} kurulu. Sürüm {to} kurulacak; hesap, rol, projeler ve bağlantı kimliği korunur.',
  'upgrade-installed': 'Kurulu',
  'upgrade-target': 'Kurulacak',
  'upgrade-version': 'Sürüm {n}',
  'upgrade-login': 'Giriş / yeniden kayıt',
  'upgrade-login-value': 'gerekmez',
  'upgrade-note':
      'Windows yönetici onayı ister. Güncelleme sırasında bağlantı kısa süre kopar.',
  'upgrade-note-mac':
      'Yönetici parolasıyla geçiş tamamlanır; ardından macOS izinleri yeniden onaylanır.',
  'upgrade-start': 'Güncelle',
  'upgrade-mac-start': 'Geçişi tamamla',
  'upgrade-running': 'Güncelleme başlatılıyor…',
  'upgrade-error': 'Güncelleme başlatılamadı',
  'upgrade-error-cancelled': 'Yönetici onayı verilmedi. Güncellemek için yeniden dene.',
  'upgrade-error-not_installed':
      'Bu bilgisayarda kurulu Sense Remote bulunamadı. Pencereyi kapatıp kurulum dosyasını yeniden aç.',
  'upgrade-error-failed':
      'Yeniden dene; sorun sürerse Sense ekibine bildir.',
  'upgrade-current-title-a': 'Sürüm {n}',
  'upgrade-current-title-b': ' kurulu',
  'upgrade-current-lead':
      'Bu bilgisayarda Sense Remote Sürüm {n} kurulu. Bu kurulum dosyası aynı ya da daha eski bir sürüm; bir şey değiştirilmedi.',
  'upgrade-done-title': 'Güncelleme başladı',
  'upgrade-done-lead':
      'Sense Remote birkaç dakika içinde Sürüm {to} ile yeniden başlar. Bu pencereyi kapatabilirsin.',
  'upgrade-done-title-mac': 'Geçiş tamamlandı',
  'upgrade-done-lead-mac': 'Sense Remote Sürüm {to} ile çalışıyor.',
};

/// Text of [key]; the key itself when it is missing (shows up in tests).
String senseInstallText(String key, [Map<String, String> args = const {}]) {
  var text = kSenseInstallTr[key] ?? key;
  args.forEach((name, value) => text = text.replaceAll('{$name}', value));
  return text;
}

/// "482913" → "482 913" (wave 3 K-GİRİŞ: easier to compare with the browser).
String formatSensePairingCode(String code) =>
    code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

/// Read digit by digit by screen readers.
String spokenSensePairingCode(String code) => code.split('').join(' ');
