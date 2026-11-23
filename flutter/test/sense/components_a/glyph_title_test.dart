// Sense Remote: golden review fixes in the library (2026-11-23, G1, G6, G7).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _long = 'Samsung SSD 980 PRO 1TB';

bool _cut(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

Widget _tag(String t) => Text(t, key: ValueKey('tag-$t'));

void main() {
  testWidgets('G6: test binding draws real (soft) shadows', (tester) async {
    expect(debugDisableShadows, isFalse);
  });

  group('G1: SenseGlyph', () {
    testWidgets('marks are Material icons, the caret is drawn', (tester) async {
      await pumpSense(
        tester,
        const Row(mainAxisSize: MainAxisSize.min, children: [
          SenseGlyph(SenseGlyphKind.check),
          SenseGlyph(SenseGlyphKind.down),
          SenseGlyph(SenseGlyphKind.caretDown),
        ]),
      );
      final icons = tester.widgetList<Icon>(find.byType(Icon)).map((i) => i.icon).toList();
      expect(icons, [Icons.check_rounded, Icons.arrow_downward_rounded]);
      expect(find.byType(SenseCaret), findsOneWidget);
      for (final k in SenseGlyphKind.values) {
        if (k != SenseGlyphKind.caretDown) expect(SenseGlyph.iconOf(k), isNotNull, reason: k.name);
      }
    });

    testWidgets('size and colour follow the arguments; decorative by default', (tester) async {
      await pumpSense(tester, const SenseGlyph(SenseGlyphKind.cross, size: 14, color: SenseColors.ok));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.size, 14);
      expect(icon.color, SenseColors.ok);
      expect(find.byType(ExcludeSemantics), findsWidgets);
    });

    testWidgets('inside rich text', (tester) async {
      await pumpSense(
        tester,
        Text.rich(TextSpan(children: [
          SenseGlyph.span(SenseGlyphKind.down),
          const TextSpan(text: ' 12 · '),
          SenseGlyph.span(SenseGlyphKind.up),
          const TextSpan(text: ' 3'),
        ])),
      );
      expect(find.byType(Icon), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  group('G7: titles use the free room', () {
    testWidgets('card title with tags is not cut while there is room', (tester) async {
      await pumpSense(
        tester,
        SizedBox(
          width: 376,
          child: SenseCard(
            title: _long,
            copyText: 'x',
            tags: [_tag('NVMe'), _tag('SSD')],
            child: const SizedBox(height: 10),
          ),
        ),
      );
      expect(_cut(tester, _long), isFalse);
      // Tags sit right after the title, not pushed to the far right.
      final titleRight = tester.getRect(find.text(_long)).right;
      final tagLeft = tester.getRect(find.byKey(const ValueKey('tag-NVMe'))).left;
      expect(tagLeft - titleRight, lessThan(12));
      expect(tester.takeException(), isNull);
    });

    testWidgets('card title ends in … only when it really does not fit', (tester) async {
      await pumpSense(
        tester,
        SizedBox(
          width: 150,
          child: SenseCard(title: _long, copyText: 'x', tags: [_tag('NVMe')], child: const SizedBox()),
        ),
      );
      expect(_cut(tester, _long), isTrue);
      expect(find.byKey(const ValueKey('tag-NVMe')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('header title is not cut by a short live status', (tester) async {
      const title = 'Giriş Salonu PC-2 · Ekran kartı ve depolama';
      await pumpSense(
        tester,
        const SizedBox(width: 760, child: SenseHeaderRow(title: title, status: 'Canlı · 8 sn önce')),
      );
      expect(_cut(tester, title), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('header: long status is capped, title still shown', (tester) async {
      await pumpSense(
        tester,
        SizedBox(
          width: 400,
          child: SenseHeaderRow(title: 'Bilgisayarlar', status: 'Canlı · ' * 20),
        ),
      );
      expect(_cut(tester, 'Bilgisayarlar'), isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
