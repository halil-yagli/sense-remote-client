// Sense Remote: the live session numbers for "Ekran bilgisi" (YH O9): frame
// rate, latency, direct/relay, codec, quality, bandwidth, loss estimate, and
// which displays the remote computer has and which one is watched.
// Source: RustDesk's own quality status (`update_quality_status` event →
// QualityMonitorModel) and PeerInfo; D1 adds the loss estimate (`loss_est`) to
// the same event. Values not measured stay null ("okunamadı").
import 'package:flutter/foundation.dart';

import '../../../../../consts.dart' show kAllDisplayValue;
import '../../../../../models/model.dart' show FFI;
import '../../../../../models/platform_model.dart' show bind;

/// Geometry of one remote display as RustDesk knows it.
@immutable
class SenseSessionDisplay {
  const SenseSessionDisplay({required this.index, required this.x, required this.y, required this.width, required this.height});
  final int index;
  final int x;
  final int y;
  final int width;
  final int height;
}

/// One snapshot of the session numbers.
@immutable
class SenseSessionVideo {
  const SenseSessionVideo({
    this.fps,
    this.rttMs,
    this.direct,
    this.codec,
    this.hardwareCodec,
    this.quality,
    this.bandwidthMbit,
    this.lossEstPct,
    this.displays = const [],
    this.watched = 0,
  });

  final double? fps;
  final double? rttMs;

  /// true direct, false relay, null unknown.
  final bool? direct;

  /// "VP9", "H264", "AV1" …
  final String? codec;

  /// Hardware encoder in use; RustDesk does not report it to the session yet.
  final bool? hardwareCodec;

  /// best, balanced, low, custom
  final String? quality;
  final double? bandwidthMbit;

  /// D1 estimate (`loss_est`), percent; always "tahmini".
  final double? lossEstPct;
  final List<SenseSessionDisplay> displays;

  /// Watched display index; [kAllDisplayValue] = all at once.
  final int watched;

  bool get watchingAll => watched == kAllDisplayValue;
}

/// "123.45kB/s" (RustDesk: kB = 1024 bytes) → megabit per second.
double? senseParseSpeedMbit(String? speed) {
  if (speed == null) return null;
  final m = RegExp(r'^\s*([0-9]+(?:\.[0-9]+)?)\s*([kKmM]?)B/s\s*$').firstMatch(speed);
  if (m == null) return null;
  final v = double.tryParse(m.group(1)!);
  if (v == null) return null;
  final unit = m.group(2)!.toLowerCase();
  final bytes = unit == 'k' ? v * 1024 : (unit == 'm' ? v * 1024 * 1024 : v);
  return bytes * 8 / 1e6;
}

double? _num(String? s) {
  if (s == null) return null;
  final m = RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(s);
  return m == null ? null : double.tryParse(m.group(0)!);
}

/// Reads [SenseSessionVideo] from a session's FFI and notifies on every
/// quality update (RustDesk sends one about every second).
class SenseSessionVideoSource extends ChangeNotifier implements ValueListenable<SenseSessionVideo> {
  SenseSessionVideoSource(this._ffi) {
    _ffi.qualityMonitorModel.addListener(_update);
    _ffi.ffiModel.addListener(_update);
    _readQuality();
    _update();
  }

  final FFI _ffi;
  String? _quality;
  SenseSessionVideo _value = const SenseSessionVideo();
  bool _disposed = false;

  @override
  SenseSessionVideo get value => _value;

  Future<void> _readQuality() async {
    try {
      _quality = await bind.sessionGetImageQuality(sessionId: _ffi.sessionId);
    } catch (_) {
      _quality = null;
    }
    _update();
  }

  void _update() {
    if (_disposed) return;
    final q = _ffi.qualityMonitorModel.data;
    final pi = _ffi.ffiModel.pi;
    _value = SenseSessionVideo(
      fps: _num(q.fps),
      rttMs: _num(q.delay),
      direct: _ffi.ffiModel.direct,
      codec: (q.codecFormat == null || q.codecFormat!.isEmpty) ? null : q.codecFormat,
      quality: _quality,
      bandwidthMbit: senseParseSpeedMbit(q.speed),
      lossEstPct: q.lossEst,
      displays: [
        for (var i = 0; i < pi.displays.length; i++)
          SenseSessionDisplay(
            index: i,
            x: pi.displays[i].x.round(),
            y: pi.displays[i].y.round(),
            width: pi.displays[i].width,
            height: pi.displays[i].height,
          ),
      ],
      watched: pi.currentDisplay,
    );
    notifyListeners();
  }

  /// Image quality changes from the Görüntü list; read it again.
  void refreshQuality() => _readQuality();

  @override
  void dispose() {
    _disposed = true;
    _ffi.qualityMonitorModel.removeListener(_update);
    _ffi.ffiModel.removeListener(_update);
    super.dispose();
  }
}
