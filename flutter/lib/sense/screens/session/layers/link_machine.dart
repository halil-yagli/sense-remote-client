// Sense Remote: connection problem state machine (YH O13; TK7). Pure Dart.
//
// It runs on its own one-second tick ([SenseLinkTiming.tick]) because a frozen link
// sends no event at all. Every tick it gets the latest [SenseLinkSample] and the
// current time (a monotonic clock; tests pass a fake one).
//
// Karar #94 (the layer must never get in the way of a working link):
//   normal ── fps < 5 for 15 s without a break ──▶ weak   (delay / loss alone: no card)
//   any ── transport lost (RustDesk "restarting") ──▶ lost
//   weak / lost ── good 3 s without a break ──▶ normal  (+ "Bağlantı düzeldi")
//   any ── no frame and no delay measurement 30 s ──▶ dropped (O14 "Uzak bilgisayar…")
//   transport lost ── 30 s without the link coming back ──▶ dropped
// While frames or probes keep coming the machine never drops. Sürüm 11 (O1): while the
// transport is lost the controller really connects again ([SenseRetryPlan]); the card counts
// those attempts, not the seconds.
//
// A short shake shows no layer; the top bar says "Dalgalı" ([SenseLinkView.wavy]).
import '../../../tokens/sense_tokens.dart';
import '../data/screen_still.dart';
import 'layer_spec.dart';

/// What the link looks like at one moment. Null = not known (not measured yet).
class SenseLinkSample {
  const SenseLinkSample({
    this.rttMs,
    this.lossPct,
    this.fps,
    this.frameAge,
    this.probeAge,
    this.bandwidthMbit,
  });

  /// Round trip of the last delay probe.
  final double? rttMs;

  /// Estimated loss in percent (D1 `loss_est`; not measured, TK7).
  final double? lossPct;

  /// Frames in the last second.
  final double? fps;

  /// Time since the last decoded frame (D1 `last_frame_ms`).
  final Duration? frameAge;

  /// Time since the last delay probe from the Host arrived.
  final Duration? probeAge;

  /// Picture data in Mbit/s (RustDesk `speed`). Null: not measured.
  final double? bandwidthMbit;

  /// How long the link has been stalled: no picture *and* no probe. A still screen
  /// sends no frame but the probes keep coming, so frames alone never mean "lost"
  /// (D1 note in `src/sense/link_quality.rs`). Without probe data only frames count.
  Duration get stall {
    final frame = frameAge;
    final probe = probeAge;
    if (probe == null) return Duration.zero;
    final rtt = Duration(milliseconds: (rttMs ?? 0).round());
    var late = probe - SenseLinkTiming.probeInterval - rtt;
    if (late < Duration.zero) late = Duration.zero;
    if (frame == null) return late;
    return frame < late ? frame : late;
  }

  SenseLevel get latencyLevel => SenseThresholds.latency.levelOf(rttMs);
  SenseLevel get lossLevel => SenseThresholds.packetLoss.levelOf(lossPct);
  SenseLevel get fpsLevel => SenseThresholds.frameRate.levelOf(fps);

  /// Values outside the working limits (eşik satırı: gecikme 150 ms · kayıp %2).
  /// The frame rate alone does not count: a still screen has no frames (D1); its
  /// tile is still coloured by the limit.
  bool get valuesBad => _atLeastWarn(latencyLevel) || _atLeastWarn(lossLevel);

  /// A low frame rate on a screen that is not changing (Sürüm 10 #118, denetim K44): the same
  /// rule as Ekran bilgisi ([senseStillScreen]) — good link and hardly any picture data or an
  /// old last frame.
  bool get still => senseStillScreen(
        fps: fps,
        rttMs: rttMs,
        lossPct: lossPct,
        mbit: bandwidthMbit,
        frameAgeMs: frameAge?.inMilliseconds,
      );

