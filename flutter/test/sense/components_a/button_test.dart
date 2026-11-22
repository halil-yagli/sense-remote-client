// Sense Remote: SenseButton behaviour (YH T3, T7; A2a).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/sense/components/button.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_hbb/sense/tokens/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

BoxDecoration _box(WidgetTester tester, Finder button) => tester
    .widget<Container>(find.descendant(of: button, matching: find.byType(Container)).first)
    .decoration! as BoxDecoration;

bool _ring(WidgetTester tester, Finder of) =>
    tester.widget<SenseFocusRing>(find.descendant(of: of, matching: find.byType(SenseFocusRing))).visible;

void main() {
  testWidgets('click, Enter and Space press the button', (tester) async {
    var n = 0;
    await pumpSense(tester, SenseButton(label: 'Bağlan', onPressed: () => n++));
    await tester.tap(find.text('Bağlan'));
    expect(n, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(n, 3);
  });

  testWidgets('keyboard focus is drawn; mouse focus is not', (tester) async {
    await pumpSense(tester, SenseButton(label: 'Bağlan', onPressed: () {}));
    final b = find.byType(SenseButton);
    expect(_ring(tester, b), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_ring(tester, b), isTrue);
  });

  testWidgets('normal button: hover and pressed colours', (tester) async {
    await pumpSense(tester, SenseButton(label: 'Ekran', onPressed: () {}));
    final b = find.byType(SenseButton);
    expect(_box(tester, b).color, SenseColors.bg);
    await hover(tester, b);
    expect(_box(tester, b).color, SenseColors.hover);
    final g = await tester.startGesture(tester.getCenter(b));
    await tester.pump(const Duration(milliseconds: 150));
    expect(_box(tester, b).color, SenseColors.raised);
    await g.up();
  });

  testWidgets('primary is white with black text; danger is red', (tester) async {
    await pumpSense(
        tester,
        Column(mainAxisSize: MainAxisSize.min, children: [
          SenseButton(label: 'Kaydet', kind: SenseButtonKind.primary, onPressed: () {}),
          SenseButton(label: 'Bitir', kind: SenseButtonKind.danger, onPressed: () {}),
        ]));
    final pri = find.widgetWithText(SenseButton, 'Kaydet');
    final end = find.widgetWithText(SenseButton, 'Bitir');
    expect(_box(tester, pri).color, SenseColors.text);
    expect(tester.widget<Text>(find.text('Kaydet')).style!.color, SenseColors.bg);
    expect(_box(tester, end).color, SenseColors.danger);
    await hover(tester, end);
    expect(_box(tester, end).color, SenseColors.dangerHover);
  });

  testWidgets('primary without its condition is faded and does nothing', (tester) async {
    await pumpSense(tester,
        const SenseButton(label: 'Devam', kind: SenseButtonKind.primary, onPressed: null));
    final opacity = tester.widget<Opacity>(
        find.descendant(of: find.byType(SenseButton), matching: find.byType(Opacity)).first);
    expect(opacity.opacity, SenseUi.disabledOpacity);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_ring(tester, find.byType(SenseButton)), isFalse, reason: 'not focusable');
  });

  testWidgets('sizes and corner follow the tokens', (tester) async {
    await pumpSense(tester, SenseButton(label: 'Bağlan', onPressed: () {}), size: const Size(1600, 900));
    final box = _box(tester, find.byType(SenseButton));
    expect(box.borderRadius, BorderRadius.circular(SenseRadii.button));
    final padding = tester
        .widget<Container>(find.descendant(of: find.byType(SenseButton), matching: find.byType(Container)).first)
        .padding;
    expect(padding, const EdgeInsets.symmetric(horizontal: SenseSizes.buttonPadH, vertical: SenseSizes.buttonPadV));
    expect(tester.widget<Text>(find.text('Bağlan')).style!.fontSize, SenseFontSize.bodySmall);
  });
}
