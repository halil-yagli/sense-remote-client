// Sense Remote: texts of the "Bilgisayar durumu" and "Ekran bilgisi" popups
// (YH O8, O9; T2: Turkish only). Taken word for word from the locked design
// prototip/onayli/2026-11-22_bilgisayar-durumu_ONAYLI.html and the prototype.

abstract final class SenseStatusStrings {
  static const String title = 'Bilgisayar durumu';
  static const String popupId = 'status';

  // Live line and header.
  static String live(String? age) => age == null ? 'Canlı' : 'Canlı · $age';
  static String offline(String? age) => age == null ? 'Çevrimdışı' : 'Çevrimdışı · son veri $age';
  static const String loading = 'Bilgiler panelden alınıyor…';
  static const String noPanelInfo = 'Bu bilgisayar için panel bilgisi yok.';
  static const String panelFailed = 'Panel bilgisine ulaşılamadı.';
  static const String retry = 'Yeniden dene';
  static const String unreadable = 'okunamadı';

  // Overall box (T7).
  static const String allOk = 'Her şey normal';
  static const String warn = 'Uyarı var';
  static const String hot = 'Dikkat gerekiyor';

  // Categories.
  static const String cpu = 'İşlemci';
  static const String gpu = 'Ekran kartı';
  static const String memory = 'Bellek';
  static const String storage = 'Depolama';
  static const String network = 'Ağ';
  static const String displays = 'Ekranlar';
  static const String components = 'Bileşenler';
  static const String software = 'Yazılım ve sürücüler';

  // Rows.
  static const String usage = 'Kullanım';
  static const String temperature = 'Sıcaklık';
  static const String model = 'Model';
  static const String coresThreads = 'Çekirdek / iş parçacığı';
  static const String baseCurrentSpeed = 'Temel / anlık hız';
  static const String topProcesses = 'En yoğun işlemler';
  static const String vram = 'Video belleği';
  static const String fan = 'Fan';
  static const String power = 'Güç';
  static const String driverVersion = 'Sürücü sürümü';
  static const String driverDate = 'Sürücü tarihi';
  static const String integrated = 'tümleşik';
  static const String used = 'Kullanılan';
  static const String available = 'Kullanılabilir';
  static const String swap = 'Sayfa dosyası';
  static const String installedMemory = 'Takılı bellekler';
  static String slot(int n) => 'Bellek $n';
  static const String freeSlots = 'Boş yuva';
  static const String diskHealth = 'Sağlık';
  static const String totalWritten = 'Toplam yazılan';
  static const String writtenSinceBoot = 'Açılıştan beri yazılan';
  static const String readWrite = 'Anlık okuma / yazma';
  static const String firmware = 'Yazılım sürümü';
  static const String healthOk = 'İyi';
  static const String healthWarning = 'Uyarı';
  static const String healthFailing = 'Arızalı';
  static String lifeLeft(String pct) => 'kalan ömür $pct';
  static String disk(String mount) => 'Disk $mount';
  static const String card = 'Kart';
  static const String ipv4 = 'IPv4';
  static const String ipv4Extra = 'IPv4 (ek)';
  static const String ipv6 = 'IPv6';
  static const String gateway = 'Ağ geçidi';
  static const String dns = 'DNS';
  static const String mac = 'MAC';
  static const String speed = 'Hız';
  static const String traffic = 'Anlık trafik';
  static const String wifiName = 'Ağ adı';
  static String signal(String pct) => 'sinyal $pct';
  static const String connected = 'bağlı';
  static const String cableOut = 'kablo takılı değil';
  static const String notConnected = 'bağlı değil';
  static const String tagStatic = 'STATİK';
  static const String tagDhcp = 'DHCP';
  static const String ethernet = 'Ethernet';
  static const String wifi = 'Wi‑Fi';
  static const String networkNote =
      'Sıra: önce kablolu, sonra Wi‑Fi, sonra diğerleri. STATİK = elle verilmiş, DHCP = ağdan otomatik.';
  static String adapters(int n) => '$n bağdaştırıcı';
  static String displayCount(int n) => '$n ekran';
  static const String primary = 'Ana';
  static const String board = 'Anakart';
  static const String bios = 'BIOS';
  static const String serial = 'Seri no';
  static const String audio = 'Ses';
  static const String usb = 'USB aygıtları';
  static const String powerPlan = 'Güç planı';
  static const String powerRestore = 'Elektrik kesilince';
  static String powerRestoreValue(bool on) => 'Açılışta otomatik aç: ${on ? 'açık' : 'kapalı'}';
  static const String osGroup = 'İşletim sistemi';
  static const String osVersion = 'Sürüm';
  static const String osBuild = 'Yapı';
  static const String lastUpdate = 'Son güncelleme';
  static const String hostname = 'Bilgisayar adı';
  static const String timezone = 'Saat dilimi';
  static const String uptime = 'Açık kalma';
  static const String driversGroup = 'Sürücüler';
  static const String driverDisplay = 'Ekran kartı';
  static const String driverNetwork = 'Ağ';
  static const String driverWifi = 'Wi‑Fi';
  static const String driverAudio = 'Ses';
  static const String driverChipset = 'Yonga seti';
  static const String senseGroup = 'Sense Remote';
  static const String senseVersion = 'Sürüm';
  static const String service = 'Hizmet';
  static const String serviceRunning = 'Çalışıyor';
  static String senseVersionValue(String version, String? role) =>
      role == null ? version : '$version (rol: $role)';
  static String senseSummary(String version) => 'Sense Remote $version';
  static const String roleHost = 'Host';
  static const String roleController = 'Controller';
  static const String roleBoth = 'Host + Controller';
  static const String copied = 'Kopyalandı';

