// Sense Remote (A2b): opening screen (YH T8, img/a08.png).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/components_b.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'support.dart';

void main() {
  testWidgets('black ground with the navy glow, mark, text and loading line', (tester) async {
    setWindow(tester, const Size(1280, 720));
    await tester.pumpWidget(app(const SenseSplash()));
    expect(find.byType(SenseGlowScene), findsOneWidget);
    expect(tester.widget<SenseGlowScene>(find.byType(SenseGlowScene)).style, SenseGlowStyle.splash);
    expect(find.byKey(const Key('sense-splash-mark')), findsOneWidget);
    expect(find.text('Sense Remote açılıyor'), findsOneWidget);
    final text = tester.widget<Text>(find.byKey(const Key('sense-splash-text')));
    expect(text.style!.color, SenseColors.textMuted);
    expect(tester.getSize(find.byKey(const Key('sense-loading-line'))), const Size(140, 2));

    // Mark, text and line are centred under each other.
    final mark = tester.getCenter(find.byKey(const Key('sense-splash-mark')));
    final line = tester.getCenter(find.byKey(const Key('sense-loading-line')));
    expect(mark.dx, closeTo(640, 0.5));
    expect(line.dx, closeTo(640, 0.5));
    expect(line.dy, greaterThan(mark.dy));
  });

  testWidgets('after an update: "Sürüm N kuruluyor · Sense Remote yeniden açılıyor"', (tester) async {
    await tester.pumpWidget(app(const SenseSplash(updatingToVersion: 5)));
    expect(find.text('Sürüm 5 kuruluyor · Sense Remote yeniden açılıyor'), findsOneWidget);
    expect(find.text('Sense Remote açılıyor'), findsNothing);
  });

  testWidgets('fades in over 0.3 s, mark breathes over 2.2 s, nothing turns', (tester) async {
    await tester.pumpWidget(app(const SenseSplash()));
    FadeTransition fade() => tester.widget<FadeTransition>(
        find.ancestor(of: find.byType(SenseGlowScene), matching: find.byType(FadeTransition)).first);
    expect(fade().opacity.value, 0);
    await tester.pump(const Duration(milliseconds: 150));
    expect(fade().opacity.value, inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 150));
    expect(fade().opacity.value, 1);

    final breathe = tester.widget<SenseBreathe>(find.byType(SenseBreathe));
    expect(breathe.spec.duration, const Duration(milliseconds: 2200));
    Opacity markOpacity() => tester.widget<Opacity>(find.descendant(
        of: find.byType(SenseBreathe), matching: find.byType(Opacity)).first);
    await tester.pump(const Duration(milliseconds: 800)); // 1.1 s since start
    expect(markOpacity().opacity, closeTo(SenseMotionParams.breatheOpacityMin, 0.01));
    expectNoRotation(tester);
  });

  test('loading line: 40 % bar slides from −100 % to +260 % in 1.2 s', () {
    expect(SenseMotion.loadingLine.duration, const Duration(milliseconds: 1200));
    const bar = SenseLoadingLine.width * SenseLoadingLine.barFraction;
    expect(SenseLoadingLine.barLeft(0), -bar);
    expect(SenseLoadingLine.barLeft(0.5), closeTo(bar * 0.8, 1e-9));
    expect(SenseLoadingLine.barLeft(0.999), closeTo(bar * 2.6, 0.01));
  });

  testWidgets('loading line moves between frames', (tester) async {
    await tester.pumpWidget(app(const Center(child: SenseLoadingLine())));
    double left() => tester.widget<Positioned>(find.byKey(const Key('sense-loading-bar'))).left!;
    final a = left();
    await tester.pump(const Duration(milliseconds: 300));
    final b = left();
    await tester.pump(const Duration(milliseconds: 300));
    final c = left();
    expect(b, greaterThan(a));
    expect(c, greaterThan(b));
  });

  testWidgets('golden: opening (a08)', (tester) async {
    setWindow(tester, const Size(1280, 760));
    await tester.pumpWidget(app(const RepaintBoundary(key: Key('golden'), child: SenseSplash(animate: false))));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('splash_a08')));
  }, skip: goldenSkip('splash_a08'), tags: const ['golden']);

  testWidgets('golden: after an update', (tester) async {
    setWindow(tester, const Size(1280, 760));
    await tester.pumpWidget(app(
        const RepaintBoundary(key: Key('golden'), child: SenseSplash(animate: false, updatingToVersion: 5))));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('splash_update')));
  }, skip: goldenSkip('splash_update'), tags: const ['golden']);
}
