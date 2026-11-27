// Sense Remote: O13 state machine (YH O13 kabul testi; TK7). Time is fake: every
// tick passes its own "now", one second apart, like the real 1 s timer.
import 'package:flutter_hbb/sense/screens/session/layers/link_machine.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

const _good = SenseLinkSample(
  rttMs: 20,
  lossPct: 0.1,
  fps: 60,
  frameAge: Duration(milliseconds: 16),
  probeAge: Duration(milliseconds: 400),
);

const _bad = SenseLinkSample(
  rttMs: 272,
  lossPct: 5.1,
  fps: 8,
  frameAge: Duration(milliseconds: 120),
  probeAge: Duration(milliseconds: 900),
);

/// Low frame rate on an otherwise answering link: the weak card's one condition.
const _weakFps = SenseLinkSample(
  rttMs: 20,
  lossPct: 0.1,
  fps: 3,
  frameAge: Duration(milliseconds: 300),
  probeAge: Duration(milliseconds: 400),
);

/// No picture and no probe for [s] seconds.
SenseLinkSample _frozen(int s) => SenseLinkSample(
      rttMs: 20,
      fps: 0,
      frameAge: Duration(seconds: s),
      // The probe due one second after the last answer is [s] seconds late.
      probeAge: Duration(seconds: s + 1),
    );

class _Run {
  final m = SenseLinkMachine();
  int t = 0;
  final events = <SenseLinkEvent>[];

  SenseLinkView step(SenseLinkSample s) {
    final v = m.tick(Duration(seconds: t++), s);
    events.add(m.lastEvent);
    return v;
  }

  SenseLinkView steps(int n, SenseLinkSample s) {
    late SenseLinkView v;
    for (var i = 0; i < n; i++) {
      v = step(s);
    }
    return v;
  }
}