  /// Bottom note (locked design, word for word).
  static const String hint =
      'Eşikler: kullanım ve doluluk %85 turuncu, %95 kırmızı · işlemci / ekran kartı 80 °C turuncu, '
      '90 °C kırmızı · disk 55 °C turuncu, 65 °C kırmızı. "okunamadı": bilgisayar o değeri vermiyor, '
      'tahmin yazılmaz.';
}

abstract final class SenseDisplayStrings {
  static const String title = 'Ekran bilgisi';
  static const String popupId = 'display';

  static String watching(int count, String watched) => '$count ekran · $watched izleniyor';
  static String display(int n) => 'Ekran $n';
  static String displayPrimary(int n) => 'Ekran $n · ana';
  static const String allDisplays = 'tüm ekranlar';

  static const String frameRate = 'Kare hızı';
  static const String latency = 'Gecikme';
  static const String connection = 'Bağlantı';
  static const String session = 'Oturum görüntüsü';

  static const String monitor = 'Monitör';
  static const String resolution = 'Çözünürlük';
  static const String scale = 'Ölçek';
  static const String refresh = 'Yenileme';
  static const String color = 'Renk';
  static const String hdr = 'HDR';
  static const String position = 'Konum';
  static const String hdrOn = 'Açık';
  static const String hdrOff = 'Kapalı';
  static String nativeSize(String size) => '$size (yerel)';
  static String nativeOther(String size, String native) => '$size (yerel $native)';
  static String othersHz(String hz) => '(diğerleri $hz)';
  static const String ycbcrNote =
      'ince yazı ve renk kenarları yumuşayabilir; ekran kartı ayarından RGB 4:4:4 önerilir.';

  static const String pathType = 'Bağlantı türü';
  static const String pathDirect = 'Doğrudan';
  static const String pathDirectLong = 'Doğrudan (aktarma yok)';
  static const String pathRelay = 'Aktarma';
  static const String pathRelayLong = 'Aktarma sunucusu üzerinden';
  static const String codec = 'Kodek';
  static const String quality = 'Kalite';
  static const String qualityBest = 'İyi görüntü';
  static const String qualityBalanced = 'Dengeli';
  static const String qualityLow = 'Hızlı tepki';
  static const String qualityCustom = 'Özel';
  static const String bandwidth = 'Bant genişliği';
  static const String lostFrames = 'Kayıp kare';
  static String estimated(String v) => '$v (tahmini)';

  /// Bottom note (prototype, word for word).
  static const String hint =
      'Uyarı rengi: ekranlar arasında farklı yenileme hızı ya da 4:2:2 renk biçimi; gecikme 80 ms '
      'üstü turuncu, 150 ms üstü kırmızı.';
}
