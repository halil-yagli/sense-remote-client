// Sense Remote: edit in place (YH T7, #33 ad ve yer Host'ta değişir; A2a).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/sense/components/inline_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late List<String> saved;

  Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
    saved = [];
    await pumpSense(
        tester,
        SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SenseInlineEdit(value: 'Galeri kioskı', onSubmitted: saved.add, enabled: enabled),
            const TextField(key: Key('other')),
          ]),
        ));
  }

  testWidgets('click opens a field in place; Enter saves the trimmed text', (tester) async {
    await pump(tester);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('Galeri kioskı'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.enterText(find.byType(TextField).first, '  Salon 2  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(saved, ['Salon 2']);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('Esc cancels: nothing saved', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Galeri kioskı'));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Yeni ad');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(saved, isEmpty);
    expect(find.text('Galeri kioskı'), findsOneWidget);
  });

  testWidgets('leaving the field saves; empty or unchanged text is not sent', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Galeri kioskı'));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();
    expect(saved, isEmpty);

    await tester.tap(find.text('Galeri kioskı'));
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Giriş');
    await tester.tap(find.byKey(const Key('other')));
    await tester.pump();
    expect(saved, ['Giriş']);
  });

  testWidgets('keyboard: Tab focuses the text, Enter opens the field', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('disabled: plain text, no field', (tester) async {
    await pump(tester, enabled: false);
    await tester.tap(find.text('Galeri kioskı'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
  });
}
