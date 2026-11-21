// Sense Remote: texts of the Sense setup screen. The UI is Turkish for now; English is kept
// next to it so a language switch later is a one-line change.

const Map<String, String> kSenseInstallTr = {
  'window-title': 'Sense Remote Kurulum',
  'close': 'Kapat',
  'version': 'Sürüm',
  'step-account': 'Sense hesabı',
  'step-role': 'Bu bilgisayarın rolü',
  'step-info': 'Bilgisayar bilgisi',
  'step-summary': 'Özet ve kurulum',
  // Step 1: Sense sign-in (wave 3 K-GİRİŞ).
  'account-title-a': 'Sense',
  'account-title-b': ' hesabınla gir',
  'account-lead':
      'Kurulumu yalnızca Sense Department çalışanı yapabilir. Bilgisayar senin hesabın üzerinden panele bağlanır.',
  'google-sign-in': 'Google ile giriş yap',
  'sign-in-note': 'tarayıcıda açılır · iki adımlı doğrulama istenir',
  'domain-hint': '@sensedepartment.com dışındaki hesaplar kabul edilmez',
  'requesting': 'Panele bağlanılıyor…',
  'pairing-label': 'Eşleştirme kodu',
  'pairing-spoken': 'Eşleştirme kodu: ',
  'pairing-hint':
      'Tarayıcıdaki onay ekranında aynı kod görünmeli. Farklıysa onaylama.',
  'open-browser': 'Tarayıcıda onayla',
  'copy-link': 'Bağlantıyı kopyala',
  'link-copied': 'Bağlantı kopyalandı.',
  'waiting': 'Tarayıcıdaki onay bekleniyor (en çok 3 dakika).',
  'cancel': 'Vazgeç',
  'verified': 'doğrulandı',
  'other-account': 'Başka hesapla gir',
  'login-timeout': 'Giriş süresi doldu (3 dakika). Yeni kodla yeniden dene.',
  'login-failed': 'Giriş tamamlanamadı.',
  'new-code': 'Yeni kod al',
  'retry': 'Yeniden dene',
  'role-title-a': 'Bu bilgisayarın ',
  'role-title-b': 'rolü',
  'role-lead':
      'Birini ya da ikisini birden seç. Kurulumdan sonra yalnızca panelden değiştirilebilir.',
  'host-desc':
      'Ekip bu bilgisayara uzaktan bağlanabilir. Müze, mekân ve marka kurulumları için.',
  'controller-desc':
      'Bu bilgisayardan, hesabının yönettiği bilgisayarlara bağlanırsın. Ekip bilgisayarları için.',
  'no-role': 'Henüz seçim yok.',
  'both-desc':
      ' — ekip bu bilgisayara bağlanabilir, sen de buradan başka bilgisayarlara bağlanabilirsin.',
  'info-title-a': 'Bilgisayar ',
  'info-title-b': 'bilgisi',
  'info-lead':
      'Bilgisayar seçtiğin projelerin sayfasına eklenir; panelde bu bilgilerle görünür.',
  'name': 'Bilgisayar adı',
  'name-hint': 'Örn. Galeri kioskı',
  'projects': 'Projeler',
  'projects-multi': '(birden fazla seçilebilir)',
  'projects-loading': 'Projeler yükleniyor…',
  'projects-empty': 'Henüz proje yok; aşağıya yeni proje adı yaz.',
  'projects-error': 'Proje listesi alınamadı.',
  'projects-error-token_invalid': 'Proje listesi alınamadı: giriş geçersiz.',
  'projects-error-network': 'Proje listesi alınamadı: panele ulaşılamadı.',
  'projects-max': 'En çok 10 proje seçilebilir.',
  'project-hint': 'Yeni proje adı yaz, Enter',
  'add-project': 'Yeni projeyi ekle',
  'remove-project': 'Projeyi kaldır',
  'new-tag': 'yeni',
  'location': 'Konum',
  'location-hint': 'Örn. Galeri 1',
  'note': 'Not (isteğe bağlı)',
  'note-hint': 'Örn. 2 ekran, LED işlemciye bağlı',
  'summary-title': 'Özet',
  'summary-lead':
      'Kurulumdan sonra ayarlar bu bilgisayarda kilitlenir; değişiklik panelden yapılır.',
  'summary-lead-controller':
      'Kurulumdan sonra bu bilgisayardan başka bilgisayarlara bağlanabilirsin.',
  'account': 'Hesap',
  'role': 'Rol',
  'update': 'Güncelleme',
  'update-value': 'Otomatik',
  'password': 'Erişim şifresi',
  'password-value': 'Şifre yöneticisinden, kurulumdan sonra',
  'none': '—',
  'advanced': 'Gelişmiş',
  'install-path': 'Kurulum klasörü',
  'change-path': 'Değiştir',
  'start-menu': 'Başlat menüsüne ekle',
  'desktop-icon': 'Masaüstüne kısayol ekle',
  'printer': 'Sense Remote yazıcısını kur',
  'back': 'Geri',
  'next': 'Devam',
  'install': 'Kur',
  'installing': 'Kuruluyor… Windows yönetici onayı isteyecek.',
  'error-cancelled': 'Yönetici onayı verilmedi; kurulum yapılmadı.',
  'error-failed': 'Kurulum tamamlanamadı.',
  'error-not-signed-in': 'Önce Sense hesabınla giriş yap.',
  'error-invalid-name': 'Bilgisayar adı boş ya da çok uzun.',
  'error-invalid-project':
      'Proje adlarından biri çok uzun ya da çok fazla proje var.',
  'error-invalid-location': 'Konum çok uzun.',
  'error-invalid-note': 'Not çok uzun.',
  'error-info-too-long': 'Bilgiler çok uzun; konumu kısalt.',
  // Registration (wave 3 K-KAYIT): the computer is already installed at this point.
  'register-title-a': 'Panele ',
  'register-title-b': 'kayıt',
  'registering': 'Bilgisayar panele kaydediliyor…',
  'register-failed': 'Kurulum tamamlandı, panele kayıt yapılamadı.',
  'skip-register': 'Kaydı atla',
  'relogin': 'Yeniden giriş yap',
  'edit-details': 'Bilgileri düzenle',
  'register-save': 'Panele kaydet',
  'seconds-short': 'sn',
  'enroll-token_invalid':
      'Giriş geçersiz ya da süresi doldu. Yeniden giriş yapıp kaydı tamamla.',
  'enroll-install_scope':
      'Giriş 30 dakikadan eski. Yeniden giriş yapıp kaydı tamamla.',
  'enroll-device_mismatch':
      'Giriş bu bilgisayarın kimliğiyle yapılmamış. Yeniden giriş yapıp kaydı tamamla.',
  'enroll-validation':
      'Panel bilgileri kabul etmedi. Ad, konum ve proje adlarını düzeltip yeniden kaydet.',
  'enroll-project_not_found':
      'Seçilen projelerden biri artık yok (arşivlenmiş olabilir). Projeleri yeniden seç.',
  'enroll-uuid_mismatch':
      'Bu kimlikle başka bir bilgisayar kayıtlı; panelde uyarı oluştu. Kaydı atla ve yöneticiye haber ver.',
  'enroll-rate_limited': 'Çok fazla deneme. 1 dakika bekleyip yeniden dene.',
  'enroll-retry': 'Panel şu anda yanıt veremedi. Yeniden dene.',
  'enroll-network':
      'Panele ulaşılamadı. İnternet bağlantısını kontrol edip yeniden dene.',
  'enroll-other': 'Kayıt yapılamadı. Yeniden dene.',
  // Sense Remote: local checks before the panel is asked (review K3-5).
  'enroll-invalid-name': 'Bilgisayar adı geçersiz. Adı düzeltip yeniden kaydet.',
  'enroll-invalid-location': 'Konum geçersiz. Konumu düzeltip yeniden kaydet.',
  'enroll-invalid-note': 'Not çok uzun ya da geçersiz. Notu düzeltip yeniden kaydet.',
  'enroll-invalid-project':
      'Proje seçimi geçersiz (en çok 10 proje, adlar kısa olmalı). Projeleri düzeltip yeniden kaydet.',
  'enroll-not-installed':
      'Kurulum tamamlanmamış görünüyor. Kaydı atla ve Sense ekibine bildir.',
  'enroll-build':
      'Bu kurulum dosyası eksik derlenmiş. Kaydı atla ve Sense ekibine bildir.',
  'enroll-identity':
      'Bu bilgisayarın kimliği okunamadı. Kaydı atla ve Sense ekibine bildir.',
  'enroll-identity-store':
      'Bu bilgisayarın kimliği kaydedilemedi. Kaydı atla ve Sense ekibine bildir.',
  // Sense Remote: panel codes of #31.
  'enroll-device_closed':
      'Bu bilgisayar panelde kapatılmış. Panel yöneticisine başvur.',
  'enroll-reinstall_not_allowed':
      'Bu bilgisayar panelde zaten kayıtlı. Yeniden kurmak için panelde bu bilgisayarın sayfasından "Yeniden kurulum izni" ver, sonra Yeniden dene.',
  'done-title': 'Kuruldu',
  'done-lead': 'Sense Remote bu bilgisayara kuruldu.',
  'done-lead-locked': 'Ayarlar kilitlendi; değişiklikler panelden yapılır.',
  // Sense Remote: a Host has no large window to open (decision: no large UI on the Host).
  'done-host-background':
      'Sense Remote arka planda çalışıyor; bağlantı sırasında ekranın sağ alt köşesinde küçük bir simge görünür.',
  'done-panel-project': 'Bilgisayar panelde {projects} sayfasında.',
  'done-panel-projects': 'Bilgisayar panelde {projects} sayfalarında.',
  'done-panel-none': 'Bilgisayar panelde etkin.',
  'done-pending':
      'Panele kayıt yapılmadı: bilgisayar panelde onay bekleyen olarak görünecek; bir Sense çalışanı onaylayabilir.',
  'open-app': 'Sense Remote\'u aç',
  // Sense Remote (Mac M3): macOS steps and install results (plan 2026-11-21 §3.2).
  'installing-mac': 'Kuruluyor… macOS yönetici parolasını isteyecek.',
  'error-not-in-applications':
      'Sense Remote Uygulamalar klasöründen çalışmıyor. Uygulamayı Uygulamalar klasörüne sürükle, oradan yeniden aç.',
  'error-daemon-timeout':
      'Arka plan hizmeti başlatılamadı. Kurulumu yeniden dene; sorun sürerse Sense ekibine bildir.',
  'apps-title-a': 'Uygulamalar',
  'apps-title-b': ' klasörüne taşı',
  'apps-lead': 'Sense Remote\'u Uygulamalar klasörüne sürükle ve oradan aç.',
  'apps-detail':
      'Kurulum, uygulama indirilen disk görüntüsünün içinden çalışırken yapılamaz. Bu pencereyi kapat, Sense Remote\'u Uygulamalar klasörüne sürükle ve oradan yeniden aç.',
  'apps-checking': 'Uygulamanın yeri denetleniyor…',
  'apps-recheck': 'Yeniden denetle',
  'apps-still-outside':
      'Uygulama hâlâ Uygulamalar klasörünün dışında çalışıyor.',
  'step-permissions': 'macOS izinleri',
  'perm-title-a': 'macOS ',
  'perm-title-b': 'izinleri',
  'perm-lead':
      'macOS bu izinleri yalnızca bilgisayarın başında, bir kez onaylatır. Sırayla aç; durum burada kendiliğinden güncellenir.',
  'perm-lead-controller':
      'macOS bu izni yalnızca bilgisayarın başında, bir kez onaylatır. Durum burada kendiliğinden güncellenir.',
  'perm-screen': 'Ekran Kaydı',
  'perm-screen-desc': 'Ekip bu bilgisayarın ekranını görebilsin.',
  'perm-accessibility': 'Erişilebilirlik',
  'perm-accessibility-desc':
      'Ekip bu bilgisayarın faresini ve klavyesini kullanabilsin.',
  'perm-input': 'Giriş İzleme',
  'perm-input-desc': 'Klavye kısayolları bağlantı sırasında doğru iletilsin.',
  'perm-granted': 'Verildi',
  'perm-missing': 'Bekleniyor',
  'perm-reading': 'Durum okunuyor…',
  'perm-open': 'Sistem Ayarları\'nı aç',
  'perm-open-hint':
      'Açılan listede Sense Remote\'un anahtarını aç. Sense Remote listede yoksa + ile Uygulamalar klasöründen ekle.',
  'perm-all-granted': 'Bütün izinler verildi.',
  'perm-later': 'Daha sonra',
  'perm-later-confirm': 'Yine de devam et',
  'perm-later-warning':
      'İzinler verilmeden ekip bu bilgisayarın ekranını göremez ya da kullanamaz; panelde izin eksik görünür. İzinler daha sonra yine bu bilgisayarın başında verilmek zorunda.',
  'perm-later-warning-controller':
      'Giriş İzleme izni olmadan bazı klavye kısayolları karşı bilgisayara iletilmez. İzin daha sonra Sistem Ayarları\'ndan verilebilir.',
  'perm-agent-error':
      'Ekran Kaydı izni verildi ama arka plan hizmeti yeniden başlatılamadı. Görüntü gelmezse bilgisayarı yeniden başlat.',
  'done-permissions-missing':
      'macOS izinleri eksik: Sistem Ayarları › Gizlilik ve Güvenlik bölümünden verilmeden bağlantı tam çalışmaz.',
  // Sense Remote (update plan §8, U7): one-time move from version 2.
  'step-upgrade': 'Güncelleme',
  'upgrade-title-a': 'Sense Remote ',
  'upgrade-title-b': 'güncellemesi',
  'upgrade-lead':
      'Bu bilgisayarda Sense Remote {from} kurulu. Sürüm {to} kurulacak; hesap, rol, projeler ve bağlantı kimliği korunur.',
  'upgrade-note':
      'Windows yönetici onayı ister. Giriş ve yeniden kayıt gerekmez. Güncelleme sırasında bağlantı kısa süre kopar.',
  'upgrade-start': 'Güncelle',
  'upgrade-running': 'Güncelleme başlatılıyor…',
  'upgrade-error-cancelled': 'Yönetici onayı verilmedi. Güncellemek için yeniden dene.',
  'upgrade-error-not_installed':
      'Bu bilgisayarda kurulu Sense Remote bulunamadı. Pencereyi kapatıp kurulum dosyasını yeniden aç.',
  'upgrade-error-failed':
      'Güncelleme başlatılamadı. Yeniden dene; sorun sürerse ekibe haber ver.',
  'upgrade-current-title-a': 'Sürüm {n}',
  'upgrade-current-title-b': ' kurulu',
  'upgrade-current-lead':
      'Bu bilgisayarda Sense Remote {n} kurulu. Bu kurulum dosyası aynı ya da daha eski bir sürüm; bir şey değiştirilmedi.',
  'upgrade-done-title': 'Güncelleme başladı',
  'upgrade-done-lead':
      'Sense Remote birkaç dakika içinde Sürüm {to} ile yeniden başlar. Bu pencereyi kapatabilirsin.',
  'upgrade-mac-title-a': 'Geçişi ',
  'upgrade-mac-title-b': 'tamamla',
  'upgrade-mac-lead':
      'Sense Remote {to} Uygulamalar klasörüne kopyalandı. Yönetici parolasıyla geçiş tamamlanır: arka plan hizmeti yeni sürümle yeniden başlar. Hesap, rol, projeler ve bağlantı kimliği korunur.',
  'upgrade-mac-note':
      'Giriş ve yeniden kayıt gerekmez. Ardından macOS izinleri yeniden onaylanır; bu adım bilgisayarın başında yapılır.',
  'upgrade-mac-start': 'Geçişi tamamla',
  'upgrade-done-title-mac': 'Geçiş tamamlandı',
  'upgrade-done-lead-mac': 'Sense Remote Sürüm {to} ile çalışıyor.',
};

