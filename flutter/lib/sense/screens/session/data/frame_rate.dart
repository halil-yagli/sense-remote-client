// Sense Remote: the frame rate the session shows (karar #152).
//
// Shown rate = frames really drawn on the Controller: the frames the decoder handed to the
// renderer (RustDesk's per-display count) capped by the frames this window rasterized in
// the same second (a 144 Hz Host on a 120 Hz Controller shows 120). RustDesk sends a frame
// only when the picture changed, so a still screen measures 0 on a healthy link; then the
// last rate measured while the picture moved is shown (last [kSenseRecentFpsWindow]), and
// before any movement the reachable rate (Host refresh rate capped by the session's frame
// limit) with the hint "henüz ölçülmedi".
import 'dart:math' as math;
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../../../consts.dart' show kRemoteImageQualityCustom;

/// The Host's frame cap when the viewer sent none (RustDesk `video_qos::FPS`).
const int kSenseDefaultFpsCap = 30;

/// How long a rate measured while the picture moved stands in for a still screen.
const Duration kSenseRecentFpsWindow = Duration(seconds: 60);

/// The session's frame limit: the custom frame rate under "Özel kalite", else the
/// Host's default cap.
int senseSessionFpsCap({String? imageQuality, int? customFps}) =>
    imageQuality == kRemoteImageQualityCustom && customFps != null && customFps > 0
        ? customFps
        : kSenseDefaultFpsCap;

/// The smaller of the Host display's refresh rate (when known) and the session's cap.
int senseReachableFps({double? refreshHz, required int cap}) {
  final hz = refreshHz?.round();
  return hz == null || hz <= 0 ? cap : math.min(hz, cap);
}

/// Frames drawn this second: the decoded count, capped by the window's rasterized frames
/// when that is known (the window can show no more frames than it rasterizes).
int senseDrawnFps({required int decoded, int? rasterized}) =>
    rasterized == null || rasterized <= 0 ? decoded : math.min(decoded, rasterized);

/// Remembers the rates measured while the picture moved. Pure Dart; time is passed in.
class SenseFrameMeter {
  final List<({Duration at, int fps})> _moving = [];

  /// One reading per second; [still] = the screen was not changing (no movement to count).
  void add({required Duration at, required int fps, required bool still}) {
    _moving.removeWhere((e) => at - e.at > kSenseRecentFpsWindow);
    if (!still && fps > 0) _moving.add((at: at, fps: fps));
  }

  /// The best rate measured while the picture moved in the last [kSenseRecentFpsWindow]
  /// (the tail of a movement is slow; the best second is what the picture flows at).
  int? recent(Duration now) {
    int? best;
    for (final e in _moving) {
      if (now - e.at > kSenseRecentFpsWindow) continue;
      if (best == null || e.fps > best) best = e.fps;
    }
    return best;
  }
}

/// Frames this window rasterized in the last second (Flutter frame timings). The remote
/// picture is a texture: every new frame on screen is one rasterized window frame.
class SenseRasterRate {
  SenseRasterRate._();

  static final SenseRasterRate instance = SenseRasterRate._();

  final List<int> _finishedUs = [];
  bool _started = false;

  void _start() {
    if (_started) return;
    _started = true;
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } catch (_) {
      _started = false;
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _finishedUs.add(t.timestampInMicroseconds(FramePhase.rasterFinish));
    }
    if (_finishedUs.length > 1000) _finishedUs.removeRange(0, _finishedUs.length - 1000);
  }

  /// Frames rasterized in the second before the newest timing (null = not known yet).
  int? perSecond() {
    _start();
    if (_finishedUs.isEmpty) return null;
    final last = _finishedUs.last;
    return _finishedUs.where((us) => last - us < 1000000).length;
  }
}

/// What the bar's backend measured for one connection; the connection card reads it.
@immutable
class SenseFrameInfo {
  const SenseFrameInfo({this.drawnFps, this.recentFps, this.reachableFps, this.remoteHz});

  /// Frames drawn in the last second (moving picture).
  final int? drawnFps;

  /// Best rate measured while the picture moved lately (null = not measured yet).
  final int? recentFps;

  /// Host refresh rate capped by the session's frame limit.
  final int? reachableFps;

  /// The watched Host display's refresh rate (Hz), when known.
  final int? remoteHz;
}

/// One value per connection (peer id).
class SenseFrameCap {
  SenseFrameCap._();

  static final Map<String, ValueNotifier<SenseFrameInfo>> _byId = {};

  static ValueNotifier<SenseFrameInfo> of(String id) =>
      _byId.putIfAbsent(id, () => ValueNotifier(const SenseFrameInfo()));

  static void remove(String id) => _byId.remove(id)?.dispose();
}
