// Sense Remote: one dark theme, Poppins, breakpoints (YH T1, T2, T3, T9; A2a).
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/components/button.dart';
import 'package:flutter_hbb/sense/components/segment.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_hbb/sense/tokens/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('T1: dark only', () {
    testWidgets('system in light mode: the app is still dark', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      late ThemeData seen;
      await tester.pumpWidget(MaterialApp(
        theme: senseTheme(),
        darkTheme: senseTheme(),
        themeMode: kSenseThemeMode,
        home: Builder(builder: (context) {
          seen = Theme.of(context);
          return const SizedBox();
        }),
      ));
      expect(seen.brightness, Brightness.dark);
      expect(seen.scaffoldBackgroundColor, SenseColors.bg);
      expect(kSenseThemeMode, ThemeMode.dark);
    });

    test('no RustDesk blue in the theme', () {
      final t = senseTheme();
      const blue = Color(0xFF0071FF);
      final s = t.colorScheme;
      for (final c in [s.primary, s.secondary, s.surface, s.tertiary, t.focusColor, t.hoverColor]) {
        expect(c, isNot(blue));
      }
      expect(s.primary, SenseColors.text);
    });
  });

  group('T2: Poppins', () {
    test('theme text uses Poppins, never WorkSans', () {
      final t = senseTheme();
      for (final style in [t.textTheme.bodyMedium, t.textTheme.titleLarge, t.textTheme.labelLarge]) {
        expect(style!.fontFamily, SenseFont.family);
      }
      expect(SenseTextStyles.body.fontFamily, 'Poppins');
      expect(SenseTextStyles.button.fontWeight, SenseFontWeight.medium);
    });

    testWidgets('every text drawn by the components is Poppins', (tester) async {
      await pumpSense(
          tester,
          Column(mainAxisSize: MainAxisSize.min, children: [
            SenseButton(label: 'Bağlan', onPressed: () {}),
            SenseSegment<int>(
                options: const [SenseSegmentOption(value: 1, label: 'Bir')],
                value: 1,
                onChanged: (_) {},
                expand: false),
          ]));
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        final family = (rich.text as TextSpan).style?.fontFamily;
        expect(family, SenseFont.family);
      }
    });
  });

  group('T3 / T9: breakpoints 1500 / 1300 / 800', () {
    test('popup, side menu and tile widths', () {
      expect(SenseLayout.popupWidth(1501), SenseSizes.popupWidth);
      expect(SenseLayout.popupWidth(1500), SenseSizes.popupWidthMedium);
      expect(SenseLayout.popupWidth(1301), SenseSizes.popupWidthMedium);
      expect(SenseLayout.popupWidth(1300), SenseSizes.popupWidthNarrow);
      expect(SenseLayout.popupWidth(1280), 370);
      expect(SenseLayout.sideMenu(1301), 212);
      expect(SenseLayout.sideMenu(1300), 180);
      expect(SenseLayout.tileMin(1300), 180);
    });

    test('button padding 11 → 9 at 1500; segment 5 → 4 at 800 px height', () {
      expect(SenseButton.paddingH(1501, SenseButtonSize.regular), 11);
      expect(SenseButton.paddingH(1500, SenseButtonSize.regular), 9);
      expect(SenseButton.paddingH(1280, SenseButtonSize.small), SenseSizes.buttonSmallPadH);
      expect(SenseSegment.paddingV(801), 5);
      expect(SenseSegment.paddingV(800), 4);
    });

    for (final size in const [Size(1600, 900), Size(1500, 800), Size(1366, 768), Size(1280, 720)]) {
      testWidgets('button padding follows the window at ${size.width.toInt()}×${size.height.toInt()}',
          (tester) async {
        await pumpSense(tester, SenseButton(label: 'Bağlan', onPressed: () {}), size: size);
        final c = tester.widget<Container>(
            find.descendant(of: find.byType(SenseButton), matching: find.byType(Container)).first);
        expect((c.padding! as EdgeInsets).left, size.width <= 1500 ? 9 : 11);
      });
    }
  });
}
