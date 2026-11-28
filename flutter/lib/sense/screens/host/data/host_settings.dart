// Sense Remote: the Host's audio and network settings the panel set (FU-A4, "Ses ve ağ").
// The panel writes them with the signed envelope (Sürüm 9, `HOST_OPTION_KEYS`); here they
// are only read. A value that cannot be read is shown as "okunamadı"; nothing is made up.
import '../../../../consts.dart';
import '../../../../models/platform_model.dart';
import '../../../strings/host.dart';

/// Raw option values; null = could not be read.
class SenseHostNet {
  const SenseHostNet({this.audioInput, this.audioEnabled, this.keepAwake, this.relayDelay, this.disableUdp});

  /// `audio-input` ('' = the system sound; the panel's "off" also writes `enable-audio` = N).
  final String? audioInput;
  final String? audioEnabled;
  final String? keepAwake;

  /// `relay-fallback-delay` ('' = default, else seconds).
  final String? relayDelay;
  final String? disableUdp;

  /// Nothing read (the first frame, or the bridge did not answer).
  static const SenseHostNet unknown = SenseHostNet();

  String get audioText {
    if (audioEnabled == 'N') return SenseHostStrings.valueOff;
    final a = audioInput;
    if (a == null) return SenseHostStrings.unreadable;
    return a.isEmpty ? SenseHostStrings.netAudioSystem : SenseHostStrings.netAudioMic;
  }

  String get awakeText {
    final v = keepAwake;
    if (v == null) return SenseHostStrings.unreadable;
    return v == 'Y' ? SenseHostStrings.valueOn : SenseHostStrings.valueOff;
  }

  String get relayText {
    final v = relayDelay;
    if (v == null) return SenseHostStrings.unreadable;
    if (v.isEmpty) return SenseHostStrings.netRelayDefault;
    final n = int.tryParse(v);
    if (n == null || n < 0) return SenseHostStrings.unreadable;
    return n == 0 ? SenseHostStrings.netRelayNow : SenseHostStrings.netRelaySeconds(n);
  }

  /// UDP is open unless the panel turned it off (`disable-udp` = Y).
  String get udpText {
    final v = disableUdp;
    if (v == null) return SenseHostStrings.unreadable;
    return v == 'Y' ? SenseHostStrings.valueOff : SenseHostStrings.valueOn;
  }

  /// The panel has one switch for this (`disable-udp`): with UDP off the Host
  /// talks over TCP / WebSocket only.
  String get tcpOnlyText {
    final v = disableUdp;
    if (v == null) return SenseHostStrings.unreadable;
    return v == 'Y' ? SenseHostStrings.valueOn : SenseHostStrings.valueOff;
  }
}

typedef SenseOptionReader = Future<String> Function(String key);

/// Reads the five settings; a key that fails stays null.
Future<SenseHostNet> senseHostNetRead([SenseOptionReader? read]) async {
  final get = read ?? (key) => bind.mainGetOption(key: key);
  Future<String?> one(String key) async {
    try {
      return await get(key);
    } catch (_) {
      return null;
    }
  }

  return SenseHostNet(
    audioInput: await one('audio-input'),
    audioEnabled: await one(kOptionEnableAudio),
    keepAwake: await one(kOptionKeepAwakeDuringIncomingSessions),
    relayDelay: await one(kOptionRelayFallbackDelay),
    disableUdp: await one(kOptionDisableUdp),
  );
}