const Map<String, String> kSenseInstallEn = {
  'window-title': 'Sense Remote Setup',
  'close': 'Close',
  'version': 'Version',
  'step-account': 'Sense account',
  'step-role': 'Role of this computer',
  'step-info': 'Computer details',
  'step-summary': 'Summary and install',
  'account-title-a': 'Sign in',
  'account-title-b': ' with Sense',
  'account-lead':
      'Only a Sense Department employee can install. The computer joins the panel through your account.',
  'google-sign-in': 'Sign in with Google',
  'sign-in-note': 'opens in the browser · two-step verification required',
  'domain-hint': 'Only @sensedepartment.com accounts are accepted',
  'requesting': 'Connecting to the panel…',
  'pairing-label': 'Pairing code',
  'pairing-spoken': 'Pairing code: ',
  'pairing-hint':
      'The approval page in the browser must show the same code. If it differs, do not approve.',
  'open-browser': 'Approve in the browser',
  'copy-link': 'Copy link',
  'link-copied': 'Link copied.',
  'waiting': 'Waiting for the approval in the browser (up to 3 minutes).',
  'cancel': 'Cancel',
  'verified': 'verified',
  'other-account': 'Use another account',
  'login-timeout': 'Sign-in timed out (3 minutes). Try again with a new code.',
  'login-failed': 'Sign-in could not be completed.',
  'new-code': 'Get a new code',
  'retry': 'Try again',
  'role-title-a': 'Role of this ',
  'role-title-b': 'computer',
  'role-lead':
      'Pick one or both. After installation it can only be changed from the panel.',
  'host-desc':
      'The team can connect to this computer. For venues and installations.',
  'controller-desc':
      'Connect from this computer to the computers your account manages. For team computers.',
  'no-role': 'Nothing selected yet.',
  'both-desc':
      ' — the team can connect here, and you can connect from here to others.',
  'info-title-a': 'Computer ',
  'info-title-b': 'details',
  'info-lead':
      'The computer is added to the pages of the projects you pick; the panel shows these details.',
  'name': 'Computer name',
  'name-hint': 'e.g. Gallery kiosk',
  'projects': 'Projects',
  'projects-multi': '(you can pick several)',
  'projects-loading': 'Loading projects…',
  'projects-empty': 'No projects yet; type a new project name below.',
  'projects-error': 'Could not load the project list.',
  'projects-error-token_invalid':
      'Could not load the project list: sign-in is not valid.',
  'projects-error-network':
      'Could not load the project list: the panel is not reachable.',
  'projects-max': 'At most 10 projects.',
  'project-hint': 'Type a new project name, Enter',
  'add-project': 'Add new project',
  'remove-project': 'Remove project',
  'new-tag': 'new',
  'location': 'Location',
  'location-hint': 'e.g. Gallery 1',
  'note': 'Note (optional)',
  'note-hint': 'e.g. 2 displays, connected to the LED processor',
  'summary-title': 'Summary',
  'summary-lead':
      'After installation the settings are locked here; changes come from the panel.',
  'summary-lead-controller':
      'After installation you can connect from this computer to others.',
  'account': 'Account',
  'role': 'Role',
  'update': 'Updates',
  'update-value': 'Automatic',
  'password': 'Access password',
  'password-value': 'From the password manager, after installation',
  'none': '—',
  'advanced': 'Advanced',
  'install-path': 'Install folder',
  'change-path': 'Change',
  'start-menu': 'Add to Start menu',
  'desktop-icon': 'Add desktop shortcut',
  'printer': 'Install the Sense Remote printer',
  'back': 'Back',
  'next': 'Continue',
  'install': 'Install',
  'installing': 'Installing… Windows will ask for administrator approval.',
  'error-cancelled':
      'Administrator approval was not given; nothing was installed.',
  'error-failed': 'Installation could not be completed.',
  'error-not-signed-in': 'Sign in with your Sense account first.',
  'error-invalid-name': 'Computer name is empty or too long.',
  'error-invalid-project':
      'A project name is too long, or there are too many projects.',
  'error-invalid-location': 'Location is too long.',
  'error-invalid-note': 'Note is too long.',
  'error-info-too-long': 'The details are too long; shorten the location.',
  'register-title-a': 'Panel ',
  'register-title-b': 'registration',
  'registering': 'Registering the computer with the panel…',
  'register-failed': 'Installed, but the panel registration failed.',
  'skip-register': 'Skip registration',
  'relogin': 'Sign in again',
  'edit-details': 'Edit details',
  'register-save': 'Register with the panel',
  'seconds-short': 's',
  'enroll-token_invalid':
      'The sign-in is not valid or has expired. Sign in again to finish the registration.',
  'enroll-install_scope':
      'The sign-in is older than 30 minutes. Sign in again to finish the registration.',
  'enroll-device_mismatch':
      'The sign-in was not made with this computer\'s ID. Sign in again to finish the registration.',
  'enroll-validation':
      'The panel did not accept the details. Fix the name, location and project names, then register again.',
  'enroll-project_not_found':
      'One of the chosen projects no longer exists (it may be archived). Pick the projects again.',
  'enroll-uuid_mismatch':
      'Another computer is registered with this ID; the panel raised an alert. Skip and tell an administrator.',
  'enroll-rate_limited': 'Too many attempts. Wait 1 minute, then try again.',
  'enroll-retry': 'The panel could not answer right now. Try again.',
  'enroll-network':
      'The panel is not reachable. Check the internet connection and try again.',
  'enroll-other': 'Registration failed. Try again.',
  'enroll-invalid-name': 'The computer name is not valid. Fix it and save again.',
  'enroll-invalid-location': 'The location is not valid. Fix it and save again.',
  'enroll-invalid-note': 'The note is too long or not valid. Fix it and save again.',
  'enroll-invalid-project':
      'The project choice is not valid (at most 10 projects, short names). Fix it and save again.',
  'enroll-not-installed':
      'The installation does not look complete. Skip and tell the Sense team.',
  'enroll-build':
      'This setup file was built incomplete. Skip and tell the Sense team.',
  'enroll-identity':
      'The identity of this computer could not be read. Skip and tell the Sense team.',
  'enroll-identity-store':
      'The identity of this computer could not be saved. Skip and tell the Sense team.',
  'enroll-device_closed':
      'This computer was closed in the panel. Contact the panel administrator.',
  'enroll-reinstall_not_allowed':
      'This computer is already registered in the panel. To reinstall, allow "Reinstall" on its page in the panel, then try again.',
  'done-title': 'Installed',
  'done-lead': 'Sense Remote is installed on this computer.',
  'done-lead-locked': 'Settings are locked; changes come from the panel.',
  'done-host-background':
      'Sense Remote runs in the background; during a connection a small icon shows in the bottom-right corner.',
  'done-panel-project': 'The computer is on the {projects} page in the panel.',
  'done-panel-projects':
      'The computer is on the {projects} pages in the panel.',
  'done-panel-none': 'The computer is active in the panel.',
  'done-pending':
      'Not registered: the computer shows up in the panel as waiting for approval; any Sense employee can approve it.',
  'open-app': 'Open Sense Remote',
  'installing-mac': 'Installing… macOS will ask for the administrator password.',
  'error-not-in-applications':
      'Sense Remote is not running from the Applications folder. Drag the app to Applications and open it from there.',
  'error-daemon-timeout':
      'The background service could not be started. Try again; if it keeps failing, tell the Sense team.',
  'apps-title-a': 'Move to ',
  'apps-title-b': 'Applications',
  'apps-lead':
      'Drag Sense Remote to the Applications folder and open it from there.',
  'apps-detail':
      'Sense Remote can not be installed while it runs from the downloaded disk image. Close this window, drag Sense Remote to the Applications folder and open it from there.',
  'apps-checking': 'Checking where the app runs from…',
  'apps-recheck': 'Check again',
  'apps-still-outside':
      'The app still runs from outside the Applications folder.',
  'step-permissions': 'macOS permissions',
  'perm-title-a': 'macOS ',
  'perm-title-b': 'permissions',
  'perm-lead':
      'macOS asks for these permissions once, at the computer itself. Turn them on in order; the state updates here by itself.',
  'perm-lead-controller':
      'macOS asks for this permission once, at the computer itself. The state updates here by itself.',
  'perm-screen': 'Screen Recording',
  'perm-screen-desc': 'So the team can see the screen of this computer.',
  'perm-accessibility': 'Accessibility',
  'perm-accessibility-desc':
      'So the team can use the mouse and keyboard of this computer.',
  'perm-input': 'Input Monitoring',
  'perm-input-desc':
      'So keyboard shortcuts are passed on correctly during a connection.',
  'perm-granted': 'Granted',
  'perm-missing': 'Waiting',
  'perm-reading': 'Reading the state…',
  'perm-open': 'Open System Settings',
  'perm-open-hint':
      'Turn on the switch of Sense Remote in the list. If Sense Remote is not listed, add it with + from the Applications folder.',
  'perm-all-granted': 'All permissions are granted.',
  'perm-later': 'Later',
  'perm-later-confirm': 'Continue anyway',
  'perm-later-warning':
      'Without the permissions the team can not see or use this computer; the panel shows them as missing. They still have to be granted at this computer later.',
  'perm-later-warning-controller':
      'Without Input Monitoring some keyboard shortcuts are not passed on to the other computer. It can be granted later in System Settings.',
  'perm-agent-error':
      'Screen Recording was granted but the background service could not be restarted. If no picture arrives, restart the computer.',
  'done-permissions-missing':
      'macOS permissions are missing: until they are granted in System Settings › Privacy & Security the connection does not fully work.',
  // Sense Remote (update plan §8, U7): one-time move from version 2.
  'step-upgrade': 'Update',
  'upgrade-title-a': 'Sense Remote ',
  'upgrade-title-b': 'update',
  'upgrade-lead':
      'Sense Remote {from} is installed on this computer. Version {to} will be installed; account, role, projects and connection ID are kept.',
  'upgrade-note':
      'Windows asks for administrator approval. No sign-in or new registration. The connection drops briefly during the update.',
  'upgrade-start': 'Update',
  'upgrade-running': 'Starting the update…',
  'upgrade-error-cancelled': 'Administrator approval was not given. Try again to update.',
  'upgrade-error-not_installed':
      'No installed Sense Remote was found. Close this window and open the setup file again.',
  'upgrade-error-failed':
      'The update could not be started. Try again; if it keeps failing, tell the team.',
  'upgrade-current-title-a': 'Version {n}',
  'upgrade-current-title-b': ' installed',
  'upgrade-current-lead':
      'Sense Remote {n} is installed on this computer. This setup file is the same or an older version; nothing was changed.',
  'upgrade-done-title': 'Update started',
  'upgrade-done-lead':
      'Sense Remote restarts with version {to} within a few minutes. You can close this window.',
  'upgrade-mac-title-a': 'Finish the ',
  'upgrade-mac-title-b': 'move',
  'upgrade-mac-lead':
      'Sense Remote {to} was copied to Applications. The administrator password finishes the move: the background service restarts with the new version. Account, role, projects and connection ID are kept.',
  'upgrade-mac-note':
      'No sign-in or new registration. The macOS permissions are approved again afterwards, at the computer itself.',
  'upgrade-mac-start': 'Finish the move',
  'upgrade-done-title-mac': 'Move finished',
  'upgrade-done-lead-mac': 'Sense Remote runs version {to}.',
};

String senseInstallText(String key) =>
    kSenseInstallTr[key] ?? kSenseInstallEn[key] ?? key;

/// Sense Remote: pairing code in two groups of three, like the panel's approval page
/// (`ClientApprove.tsx`: "482 913").
String formatSensePairingCode(String code) =>
    code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

/// Digit by digit for screen readers ("4 8 2 9 1 3").
String spokenSensePairingCode(String code) => code.split('').join(' ');
