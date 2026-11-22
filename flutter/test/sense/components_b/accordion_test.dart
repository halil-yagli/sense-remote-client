// Sense Remote (A2b): closable categories and the general status box (T7, #45).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/components_b.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'support.dart';

SenseAccordionItem _item(String id, {double height = 40, SenseLevel? level, String? summary}) =>
    SenseAccordionItem(
      id: id,
      title: 'Kategori $id',
      summary: summary,
      level: level,
      builder: (_) => SizedBox(key: Key('body-$id'), height: height),
    );

Finder _header(String id) => find.text('Kategori $id');

void main() {
  group('SenseAccordion (T7)', () {
    testWidgets('one open per level; pressing the open one closes it', (tester) async {
      String? last = 'unset';
      await tester.pumpWidget(app(SingleChildScrollView(
        child: SenseAccordion(
          items: [_item('a'), _item('b'), _item('c')],
          onChanged: (v) => last = v,
        ),
      )));
      expect(find.byKey(const Key('body-a')), findsNothing);

      await tester.tap(_header('a'));
      await tester.pump();
      expect(find.byKey(const Key('body-a')), findsOneWidget);
      expect(last, 'a');

      await tester.tap(_header('b'));
      await tester.pump();
      expect(find.byKey(const Key('body-a')), findsNothing);
      expect(find.byKey(const Key('body-b')), findsOneWidget);
      expect(last, 'b');

      await tester.tap(_header('b'));
      await tester.pump();
      expect(find.byKey(const Key('body-b')), findsNothing);
      expect(last, isNull);
    });

    testWidgets('a nested level keeps its own open item', (tester) async {
      await tester.pumpWidget(app(SingleChildScrollView(
        child: SenseAccordion(initialOpenId: 'outer', items: [
          SenseAccordionItem(
            id: 'outer',
            title: 'Kategori outer',
            builder: (_) => SenseAccordion(items: [_item('x'), _item('y')]),
          ),
          _item('other'),
        ]),
      )));
      await tester.tap(_header('x'));
      await tester.pump();
      expect(find.byKey(const Key('body-x')), findsOneWidget);
      expect(find.text('Kategori outer'), findsOneWidget);
      await tester.tap(_header('y'));
      await tester.pump();
      expect(find.byKey(const Key('body-x')), findsNothing);
      expect(find.byKey(const Key('body-y')), findsOneWidget);
      expect(find.byKey(const Key('sense-acc-outer')), findsOneWidget, reason: 'outer stays open');
    });

    testWidgets('the pressed header stays where it was on screen (#45)', (tester) async {
      setWindow(tester, const Size(500, 400));
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(app(SingleChildScrollView(
        controller: scroll,
        child: Column(children: [
          SenseAccordion(
            initialOpenId: 'a',
            items: [_item('a', height: 300), _item('b'), _item('c', height: 600), _item('d')],
          ),
          const SizedBox(height: 1000),
        ]),
      )));
      scroll.jumpTo(320);
      await tester.pump();
      final before = tester.getTopLeft(_header('c')).dy;

      await tester.tap(_header('c'));
      await tester.pump(); // rebuild: "a" closes above, "c" opens
      await tester.pump(); // post-frame scroll correction
      expect(find.byKey(const Key('body-a')), findsNothing);
      expect(find.byKey(const Key('body-c')), findsOneWidget);
      expect(tester.getTopLeft(_header('c')).dy, closeTo(before, 1));
      expect(scroll.offset, lessThan(320), reason: 'the list scrolled instead of the header jumping');
    });

    testWidgets('caret changes ▶ → ▼ without turning (T4)', (tester) async {
      await tester.pumpWidget(app(SingleChildScrollView(child: SenseAccordion(items: [_item('a')]))));
      expect(find.text('▶'), findsOneWidget);
      await tester.tap(_header('a'));
      await tester.pump();
      expect(find.text('▼'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      expectNoRotation(tester);
    });

    testWidgets('keyboard: Tab to the header, Enter opens', (tester) async {
      await tester.pumpWidget(app(SingleChildScrollView(child: SenseAccordion(items: [_item('a')]))));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.byKey(const Key('body-a')), findsOneWidget);
    });

    testWidgets('level colours: warn / hot stripe and title, dot only with a level', (tester) async {
      await tester.pumpWidget(app(SingleChildScrollView(
        child: SenseAccordion(items: [
          _item('ok', level: SenseLevel.ok),
          _item('warn', level: SenseLevel.warn),
          _item('hot', level: SenseLevel.hot),
          _item('none'),
        ]),
      )));
      Color titleColor(String id) => tester.widget<Text>(_header(id)).style!.color!;
      expect(titleColor('ok'), SenseColors.text);
      expect(titleColor('warn'), SenseColors.warn);
      expect(titleColor('hot'), SenseColors.dangerText);
      expect(titleColor('none'), SenseColors.text);
      expect(find.byKey(const Key('sense-acc-stripe')), findsNWidgets(2));
      expect(find.byType(SenseStatusDot), findsNWidgets(3));
    });
  });

  group('SenseStatusBox (T7)', () {
    test('frame and title follow the worst level', () {
      expect(SenseStatusBox.borderColor(SenseLevel.ok), SenseColors.line);
      expect(SenseStatusBox.borderColor(SenseLevel.warn), SenseColors.warn.withOpacity(0.5));
      expect(SenseStatusBox.borderColor(SenseLevel.hot), SenseColors.hot.withOpacity(0.6));
      expect(SenseStatusBox.titleColor(SenseLevel.ok), SenseColors.ok);
      expect(SenseStatusBox.titleColor(SenseLevel.hot), SenseColors.hot);
      expect(senseWorstLevel([SenseLevel.ok, SenseLevel.hot, SenseLevel.warn]), SenseLevel.hot);
    });

    testWidgets('a tag opens its category', (tester) async {
      String? opened;
      await tester.pumpWidget(app(Center(
        child: SizedBox(
          width: 400,
          child: SenseStatusBox(
            level: SenseLevel.warn,
            title: 'Dikkat gerekiyor',
            alerts: [SenseStatusAlert(label: 'Ekran kartı', level: SenseLevel.warn, onTap: () => opened = 'gpu')],
          ),
        ),
      )));
      await tester.tap(find.text('Ekran kartı'));
      expect(opened, 'gpu');
    });
  });

  testWidgets('golden: categories, page density, status boxes', (tester) async {
    setWindow(tester, const Size(500, 760));
    await tester.pumpWidget(app(sample(
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SenseStatusBox(level: SenseLevel.ok, title: 'Her şey yolunda'),
        const SizedBox(height: 6),
        SenseStatusBox(level: SenseLevel.warn, title: 'Göz atılmalı', alerts: [
          SenseStatusAlert(label: 'Ekran kartı', level: SenseLevel.warn, onTap: () {}),
        ]),
        const SizedBox(height: 6),
        SenseAccordion(initialOpenId: 'warn', items: [
          _item('ok', level: SenseLevel.ok, summary: 'i7-12700 · %23 · 58 °C'),
          _item('warn', level: SenseLevel.warn, summary: 'RTX 4070 · %71 · 84 °C'),
          _item('hot', level: SenseLevel.hot, summary: 'C: %62 · D: %96'),
        ]),
        const SizedBox(height: 16),
        SenseAccordion(density: SenseAccordionDensity.page, items: [
          _item('Bağlantılar', summary: '5 ayar'),
          _item('Güvenlik', summary: '6 ayar'),
        ]),
      ]),
    )));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('accordion_status')));
  }, skip: goldenSkip('accordion_status'), tags: const ['golden']);
}