void main() {
  group('stall: no picture and no probe', () {
    test('a still screen sends no frame but the probes keep coming: no stall', () {
      const still = SenseLinkSample(
          rttMs: 20, fps: 0, frameAge: Duration(seconds: 40), probeAge: Duration(milliseconds: 800));
      expect(still.stall, Duration.zero);
    });

    test('frames flowing while probes are late: no stall', () {
      const s = SenseLinkSample(
          rttMs: 20, fps: 30, frameAge: Duration(milliseconds: 30), probeAge: Duration(seconds: 6));
      expect(s.stall, const Duration(milliseconds: 30));
    });

    test('both stopped: the shorter of frame age and probe lateness', () {
      expect(_frozen(5).stall, const Duration(seconds: 5) - const Duration(milliseconds: 20));
    });

    test('the round trip is part of the probe wait', () {
      const s = SenseLinkSample(
          rttMs: 500, frameAge: Duration(seconds: 9), probeAge: Duration(milliseconds: 1400));
      expect(s.stall, Duration.zero);
    });

    test('no probe data: never stalled (nothing is guessed)', () {
      const s = SenseLinkSample(frameAge: Duration(seconds: 60));
      expect(s.stall, Duration.zero);
    });
  });

  group('values', () {
    test('latency and loss above the limits are bad', () {
      expect(_good.valuesBad, isFalse);
      expect(_bad.valuesBad, isTrue);
      expect(const SenseLinkSample(rttMs: 150).valuesBad, isTrue, reason: '150 ms is the limit');
      expect(const SenseLinkSample(rttMs: 149).valuesBad, isFalse);
      expect(const SenseLinkSample(lossPct: 2).valuesBad, isTrue);
      expect(const SenseLinkSample(lossPct: 1.9).valuesBad, isFalse);
    });

    test('a low frame rate alone is not bad (still screen) but its tile is coloured', () {
      const s = SenseLinkSample(rttMs: 20, lossPct: 0, fps: 3);
      expect(s.valuesBad, isFalse);
      expect(s.fpsLevel, SenseLevel.hot);
      expect(const SenseLinkSample(fps: 12).fpsLevel, SenseLevel.warn);
      expect(const SenseLinkSample(fps: 15).fpsLevel, SenseLevel.ok);
    });

    test('levels follow the tokens', () {
      expect(_bad.latencyLevel, SenseLevel.warn);
      expect(_bad.lossLevel, SenseLevel.hot);
      expect(const SenseLinkSample(rttMs: 300).latencyLevel, SenseLevel.hot);
      expect(const SenseLinkSample().latencyLevel, SenseLevel.unknown);
    });
  });

  group('short shake', () {
    test('2 s bad: no layer, only "Dalgalı"', () {
      final r = _Run();
      r.steps(3, _good);
      var v = r.steps(2, _bad);
      expect(v.layerUp, isFalse);
      expect(v.wavy, isTrue);
      v = r.step(_good);
      expect(v.layerUp, isFalse);
      expect(v.wavy, isFalse);
      expect(r.events, everyElement(SenseLinkEvent.none));
    });

    test('4 s bad then good: still no layer', () {
      final r = _Run();
      r.steps(4, _bad);
      final v = r.steps(10, _good);
      expect(v.phase, SenseLinkPhase.normal);
      expect(r.events, everyElement(SenseLinkEvent.none));
    });

    test('a single good second starts the 5 s over', () {
      final r = _Run();
      r.steps(4, _bad);
      r.step(_good);
      final v = r.steps(4, _bad);
      expect(v.phase, SenseLinkPhase.normal);
    });

    test('2 s frozen: no layer, "Dalgalı"', () {
      final r = _Run();
      r.step(_good);
      final v = r.step(_frozen(2));
      expect(v.layerUp, isFalse);
      expect(v.wavy, isTrue);
    });
  });

  group('weak (karar #94: fps < 5 for 15 s)', () {
    test('fps 3: 14 s no card, 16 s the card', () {
      final r = _Run();
      var v = r.steps(15, _weakFps); // seconds 0..14
      expect(v.phase, SenseLinkPhase.normal, reason: '14 s since the first low second');
      expect(v.layerUp, isFalse);
      v = r.step(_weakFps); // second 15
      expect(v.phase, SenseLinkPhase.weak);
      expect(v.layerUp, isTrue);
      expect(v.wavy, isFalse);
      expect(v.recoveringIn, isNull);
    });

    test('high delay (900 ms) with fps 20 never opens the card', () {
      final r = _Run();
      const slowButAlive = SenseLinkSample(
          rttMs: 900, lossPct: 0.1, fps: 20, frameAge: Duration(milliseconds: 30), probeAge: Duration(seconds: 2));
      final v = r.steps(120, slowButAlive);
      expect(v.layerUp, isFalse);
      expect(v.wavy, isTrue, reason: 'the bar still says Dalgalı');
      expect(r.events, everyElement(SenseLinkEvent.none));
    });

    test('high loss alone never opens the card', () {
      final r = _Run();
      final v = r.steps(
          120,
          const SenseLinkSample(
              rttMs: 20, lossPct: 5.1, fps: 30, frameAge: Duration(milliseconds: 30), probeAge: Duration(milliseconds: 400)));
      expect(v.layerUp, isFalse);
    });

    test('0 fps (still screen, probes answer) is not weak', () {
      final r = _Run();
      final v = r.steps(60, const SenseLinkSample(
          rttMs: 20, lossPct: 0, fps: 0, frameAge: Duration(seconds: 40), probeAge: Duration(milliseconds: 800)));
      expect(v.layerUp, isFalse);
    });

    test('a single good second starts the 15 s over', () {
      final r = _Run();
      r.steps(14, _weakFps);
      r.step(_good);
      final v = r.steps(14, _weakFps);
      expect(v.phase, SenseLinkPhase.normal);
    });

    test('good 3 s: "toparlandı" counts down, then the layer goes once', () {
      final r = _Run();
      r.steps(16, _weakFps);
      var v = r.step(_good);
      expect(v.phase, SenseLinkPhase.weak);
      expect(v.recoveringIn, 3);
      v = r.step(_good);
      expect(v.recoveringIn, 2);
      v = r.step(_good);
      expect(v.recoveringIn, 1);
      v = r.step(_good);
      expect(v.phase, SenseLinkPhase.normal);
      expect(r.m.lastEvent, SenseLinkEvent.recovered);
      r.step(_good);
      expect(r.m.lastEvent, SenseLinkEvent.none);
      expect(r.events.where((e) => e == SenseLinkEvent.recovered), hasLength(1));
    });

    test('low again while recovering: the 3 s start over', () {
      final r = _Run();
      r.steps(16, _weakFps);
      r.steps(2, _good);
      var v = r.step(_weakFps);
      expect(v.recoveringIn, isNull);
      expect(v.phase, SenseLinkPhase.weak);
      v = r.steps(3, _good);
      expect(v.phase, SenseLinkPhase.weak);
      v = r.step(_good);
      expect(v.phase, SenseLinkPhase.normal);
    });
  });

  group('lost and dropped (karar #94)', () {
    test('29 s without frame and probe: no card, no drop', () {
      final r = _Run();
      r.step(_good);
      final v = r.step(_frozen(29));
      expect(v.layerUp, isFalse);
      expect(v.dropped, isFalse);
      expect(r.m.lastEvent, SenseLinkEvent.none);
      expect(v.wavy, isTrue, reason: 'the bar warns');
    });

    test('31 s without frame and probe: lost, dropped once, then the machine stays put', () {
      final r = _Run();
      r.step(_frozen(29));
      expect(r.m.lastEvent, SenseLinkEvent.none);
      final v = r.step(_frozen(31));
      expect(v.dropped, isTrue);
      expect(v.phase, SenseLinkPhase.lost);
      expect(v.layerUp, isFalse, reason: 'the ended card takes over');
      expect(r.m.lastEvent, SenseLinkEvent.dropped);
      r.step(_good);
      expect(r.m.lastEvent, SenseLinkEvent.none);
      expect(r.m.view.dropped, isTrue);
    });

    test('data keeps coming: the machine never drops', () {
      final r = _Run();
      r.steps(600, _weakFps);
      r.steps(600, _bad);
      expect(r.m.view.dropped, isFalse);
      expect(r.events, isNot(contains(SenseLinkEvent.dropped)));
    });

    // Sürüm 11 (O1): the card counts real attempts (set by the controller), and the session
    // closes 30 s after the transport was lost.
    test('transport lost: the lost card shows at once, text counts real attempts', () {
      final r = _Run();
      r.m.transportLost(Duration.zero);
      var v = r.step(_frozen(9));
      expect(v.phase, SenseLinkPhase.lost);
      expect(v.layerUp, isTrue);
      expect(v.stallSeconds, 8);
      expect(v.attempt, 0, reason: 'no attempt made yet; nothing is counted from the time');
      expect(v.closeIn, 30);
      r.m.retries = 2;
      v = r.step(_frozen(10));
      expect(v.attempt, 2);
      expect(v.closeIn, 29);
    });

    test('retry plan: first after 1 s, then 2, 4, 8, 8 s apart', () {
      final p = SenseRetryPlan();
      expect(p.due(const Duration(seconds: 5)), isFalse, reason: 'not begun');
      p.begin(Duration.zero);
      final at = <int>[];
      for (var s = 0; s <= 40; s++) {
        if (p.due(Duration(seconds: s))) at.add(s);
      }
      expect(at, [1, 3, 7, 15, 23, 31, 39]);
      expect(p.attempts, 7);
      p.stop();
      expect(p.active, isFalse);
      expect(p.attempts, 0);
    });

    test('transport lost without data: dropped after 30 s', () {
      final r = _Run();
      r.m.transportLost(Duration.zero);
      var v = r.steps(30, _frozen(2)); // seconds 0..29
      expect(v.dropped, isFalse);
      v = r.step(_frozen(2)); // second 30
      expect(v.dropped, isTrue);
    });

    test('transport lost but data flows again: 3 s good, then normal, never dropped', () {
      final r = _Run();
      r.step(_good);
      r.m.transportLost(const Duration(seconds: 1));
      var v = r.step(_frozen(2));
      expect(v.phase, SenseLinkPhase.lost);
      v = r.step(_good);
      expect(v.phase, SenseLinkPhase.lost);
      expect(v.recoveringIn, 3);
      v = r.steps(3, _good);
      expect(v.phase, SenseLinkPhase.normal);
      expect(r.m.lastEvent, SenseLinkEvent.recovered);
      r.steps(120, _good);
      expect(r.m.view.dropped, isFalse);
    });

    test('reset after a reconnect starts clean', () {
      final r = _Run();
      r.step(_frozen(31));
      r.m.reset();
      final v = r.step(_good);
      expect(v.phase, SenseLinkPhase.normal);
      expect(v.dropped, isFalse);
    });
  });

  test('ticks with uneven gaps still use the clock, not the tick count', () {
    final m = SenseLinkMachine();
    m.tick(Duration.zero, _weakFps);
    expect(m.tick(const Duration(milliseconds: 14900), _weakFps).phase, SenseLinkPhase.normal);
    expect(m.tick(const Duration(seconds: 15), _weakFps).phase, SenseLinkPhase.weak);
  });

  group('still screen (Sürüm 10 #118, denetim K44: same rule as Ekran bilgisi)', () {
    // Good link, a few frames a second, hardly any picture data: the screen is not changing.
    const stillLowData = SenseLinkSample(
      rttMs: 5,
      lossPct: 0,
      fps: 2,
      frameAge: Duration(milliseconds: 300),
      probeAge: Duration(milliseconds: 400),
      bandwidthMbit: 0.1,
    );
    // Good link, last frame 2.5 s old: nothing changed since.
    const stillOldFrame = SenseLinkSample(
      rttMs: 5,
      lossPct: 0,
      fps: 2,
      frameAge: Duration(milliseconds: 2500),
      probeAge: Duration(milliseconds: 400),
    );

    test('fps 2 on a still screen for 30 s never opens the weak card', () {
      for (final s in [stillLowData, stillOldFrame]) {
        final r = _Run();
        final v = r.steps(30, s);
        expect(v.phase, SenseLinkPhase.normal);
        expect(v.layerUp, isFalse);
        expect(s.still, isTrue);
        expect(s.fpsWeak, isFalse);
      }
    });

    test('the card tile is not coloured for a still screen, the raw level stays', () {
      expect(stillLowData.fpsShownLevel, SenseLevel.ok);
      expect(stillLowData.fpsLevel, SenseLevel.hot);
      expect(_weakFps.fpsShownLevel, SenseLevel.hot);
    });

    test('real weakness keeps the karar #94 card: lots of data, or a bad link', () {
      const busy = SenseLinkSample(
          rttMs: 5, lossPct: 0, fps: 2, frameAge: Duration(milliseconds: 300),
          probeAge: Duration(milliseconds: 400), bandwidthMbit: 6);
      const slow = SenseLinkSample(
          rttMs: 200, lossPct: 0, fps: 2, frameAge: Duration(milliseconds: 2500),
          probeAge: Duration(milliseconds: 400), bandwidthMbit: 0.1);
      const lossy = SenseLinkSample(
          rttMs: 5, lossPct: 3, fps: 2, frameAge: Duration(milliseconds: 300),
          probeAge: Duration(milliseconds: 400), bandwidthMbit: 0.1);
      for (final s in [busy, slow, lossy, _weakFps]) {
        expect(s.still, isFalse);
        final r = _Run();
        expect(r.steps(16, s).phase, SenseLinkPhase.weak);
      }
    });

    test('the open weak card goes once the screen turns out to be still', () {
      final r = _Run();
      expect(r.steps(16, _weakFps).phase, SenseLinkPhase.weak);
      final v = r.steps(4, stillLowData);
      expect(v.phase, SenseLinkPhase.normal);
      expect(r.m.lastEvent, SenseLinkEvent.recovered);
    });
  });
}
