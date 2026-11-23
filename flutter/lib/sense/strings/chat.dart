// Sense Remote: words of the shared chat (YH O10, O11 sesli, O12; H4 uses the
// same chat). Turkish only (T2, #59). The side-specific names (who "Sen" talks
// to) are in [SenseChatLabels].

abstract final class SenseChatStrings {
  static const String title = 'Sohbet';

  /// Faded note at the top of the messages (#56).
  static const String wipeNote = 'Sohbet ve dosya listesi bağlantı bitince silinir';

  static const String me = 'Sen';

  // Writing row (O10, O12).
  static const String hint = 'Mesaj yaz ya da dosya sürükle…';
  static const String send = 'Gönder';
  static const String attach = 'Dosya ekle';
  static const String dropHere = 'Bırakınca gönderilir';

  // Call (O11, voice only: #67).
  static const String call = 'Ara';
  static const String endCall = 'Aramayı bitir';
  static const String calling = 'Aranıyor…';
  static String inCall(String mmss) => 'Görüşmede · $mmss';

  // Incoming call (H4, #73: the other side calls; voice only, #67).
  static const String accept = 'Kabul et';
  static const String reject = 'Reddet';

  static const String microphone = 'Mikrofon';
  static const String micOff = 'kapalı';
  static const String micsHeader = 'Mikrofonlar · bu bilgisayara bağlı';
  static const String defaultMic = 'Varsayılan mikrofon';
  static const String level = 'Ses seviyesi';
  static const String outputHeader = 'Ses çıkışı';
  static const String defaultOutput = 'Sistem varsayılanı';
  static const String muteMic = 'Mikrofonu kapat';
  static const String muteFailed = 'Mikrofon kapatılamadı';

  // File bubble (O12).
  static const String kindImage = 'Resim';
  static const String kindVideo = 'Video';
  static const String kindDoc = 'Belge';
  static const String sending = 'Gönderiliyor';
  static const String receiving = 'İndiriliyor';
  static const String resuming = 'Kaldığı yerden sürüyor';
  static const String failed = 'Aktarılamadı';
  static const String sentSaved = 'Gönderildi, karşıda İndirilenler’e kaydedildi';
  static const String savedDownloads = 'İndirilenler’e kaydedildi';
  static const String savedIncoming = 'Gelen dosyalar klasörüne kaydedildi';
  static const String showInFolder = 'Klasörde göster';

  // Icon (O10, H3 look).
  static const String iconTooltip = 'Sohbet · basınca açılır, sürükleyerek taşınır';
  static const String minimize = 'Simgeye küçült';

  // Notification card (#62).
  static const String noticeNow = 'Sense Remote · şimdi';
  static String noticeTitle(String computer) => '$computer · yeni mesaj';
  static String noticeBody(String author, String text) => '$author: $text';
  static String noticeFile(String author, String file) => '$author: $file';
}

/// Names that depend on the side. Controller talks to the person on site; the
/// Host card (C5) talks to Sense Department.
class SenseChatLabels {
  const SenseChatLabels({
    required this.subtitle,
    required this.peer,
    required this.peerOnline,
    required this.incomingCall,
  });

  /// Controller window (O10): "Sohbet · Sahadaki kişiyle".
  static const SenseChatLabels controller = SenseChatLabels(
    subtitle: 'Sahadaki kişiyle',
    peer: 'Sahadaki kişi',
    peerOnline: 'Sahadaki kişi çevrimiçi',
    incomingCall: 'Sahadaki kişi sesli arıyor',
  );

  /// Host card (H4): "Sense Department ile sohbet".
  static const SenseChatLabels host = SenseChatLabels(
    subtitle: 'Sense Department ile',
    peer: 'Sense Department',
    peerOnline: 'Sense Department ile sohbet',
    incomingCall: 'Sense Department sesli arıyor',
  );

  /// Grey text next to "Sohbet".
  final String subtitle;

  /// Author line of the other side's messages.
  final String peer;

  /// Status row when no call is running.
  final String peerOnline;

  /// Green "… sesli arıyor" box of an incoming call (#73).
  final String incomingCall;
}
