// Sense Remote: labels, lights, tiles, cards, header, spinner, scrollbar (YH T4, T6, T7; A2a).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/sense/components/button.dart';
import 'package:flutter_hbb/sense/components/card.dart';
import 'package:flutter_hbb/sense/components/chip.dart';
import 'package:flutter_hbb/sense/components/header_row.dart';
import 'package:flutter_hbb/sense/components/led.dart';
import 'package:flutter_hbb/sense/components/scrollbar.dart';
import 'package:flutter_hbb/sense/components/spinner.dart';
import 'package:flutter_hbb/sense/components/stat_tile.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

BoxDecoration _deco(WidgetTester tester, Finder of) => tester
    .widget<Container>(find.descendant(of: of, matching: find.byType(Container)).first)
    .decoration! as BoxDecoration;

BoxDecoration _led(WidgetTester tester, Finder of) => tester
    .widget<DecoratedBox>(find.descendant(of: of, matching: find.byType(DecoratedBox)).first)
    .decoration as BoxDecoration;

void main() {
  group('SenseChip', () {
    testWidgets('colours per level; neutral is raised', (tester) async {
      await pumpSense(
          tester,
          const Row(mainAxisSize: MainAxisSize.min, children: [
            SenseChip(label: 'Yok'),
            SenseChip(label: 'Verildi', level: SenseLevel.ok),
            SenseChip(label: 'Disk %88', level: SenseLevel.warn),
            SenseChip(label: 'Kesildi', level: SenseLevel.hot),
          ]));
      expect(_deco(tester, find.widgetWithText(SenseChip, 'Yok')).color, SenseColors.raised);
      expect(tester.widget<Text>(find.text('Verildi')).style!.color, SenseColors.ok);
      expect(tester.widget<Text>(find.text('Disk %88')).style!.color, SenseColors.warn);
      expect(tester.widget<Text>(find.text('Kesildi')).style!.color, SenseColors.dangerText);
    });

    testWidgets('clickable alert tag: bold, click and Enter open it', (tester) async {
      var n = 0;
      await pumpSense(tester, SenseChip(label: 'Disk', level: SenseLevel.warn, onTap: () => n++));
      expect(tester.widget<Text>(find.text('Disk')).style!.fontWeight, SenseFontWeight.bold);
      await tester.tap(find.text('Disk'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(n, 2);
    });

    testWidgets('pill: selected is white, hover lightens', (tester) async {
      await pumpSense(
          tester,
          Row(mainAxisSize: MainAxisSize.min, children: [
            SensePill(label: 'Bugün', selected: true, onTap: () {}),
            SensePill(label: 'Dün', onTap: () {}),
          ]));
      expect(_deco(tester, find.widgetWithText(SensePill, 'Bugün')).color, SenseColors.text);
      await hover(tester, find.text('Dün'));
      expect(tester.widget<Text>(find.text('Dün')).style!.color, SenseColors.text);
    });
  });

  group('SenseLed', () {
    testWidgets('size and colours; unknown is a hollow ring', (tester) async {
      await pumpSense(
          tester,
          const Row(mainAxisSize: MainAxisSize.min, children: [
            SenseLed(key: Key('ok'), level: SenseLevel.ok),
            SenseLed(key: Key('na'), level: SenseLevel.unknown),
          ]));
      expect(tester.getSize(find.byKey(const Key('ok'))), const Size.square(SenseSizes.led));
      expect(_led(tester, find.byKey(const Key('ok'))).color, SenseColors.ok);
      final na = _led(tester, find.byKey(const Key('na')));
      expect(na.color, isNull);
      expect(na.border, isNotNull);
    });

    testWidgets('red blinks (1,4 s, down to 0,3); others stay', (tester) async {
      await pumpSense(
          tester,
          const Row(mainAxisSize: MainAxisSize.min, children: [
            SenseLed(key: Key('hot'), level: SenseLevel.hot),
            SenseLed(key: Key('warn'), level: SenseLevel.warn),
          ]),
          animate: true);
      double op(String k) => tester
          .widget<Opacity>(find.descendant(of: find.byKey(Key(k)), matching: find.byType(Opacity)))
          .opacity;
      final half = SenseMotion.blinkSlow.duration ~/ 2;
      await tester.pump(half);
      expect(op('hot'), closeTo(SenseMotionParams.blinkOpacityMin, 0.02));
      expect(op('warn'), 1);
      await tester.pump(half);
      expect(op('hot'), closeTo(1, 0.02));
    });

    testWidgets('no blinking when animations are off', (tester) async {
      await pumpSense(tester, const SenseLed(level: SenseLevel.hot));
      await tester.pump(const Duration(milliseconds: 700));
      expect(
          tester
              .widget<Opacity>(find.descendant(of: find.byType(SenseLed), matching: find.byType(Opacity)))
              .opacity,
          1);
    });
  });

  group('SenseStatTile', () {
    testWidgets('label + value; frame and value in the level colour', (tester) async {
      await pumpSense(
          tester,
          const SizedBox(
            width: 480,
            child: SenseStatGrid(children: [
              SenseStatTile(label: 'İşlemci', value: '%42', level: SenseLevel.ok),
              SenseStatTile(label: 'Bellek', value: '%88', level: SenseLevel.warn),
              SenseStatTile(label: 'Disk', value: '%97', level: SenseLevel.hot),
            ]),
          ));
      expect(tester.widget<Text>(find.text('%42')).style!.color, SenseColors.ok);
      expect(tester.widget<Text>(find.text('%88')).style!.color, SenseColors.warn);
      expect(tester.widget<Text>(find.text('%97')).style!.color, SenseColors.dangerText);
      expect((_deco(tester, find.widgetWithText(SenseStatTile, 'Disk')).border! as Border).top.color,
          SenseColors.hot.withOpacity(0.55));
      expect(tester.widget<Text>(find.text('Bellek')).style!.color, SenseColors.textMuted);
    });

    testWidgets('unreadable value says "okunamadı" in italics, never a guess', (tester) async {
      await pumpSense(tester, const SenseStatTile(label: 'GPU sıcaklığı', value: null));
      final t = tester.widget<Text>(find.text(kSenseUnreadable));
      expect(t.style!.fontStyle, FontStyle.italic);
      expect(t.style!.color, SenseColors.textMuted);
    });

    testWidgets('clickable tile opens with click and Enter', (tester) async {
      var n = 0;
      await pumpSense(tester, SenseStatTile(label: 'Disk', value: '%97', level: SenseLevel.hot, onTap: () => n++));
      await tester.tap(find.text('%97'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(n, 2);
    });

    test('grid columns: 150 px tiles, 120 px at or under 1300 px', () {
      expect(SenseStatGrid.defaultMinTile(1301), 150);
      expect(SenseStatGrid.defaultMinTile(1300), 120);
      expect(SenseStatGrid.columns(480, 150, 6), 3);
      expect(SenseStatGrid.columns(480, 120, 6), 3);
      expect(SenseStatGrid.columns(520, 120, 6), 4);
      expect(SenseStatGrid.columns(1000, 150, 2), 2, reason: 'auto-fit: never more columns than tiles');
      expect(SenseStatGrid.columns(100, 150, 3), 1);
    });
  });

  group('SenseCard', () {
    testWidgets('title, rows, Kopyala copies the text', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() =>
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      var n = 0;
      await pumpSense(
          tester,
          SizedBox(
            width: 380,
            child: SenseCard(
              title: 'Disk C:',
              level: SenseLevel.warn,
              copyText: 'C: 476 GB, %88 dolu',
              onCopied: () => n++,
              child: const Column(children: [
                SenseCardRow(label: 'Doluluk', value: '%88', level: SenseLevel.warn),
                SenseCardRow(label: 'Sıcaklık', value: null, last: true),
              ]),
            ),
          ));
      expect(find.text('Disk C:'), findsOneWidget);
      expect(find.text(kSenseUnreadable), findsOneWidget);
      expect(tester.widget<Text>(find.text('%88')).style!.color, SenseColors.warn);
      await tester.tap(find.text(kSenseCopy));
      await tester.pump();
      await tester.pump();
      expect(copied, ['C: 476 GB, %88 dolu']);
      expect(n, 1);
      expect(find.text(kSenseCopied), findsOneWidget);
      await tester.pump(SenseMotion.savedHold.duration);
      await tester.pump();
      expect(find.text(kSenseCopy), findsOneWidget);
    });

    testWidgets('Kopyala is reachable with the keyboard', (tester) async {
      await pumpSense(tester, const SenseCopyButton(text: 'x'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.widget<SenseFocusRing>(find.byType(SenseFocusRing)).visible, isTrue);
    });
  });

  group('SenseHeaderRow', () {
    testWidgets('bold title, thin part, live status, actions on the right', (tester) async {
      await pumpSense(
          tester,
          SizedBox(
            width: 900,
            child: SenseHeaderRow(
              title: 'Bakım',
              titleThin: ' yapılıyor',
              status: 'Canlı · 8 sn önce',
              trailing: [SenseButton(label: 'Yenile', onPressed: () {})],
            ),
          ));
      final rich = tester.widget<RichText>(find.byType(RichText).first);
      // Text.rich wraps the given span in the default style span.
      final mine = (rich.text as TextSpan).children!.first as TextSpan;
      final spans = mine.children!.cast<TextSpan>();
      expect(spans[0].style!.fontWeight, SenseFontWeight.bold);
      expect(spans[1].style!.fontWeight, SenseFontWeight.thin);
      expect(spans[0].style!.fontSize, SenseFontSize.pageTitle);
      expect(find.text('Canlı · 8 sn önce'), findsOneWidget);
      expect(tester.getTopRight(find.byType(SenseButton)).dx,
          closeTo(tester.getTopRight(find.byType(SenseHeaderRow)).dx, 0.5));
    });

    testWidgets('long title does not overflow at 1280 px', (tester) async {
      await pumpSense(
          tester,
          SizedBox(
            width: 600,
            child: SenseHeaderRow(
              title: 'Bilgisayarlar ' * 8,
              status: '12/40 çevrimiçi',
              trailing: [SenseButton(label: 'Kimlikle bağlan', onPressed: () {})],
            ),
          ));
      expect(tester.takeException(), isNull);
    });
  });

  group('SenseSpinner', () {
    testWidgets('turns once in 0,9 s (T4), size follows', (tester) async {
      await pumpSense(tester, const SenseSpinner(size: 11), animate: true);
      expect(tester.getSize(find.byType(SenseSpinner)), const Size.square(11));
      await tester.pump(SenseMotion.spinner.duration ~/ 2);
      await tester.pump(SenseMotion.spinner.duration ~/ 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('SenseScrollbar', () {
    testWidgets('thin: 4 px thumb, no track', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await pumpSense(
          tester,
          SizedBox(
            height: 200,
            width: 300,
            child: SenseScrollbar(
              controller: controller,
              thumbVisibility: true,
              child: ListView(controller: controller, children: [
                for (var i = 0; i < 40; i++) SizedBox(height: 30, child: Text('Satır $i')),
              ]),
            ),
          ));
      final theme = ScrollbarTheme.of(tester.element(find.byType(Scrollbar)));
      expect(theme.thickness!.resolve({}), SenseSizes.scrollbarThumb);
      expect(theme.thickness!.resolve({WidgetState.hovered}), SenseSizes.scrollbarThumbHover);
      expect(theme.trackVisibility!.resolve({}), isFalse);
      expect(theme.thumbColor!.resolve({}), SenseColors.line);
    });
  });
}