  /// Frame-rate level as shown on the card's tile: a still screen is not a warning (K44).
  SenseLevel get fpsShownLevel => still ? SenseLevel.ok : fpsLevel;

  /// Frame rate under the weak card's limit. 0 fps is a still screen (D1: no frame is
  /// sent while probes keep coming) and does not count; neither does a low rate on a still
  /// screen ([still], K44). The karar #94 limits themselves are unchanged.
  bool get fpsWeak {
    final f = fps;
    return f != null && f > 0 && f < SenseLinkTiming.weakFpsBelow && !still;
  }

  static bool _atLeastWarn(SenseLevel l) => l == SenseLevel.warn || l == SenseLevel.hot;
}

enum SenseLinkPhase { normal, weak, lost }

/// What the screen shows after a tick.
class SenseLinkView {
  const SenseLinkView({
    required this.phase,
    required this.sample,
    this.wavy = false,
    this.recoveringIn,
    this.stall = Duration.zero,
    this.dropped = false,
    this.retries = 0,
    this.lostFor,
  });

  static const SenseLinkView initial =
      SenseLinkView(phase: SenseLinkPhase.normal, sample: SenseLinkSample());

  final SenseLinkPhase phase;
  final SenseLinkSample sample;

  /// Bad values but no layer yet: the top bar says "Dalgalı".
  final bool wavy;

  /// Layer up and values good again: seconds until it goes.
  final int? recoveringIn;

  /// How long the picture has been missing (lost layer text).
  final Duration stall;

  /// Stalled for [SenseLinkTiming.drop]: the session is over.
  final bool dropped;

  /// Sürüm 11 (O1): reconnect attempts really made since the transport was lost.
  final int retries;

  /// Time since the transport was lost (null = not lost); the session closes
  /// [SenseLinkTiming.drop] after that.
  final Duration? lostFor;

  bool get layerUp => phase != SenseLinkPhase.normal && !dropped;

  int get stallSeconds => stall.inSeconds;

  /// Sürüm 11 (O1): the reconnect attempt the card shows — the real ones (0 = none yet).
  int get attempt => retries;

  int get closeIn {
    final s = SenseLinkTiming.drop.inSeconds - (lostFor ?? stall).inSeconds;
    return s < 0 ? 0 : s;
  }
}

/// Events of one tick the controller reacts to.
enum SenseLinkEvent { none, recovered, dropped }

class SenseLinkMachine {
  SenseLinkMachine();

  SenseLinkPhase _phase = SenseLinkPhase.normal;
  Duration? _badSince;
  Duration? _goodSince;
  bool _dropped = false;
  Duration? _transportLostAt;
  SenseLinkView _view = SenseLinkView.initial;
  SenseLinkEvent _event = SenseLinkEvent.none;

  SenseLinkView get view => _view;

  /// Sürüm 11 (O1): reconnect attempts made in this outage (the controller sets it).
  int retries = 0;

  /// Sürüm 11 (O1): a delay probe came after the loss (the controller sets it each tick).
  /// The last values before a reset still look fresh for a second; they do not bring the
  /// transport back.
  bool freshData = true;

  /// The transport is reported lost and has not come back yet.
  bool get transportDown => _transportLostAt != null;

  /// What happened on the last tick.
  SenseLinkEvent get lastEvent => _event;

  /// RustDesk reports the transport gone (`restarting-show`): "Bağlantı kesildi" now;
  /// the session closes when no data comes for [SenseLinkTiming.drop].
  void transportLost(Duration now) => _transportLostAt ??= now;

  /// Starts over (after a reconnect).
  void reset() {
    _transportLostAt = null;
    retries = 0;
    _phase = SenseLinkPhase.normal;
    _badSince = null;
    _goodSince = null;
    _dropped = false;
    _view = SenseLinkView.initial;
    _event = SenseLinkEvent.none;
  }

