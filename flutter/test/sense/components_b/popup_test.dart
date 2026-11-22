// Sense Remote (A2b): popup frame and the single-popup host (T3, T4, T7).
// The golden is the locked "Bilgisayar durumu" layout (img/c06.png,
// prototip/onayli/2026-11-22_bilgisayar-durumu_ONAYLI.html).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/components_b.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'support.dart';

Widget _shell({
  bool minimized = false,
  ValueChanged<bool>? onMin,
  VoidCallback? onClose,
  bool animateIn = false,
}) =>
    SensePopupShell(
      title: 'Bilgisayar durumu',
      subtitle: '8 sn önce',
      minimized: minimized,
      onMinimizedChanged: onMin ?? (_) {},
      onClose: onClose ?? () {},
      animateIn: animateIn,
      body: const SizedBox(key: Key('body'), height: 120),
    );

Opacity _enterOpacity(WidgetTester tester) => tester.widget<Opacity>(find.descendant(
    of: find.byType(SensePopupEnter), matching: find.byType(Opacity)).first);

void main() {
  group('SensePopupShell', () {
    testWidgets('header: title, grey subtitle, – and ×', (tester) async {
      var closed = 0;
      bool? minimized;
      await tester.pumpWidget(app(Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 440, child: _shell(onClose: () => closed++, onMin: (v) => minimized = v)))));
      expect(find.text('Bilgisayar durumu'), findsOneWidget);
      expect(find.text('8 sn önce'), findsOneWidget);
      final title = tester.widget<Text>(find.text('Bilgisayar durumu'));
      expect(title.style!.fontSize, SenseFontSize.popupTitle);
      expect(title.style!.fontWeight, SenseFontWeight.bold);
      final sub = tester.widget<Text>(find.text('8 sn önce'));
      expect(sub.style!.fontSize, SenseFontSize.popupSubtitle);
      expect(sub.style!.color, SenseColors.textMuted);

      await tester.tap(find.byKey(const Key('sense-popup-close')));
      expect(closed, 1);
      await tester.tap(find.byKey(const Key('sense-popup-minimize')));
      expect(minimized, isTrue);
      minimized = null;
      await tester.tap(find.text('Bilgisayar durumu'));
      expect(minimized, isTrue, reason: 'a tap on the header minimizes too');
    });

    testWidgets('minimized: body hidden, header stays', (tester) async {
      await tester.pumpWidget(app(Align(
          alignment: Alignment.topLeft, child: SizedBox(width: 440, child: _shell(minimized: true)))));
      expect(find.byKey(const Key('body')), findsNothing);
      expect(find.text('Bilgisayar durumu'), findsOneWidget);
      expect(find.text('+'), findsOneWidget);
    });

    testWidgets('frame: surface, line border, 12 px corners', (tester) async {
      await tester.pumpWidget(app(Align(alignment: Alignment.topLeft, child: SizedBox(width: 440, child: _shell()))));
      final box = tester.widgetList<Container>(find.byType(Container)).firstWhere((c) {
        final d = c.decoration;
        return d is BoxDecoration && d.color == SenseColors.surface;
      });
      final d = box.decoration! as BoxDecoration;
      expect(d.borderRadius, BorderRadius.circular(SenseRadii.popup));
      expect((d.border! as Border).top.color, SenseColors.line);
    });

    test('opening frames: 0.14 s ease-out, 6 px and 98.5 %', () {
      expect(SenseMotion.popupOpen.duration, const Duration(milliseconds: 140));
      expect(SenseMotion.popupOpen.curve, SenseCurves.easeOut);
      final start = SensePopupEnter.frameAt(0, SensePopupFrom.top);
      expect(start.opacity, 0);
      expect(start.dy, -6);
      expect(start.scale, 0.985);
      final mid = SensePopupEnter.frameAt(0.5, SensePopupFrom.top);
      expect(mid.opacity, inExclusiveRange(0.5, 1), reason: 'ease-out is past half at half time');
      expect(mid.dy, inExclusiveRange(-6, 0));
      expect(mid.scale, inExclusiveRange(0.985, 1));
      final end = SensePopupEnter.frameAt(1, SensePopupFrom.bottom);
      expect(end.opacity, 1);
      expect(end.dy, 0);
      expect(end.scale, 1);
      expect(SensePopupEnter.frameAt(0, SensePopupFrom.bottom).dy, 6, reason: 'chat grows up');
    });

    testWidgets('opening animation runs once, middle frame in between, no rotation', (tester) async {
      await tester.pumpWidget(app(Align(
          alignment: Alignment.topLeft, child: SizedBox(width: 440, child: _shell(animateIn: true)))));
      expect(_enterOpacity(tester).opacity, 0);
      await tester.pump(const Duration(milliseconds: 70));
      expect(_enterOpacity(tester).opacity, inExclusiveRange(0, 1));
      expectNoRotation(tester);
      await tester.pump(const Duration(milliseconds: 70));
      expect(_enterOpacity(tester).opacity, 1);
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('SensePopupHost: one popup at a time (T7)', () {
    Widget host(SensePopupController c) => app(
          SensePopupHost(controller: c, child: const SizedBox.expand()),
        );

    Widget pane(String title) => SensePopupShell(
          title: title,
          onClose: () {},
          animateIn: false,
          body: SizedBox(height: 2000, child: Text('$title gövde')),
        );

    testWidgets('opening one closes the other; toggle; close', (tester) async {
      setWindow(tester, const Size(1600, 900));
      final c = SensePopupController();
      addTearDown(c.dispose);
      await tester.pumpWidget(host(c));
      expect(find.byType(SensePopupShell), findsNothing);

      c.open('status', (_) => pane('Bilgisayar durumu'));
      await tester.pump();
      expect(find.text('Bilgisayar durumu'), findsOneWidget);

      c.open('display', (_) => pane('Ekran bilgisi'));
      await tester.pump();
      expect(find.byType(SensePopupShell), findsOneWidget);
      expect(find.text('Bilgisayar durumu'), findsNothing);
      expect(c.openId, 'display');

      c.toggle('display', (_) => pane('Ekran bilgisi'));
      await tester.pump();
      expect(find.byType(SensePopupShell), findsNothing);
      expect(c.isOpen, isFalse);

      c.toggle('status', (_) => pane('Bilgisayar durumu'));
      await tester.pump();
      c.close('display');
      await tester.pump();
      expect(c.openId, 'status', reason: 'closing another id leaves the open one');
      c.close();
      await tester.pump();
      expect(find.byType(SensePopupShell), findsNothing);
    });

    testWidgets('width follows the window (440 / 400 / 370); ends 32 px above the bottom', (tester) async {
      final c = SensePopupController();
      addTearDown(c.dispose);
      for (final (w, expected) in [(1600.0, 440.0), (1500.0, 400.0), (1366.0, 400.0), (1280.0, 370.0)]) {
        setWindow(tester, Size(w, 720));
        await tester.pumpWidget(host(c));
        c.open('status', (_) => pane('Bilgisayar durumu'));
        await tester.pump();
        final r = tester.getRect(find.byType(SensePopupShell));
        expect(r.width, expected, reason: 'window $w');
        expect(r.right, w - SensePopupHost.defaultMargin);
        expect(r.top, SensePopupHost.defaultMargin);
        expect(r.bottom, lessThanOrEqualTo(720 - SenseSizes.popupBottomGap));
        c.close();
        await tester.pump();
      }
    });

    testWidgets('chat sits at the bottom right and grows up', (tester) async {
      setWindow(tester, const Size(1600, 900));
      final c = SensePopupController();
      addTearDown(c.dispose);
      await tester.pumpWidget(host(c));
      c.open('chat', (_) => SensePopupShell(title: 'Sohbet', body: const SizedBox(height: 200)),
          placement: SensePopupPlacement.bottomRight);
      await tester.pump();
      final enter = tester.widget<SensePopupEnter>(find.byType(SensePopupEnter));
      expect(enter.from, SensePopupFrom.bottom);
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getRect(find.byType(SensePopupShell)).bottom, 900 - SenseSizes.popupBottomGap);
    });

    testWidgets('Esc closes the open popup', (tester) async {
      setWindow(tester, const Size(1600, 900));
      final c = SensePopupController();
      addTearDown(c.dispose);
      await tester.pumpWidget(app(SensePopupHost(
        controller: c,
        child: const Focus(autofocus: true, child: SizedBox.expand()),
      )));
      c.open('status', (_) => pane('Bilgisayar durumu'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.isOpen, isFalse);
    });

    testWidgets('SensePopupHost.of finds the controller', (tester) async {
      final c = SensePopupController();
      addTearDown(c.dispose);
      SensePopupController? found;
      await tester.pumpWidget(app(SensePopupHost(
        controller: c,
        child: Builder(builder: (context) {
          found = SensePopupHost.of(context);
          return const SizedBox.expand();
        }),
      )));
      expect(found, same(c));
    });
  });

  testWidgets('golden: Bilgisayar durumu popup (c06 layout)', (tester) async {
    setWindow(tester, const Size(480, 900));
    final storage = [
      const SenseStatusAlert(label: 'Ekran kartı', level: SenseLevel.warn),
      const SenseStatusAlert(label: 'Depolama', level: SenseLevel.hot),
    ];
    Widget row(String l, String v, [SenseLevel lv = SenseLevel.ok]) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(
                child: Text(l,
                    style: const TextStyle(
                        fontFamily: SenseFont.family, fontSize: SenseFontSize.hintLarge, color: SenseColors.textMuted))),
            Text(v,
                style: TextStyle(
                    fontFamily: SenseFont.family,
                    fontSize: SenseFontSize.hintLarge,
                    fontWeight: lv == SenseLevel.ok ? SenseFontWeight.regular : SenseFontWeight.bold,
                    color: lv == SenseLevel.ok ? SenseColors.text : lv.color)),
          ]),
        );
    await tester.pumpWidget(app(Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: const Key('golden'),
        child: Container(
          color: SenseColors.bg,
          padding: const EdgeInsets.all(20),
          width: 480,
          height: 760,
          alignment: Alignment.topCenter,
          child: SensePopupShell(
            title: 'Bilgisayar durumu',
            subtitle: '8 sn önce',
            animateIn: false,
            onMinimizedChanged: (_) {},
            onClose: () {},
            body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SenseStatusBox(level: SenseLevel.hot, title: 'Dikkat gerekiyor', alerts: storage, children: [
                row('İşlemci', '%23 · 58 °C'),
                row('Ekran kartı', '%71 · 84 °C', SenseLevel.warn),
                row('Disk D:', '%96', SenseLevel.hot),
              ]),
              const SizedBox(height: 6),
              SenseAccordion(
                initialOpenId: 'disk',
                items: [
                  SenseAccordionItem(
                      id: 'cpu', title: 'İşlemci', summary: 'i7-12700 · %23 · 58 °C', level: SenseLevel.ok,
                      builder: (_) => const SizedBox()),
                  SenseAccordionItem(
                      id: 'gpu', title: 'Ekran kartı', summary: 'RTX 4070 · %71 · 84 °C', level: SenseLevel.warn,
                      builder: (_) => const SizedBox()),
                  SenseAccordionItem(
                      id: 'ram', title: 'Bellek', summary: '14,1 / 32 GB · %44', level: SenseLevel.ok,
                      builder: (_) => const SizedBox()),
                  SenseAccordionItem(
                      id: 'disk', title: 'Depolama', summary: 'C: %62 · D: %96', level: SenseLevel.hot,
                      builder: (_) => Column(children: [
                            row('C: (Sistem)', '577 / 931 GB'),
                            row('D: (İçerik)', '1,75 / 1,82 TB', SenseLevel.hot),
                          ])),
                ],
              ),
            ]),
          ),
        ),
      ),
    )));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('popup_status_c06')));
  }, skip: goldenSkip('popup_status_c06'), tags: const ['golden']);
}
