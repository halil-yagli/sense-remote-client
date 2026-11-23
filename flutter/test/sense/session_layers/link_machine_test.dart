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

  group('weak', () {
    test('bad 5 s without a break: weak layer', () {
      final r = _Run();
      var v = r.steps(5, _bad); // seconds 0..4
      expect(v.phase, SenseLinkPhase.normal, reason: '4 s since the first bad tick');
      v = r.step(_bad); // second 5
      expect(v.phase, SenseLinkPhase.weak);
      expect(v.layerUp, isTrue);
      expect(v.wavy, isFalse, reason: 'the layer is up; the bar word is for the short shake');
      expect(v.recoveringIn, isNull);
      expect(v.sample.rttMs, 272);
    });

    test('good 3 s: "toparlandı" counts down, then the layer goes once', () {
      final r = _Run();
      r.steps(6, _bad);
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

    test('bad again while recovering: the 3 s start over', () {
      final r = _Run();
      r.steps(6, _bad);
      r.steps(2, _good);
      var v = r.step(_bad);
      expect(v.recoveringIn, isNull);
      expect(v.phase, SenseLinkPhase.weak);
      v = r.steps(3, _good);
      expect(v.phase, SenseLinkPhase.weak);
      v = r.step(_good);
      expect(v.phase, SenseLinkPhase.normal);
    });
  });

  group('lost', () {
    test('3 s without picture and probe: lost layer', () {
      final r = _Run();
      r.steps(2, _good);
      var v = r.step(_frozen(2));
      expect(v.layerUp, isFalse);
      v = r.step(_frozen(4));
      expect(v.phase, SenseLinkPhase.lost);
      expect(v.stallSeconds, 3);
    });

    test('weak turns lost when the picture stops', () {
      final r = _Run();
      r.steps(6, _bad);
      expect(r.m.view.phase, SenseLinkPhase.weak);
      final v = r.step(_frozen(4));
      expect(v.phase, SenseLinkPhase.lost);
    });

    test('lost text: attempt every 4 s and seconds to the 30 s close', () {
      final r = _Run();
      var v = r.step(_frozen(9));
      expect(v.phase, SenseLinkPhase.lost);
      expect(v.stallSeconds, 8);
      expect(v.attempt, 3, reason: '8.98 s / 4 s, rounded up');
      expect(v.closeIn, 22);
      v = r.step(_frozen(4));
      expect(v.attempt, 1);
    });

    test('back after an outage: 3 s good, then normal', () {
      final r = _Run();
      r.step(_frozen(5));
      var v = r.step(_good);
      expect(v.phase, SenseLinkPhase.lost);
      expect(v.recoveringIn, 3);
      v = r.steps(3, _good);
      expect(v.phase, SenseLinkPhase.normal);
      expect(r.m.lastEvent, SenseLinkEvent.recovered);
    });

    test('30 s stalled: dropped once, then the machine stays put', () {
      final r = _Run();
      r.step(_frozen(29));
      expect(r.m.lastEvent, SenseLinkEvent.none);
      final v = r.step(_frozen(32));
      expect(v.dropped, isTrue);
      expect(v.layerUp, isFalse, reason: 'the ended card takes over');
      expect(r.m.lastEvent, SenseLinkEvent.dropped);
      r.step(_good);
      expect(r.m.lastEvent, SenseLinkEvent.none);
      expect(r.m.view.dropped, isTrue);
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
    m.tick(Duration.zero, _bad);
    expect(m.tick(const Duration(milliseconds: 4900), _bad).phase, SenseLinkPhase.normal);
    expect(m.tick(const Duration(seconds: 5), _bad).phase, SenseLinkPhase.weak);
  });
}