  SenseLinkView tick(Duration now, SenseLinkSample s) {
    _event = SenseLinkEvent.none;
    if (_dropped) return _view;

    var stall = s.stall;
    final lostAt = _transportLostAt;
    if (lostAt != null) {
      if (stall < SenseLinkTiming.tick && now > lostAt && freshData) {
        // Data flows again: the transport is back.
        _transportLostAt = null;
      } else if (now - lostAt > stall) {
        stall = now - lostAt;
      }
    }
    final lostNow = _transportLostAt != null;
    final lostFor = lostNow ? now - _transportLostAt! : null;
    // Short shake for the bar word: bad values or a missing picture for a second.
    final shake = s.valuesBad || stall >= SenseLinkTiming.tick;
    // The weak card only cares about the frame rate.
    final weakBad = s.fpsWeak;

    if (weakBad || lostNow) {
      _goodSince = null;
      _badSince ??= now;
    } else {
      _badSince = null;
      _goodSince ??= now;
    }

    // Sürüm 11 (O1): with the transport lost, the reconnect attempts get the full window.
    if (lostFor != null ? lostFor >= SenseLinkTiming.drop : stall >= SenseLinkTiming.drop) {
      _dropped = true;
      _event = SenseLinkEvent.dropped;
      _view = SenseLinkView(
          phase: SenseLinkPhase.lost,
          sample: s,
          stall: stall,
          dropped: true,
          retries: retries,
          lostFor: lostFor);
      return _view;
    }

    switch (_phase) {
      case SenseLinkPhase.normal:
        if (lostNow) {
          _phase = SenseLinkPhase.lost;
        } else if (weakBad && now - _badSince! >= SenseLinkTiming.showWeak) {
          _phase = SenseLinkPhase.weak;
        }
      case SenseLinkPhase.weak:
      case SenseLinkPhase.lost:
        if (lostNow) {
          _phase = SenseLinkPhase.lost;
        } else if (!weakBad && now - _goodSince! >= SenseLinkTiming.hideOk) {
          _phase = SenseLinkPhase.normal;
          _event = SenseLinkEvent.recovered;
        }
    }

    int? recoveringIn;
    if (_phase != SenseLinkPhase.normal && !weakBad && !lostNow && _goodSince != null) {
      final left = SenseLinkTiming.hideOk - (now - _goodSince!);
      final secs = (left.inMilliseconds / 1000).ceil();
      recoveringIn = secs < 1 ? 1 : secs;
    }

    _view = SenseLinkView(
      phase: _phase,
      sample: s,
      wavy: _phase == SenseLinkPhase.normal && shake,
      recoveringIn: recoveringIn,
      stall: stall,
      retries: lostNow ? retries : 0,
      lostFor: lostFor,
    );
    return _view;
  }
}

/// Sürüm 11 (O1): when the next reconnect attempt goes out while the transport is lost.
/// First one [SenseLinkTiming.retryFirst] after the loss, then 2, 4, 8, 8 … s apart. Pure.
class SenseRetryPlan {
  Duration? _since;
  Duration? _last;
  int _attempts = 0;

  bool get active => _since != null;
  int get attempts => _attempts;

  void begin(Duration now) => _since ??= now;

  void stop() {
    _since = null;
    _last = null;
    _attempts = 0;
  }

  /// True = make one attempt now (it is counted).
  bool due(Duration now) {
    final since = _since;
    if (since == null) return false;
    final last = _last;
    final next = last == null ? since + SenseLinkTiming.retryFirst : last + gapAfter(_attempts);
    if (now < next) return false;
    _attempts++;
    _last = now;
    return true;
  }

  /// Wait after attempt [n] (1-based): 2, 4, 8, 8 … s.
  static Duration gapAfter(int n) {
    final s = n <= 1 ? 2 : (n == 2 ? 4 : 8);
    final capped = Duration(seconds: s);
    return capped > SenseLinkTiming.retryMaxGap ? SenseLinkTiming.retryMaxGap : capped;
  }
}
