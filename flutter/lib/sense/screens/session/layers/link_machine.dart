// Sense Remote: connection problem state machine (YH O13; TK7). Pure Dart.
//
// It runs on its own one-second tick ([SenseLinkTiming.tick]) because a frozen link
// sends no event at all. Every tick it gets the latest [SenseLinkSample] and the
// current time (a monotonic clock; tests pass a fake one).
//
//   normal ── bad 5 s without a break ──▶ weak
//   normal / weak ── no picture 3 s ──▶ lost
//   weak / lost ── good 3 s without a break ──▶ normal  (+ "Bağlantı düzeldi")
//   any ── stalled 30 s ──▶ dropped (the session closes; O14 "Uzak bilgisayar…")
//
// A short shake shows no layer; the top bar says "Dalgalı" ([SenseLinkView.wavy]).
import '../../../tokens/sense_tokens.dart';
import 'layer_spec.dart';

/// What the link looks like at one moment. Null = not known (not measured yet).
class SenseLinkSample {
  const SenseLinkSample({
    this.rttMs,
    this.lossPct,
    this.fps,
    this.frameAge,
    this.probeAge,
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

  bool get layerUp => phase != SenseLinkPhase.normal && !dropped;

  int get stallSeconds => stall.inSeconds;

  /// Prototype: one reconnect attempt per 4 s of the outage, at least 1.
  int get attempt {
    final n = (stall.inMilliseconds / SenseLinkTiming.attemptEvery.inMilliseconds).ceil();
    return n < 1 ? 1 : n;
  }

  int get closeIn {
    final s = SenseLinkTiming.drop.inSeconds - stallSeconds;
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
  SenseLinkView _view = SenseLinkView.initial;
  SenseLinkEvent _event = SenseLinkEvent.none;

  SenseLinkView get view => _view;

  /// What happened on the last tick.
  SenseLinkEvent get lastEvent => _event;

  /// Starts over (after a reconnect).
  void reset() {
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

    final stall = s.stall;
    final lostNow = stall >= SenseLinkTiming.showLost;
    // Late probes or a missing picture for a second are already "bad".
    final bad = s.valuesBad || stall >= SenseLinkTiming.tick;

    if (bad) {
      _goodSince = null;
      _badSince ??= now;
    } else {
      _badSince = null;
      _goodSince ??= now;
    }

    if (stall >= SenseLinkTiming.drop) {
      _dropped = true;
      _event = SenseLinkEvent.dropped;
      _view = SenseLinkView(
          phase: SenseLinkPhase.lost, sample: s, stall: stall, dropped: true);
      return _view;
    }

    switch (_phase) {
      case SenseLinkPhase.normal:
        if (lostNow) {
          _phase = SenseLinkPhase.lost;
        } else if (bad && now - _badSince! >= SenseLinkTiming.showWeak) {
          _phase = SenseLinkPhase.weak;
        }
      case SenseLinkPhase.weak:
      case SenseLinkPhase.lost:
        if (lostNow) {
          _phase = SenseLinkPhase.lost;
        } else if (!bad && now - _goodSince! >= SenseLinkTiming.hideOk) {
          _phase = SenseLinkPhase.normal;
          _event = SenseLinkEvent.recovered;
        }
    }

    int? recoveringIn;
    if (_phase != SenseLinkPhase.normal && !bad && _goodSince != null) {
      final left = SenseLinkTiming.hideOk - (now - _goodSince!);
      final secs = (left.inMilliseconds / 1000).ceil();
      recoveringIn = secs < 1 ? 1 : secs;
    }

    _view = SenseLinkView(
      phase: _phase,
      sample: s,
      wavy: _phase == SenseLinkPhase.normal && bad,
      recoveringIn: recoveringIn,
      stall: stall,
    );
    return _view;
  }
}
