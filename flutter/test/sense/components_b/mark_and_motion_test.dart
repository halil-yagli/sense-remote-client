// Sense Remote (A2b): Sense mark (T5), breathe / blink pulses and the glow
// scene (T4, T1). Each animation is checked at a middle frame; nothing turns.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/components_b.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'support.dart';

double _opacityOf(WidgetTester tester, Finder child) {
  final o = tester.widget<Opacity>(find.ancestor(of: child, matching: find.byType(Opacity)).first);
  return o.opacity;
}

void main() {
  group('SenseMark (T5)', () {
    test('ships the transparent mark files, with no plate or frame', () {
      for (final f in ['mark_white', 'mark_black', 'mark_half']) {
        final svg = File('assets/sense/$f.svg').readAsStringSync();
        expect(svg, contains('<path'));
        expect(svg, isNot(contains('<rect')), reason: '$f has a plate');
        expect(svg, isNot(contains('<circle')), reason: '$f has a plate');
      }
      expect(File('assets/sense/mark_half.svg').readAsStringSync(),
          contains('viewBox="410 180 260 350"'));
    });

    testWidgets('draws at the asked size; decorative unless labelled', (tester) async {
      await tester.pumpWidget(app(const Center(child: SenseMark())));
      expect(tester.getSize(find.byType(SenseMark)), const Size(72, 66));
      expect(find.bySemanticsLabel('Sense'), findsNothing);

      await tester.pumpWidget(app(const Center(
          child: SenseMark(width: 26, height: 24, shape: SenseMarkShape.half, semanticLabel: 'Sense'))));
      expect(tester.getSize(find.byType(SenseMark)), const Size(26, 24));
      expect(find.bySemanticsLabel('Sense'), findsOneWidget);
    });

    test('the two halves are the same shape turned half a turn', () {
      final r = SenseMarkPainter.rightHalf().getBounds();
      final l = SenseMarkPainter.leftHalf().getBounds();
      expect(r.width, closeTo(l.width, 0.01));
      expect(r.height, closeTo(l.height, 0.01));
      // Centres mirror around the Drive page centre (420.945, 297.64).
      expect(r.center.dx + l.center.dx, closeTo(841.89, 0.05));
      expect(r.center.dy + l.center.dy, closeTo(595.28, 0.05));
    });

    testWidgets('golden: white, black on white, half', (tester) async {
      await tester.pumpWidget(app(sample(
        width: 300,
        const Row(children: [
          SenseMark(),
          SizedBox(width: 16),
          ColoredBox(color: SenseColors.text, child: SenseMark(color: SenseColors.bg)),
          SizedBox(width: 16),
          SenseMark(width: 26, height: 35, shape: SenseMarkShape.half),
        ]),
      )));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('sense_mark')));
    }, skip: goldenSkip('sense_mark'), tags: const ['golden']);
  });

  group('pulses (T4)', () {
    test('keyframe opacity: full at the ends, lowest in the middle', () {
      const min = SenseMotionParams.breatheOpacityMin;
      final c = SenseMotion.breatheFast.curve;
      expect(sensePulseOpacity(0, min: min, curve: c), 1);
      expect(sensePulseOpacity(0.5, min: min, curve: c), closeTo(min, 1e-9));
      expect(sensePulseOpacity(1, min: min, curve: c), 1);
      final quarter = sensePulseOpacity(0.25, min: min, curve: c);
      expect(quarter, inExclusiveRange(min, 1));
      expect(sensePulseOpacity(0.75, min: min, curve: c), closeTo(quarter, 1e-9));
    });

    test('durations are inside the T4 ranges', () {
      expect(SenseMotion.breatheFast.duration, const Duration(milliseconds: 2200));
      expect(SenseMotion.breathe.duration.inMilliseconds, inInclusiveRange(2200, 2400));
      for (final s in [SenseMotion.blink, SenseMotion.blinkFast, SenseMotion.blinkSlow]) {
        expect(s.duration.inMilliseconds, inInclusiveRange(1000, 1400));
        expect(s.repeat, isTrue);
      }
    });

    testWidgets('breathe: 1 → 0.55 at 1.1 s → 1 at 2.2 s, repeats', (tester) async {
      const key = Key('b');
      await tester.pumpWidget(app(const Center(child: SenseBreathe(child: SizedBox(key: key, width: 10, height: 10)))));
      expect(_opacityOf(tester, find.byKey(key)), 1);
      await tester.pump(const Duration(milliseconds: 550));
      final mid = _opacityOf(tester, find.byKey(key));
      expect(mid, inExclusiveRange(0.55, 1));
      await tester.pump(const Duration(milliseconds: 550));
      expect(_opacityOf(tester, find.byKey(key)), closeTo(0.55, 0.01));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(_opacityOf(tester, find.byKey(key)), closeTo(1, 0.01));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(_opacityOf(tester, find.byKey(key)), closeTo(0.55, 0.01), reason: 'loops');
      expectNoRotation(tester);
    });

    testWidgets('blink: 1 → 0.3 at half of 1.2 s', (tester) async {
      const key = Key('d');
      await tester.pumpWidget(app(const Center(child: SenseBlink(child: SizedBox(key: key, width: 8, height: 8)))));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_opacityOf(tester, find.byKey(key)), inExclusiveRange(0.3, 1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_opacityOf(tester, find.byKey(key)), closeTo(0.3, 0.01));
      expectNoRotation(tester);
    });

    testWidgets('stand still when the system turns animations off', (tester) async {
      const key = Key('s');
      await tester.pumpWidget(app(
        const Center(child: SenseBreathe(child: SizedBox(key: key, width: 10, height: 10))),
        disableAnimations: true,
      ));
      await tester.pump(const Duration(milliseconds: 1100));
      expect(_opacityOf(tester, find.byKey(key)), 1);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('status dot blinks only when asked', (tester) async {
      await tester.pumpWidget(app(const Center(child: SenseStatusDot())));
      expect(find.byType(SenseBlink), findsNothing);
      await tester.pumpWidget(app(const Center(child: SenseStatusDot(blinking: true))));
      expect(find.byType(SenseBlink), findsOneWidget);
    });
  });

  group('SenseGlowScene (T1)', () {
    testWidgets('fills its box, black at the corners', (tester) async {
      setWindow(tester, const Size(400, 300));
      await tester.pumpWidget(app(const SenseGlowScene()));
      expect(tester.getSize(find.byType(SenseGlowScene)), const Size(400, 300));
      final p = tester.widget<CustomPaint>(
          find.descendant(of: find.byType(SenseGlowScene), matching: find.byType(CustomPaint)).first);
      expect((p.painter! as SenseGlowPainter).spots, SenseGlowScene.splashSpots);
      expect(SenseGlowScene.splashSpots.single.color, SenseColors.glowStart);
    });

    testWidgets('golden: splash and scene', (tester) async {
      setWindow(tester, const Size(660, 220));
      await tester.pumpWidget(app(const RepaintBoundary(
        key: Key('golden'),
        child: Row(children: [
          SizedBox(width: 320, height: 200, child: SenseGlowScene()),
          SizedBox(width: 20),
          SizedBox(width: 320, height: 200, child: SenseGlowScene(style: SenseGlowStyle.scene)),
        ]),
      )));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('glow_scene')));
    }, skip: goldenSkip('glow_scene'), tags: const ['golden']);
  });
}
