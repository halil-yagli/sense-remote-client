// Sense Remote: the "Ağ" traffic row draws its arrows as icons (G1) and the network and
// storage rows show prefix, badge and volume name (O8).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_popup.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_widgets.dart';
import 'package:flutter_hbb/sense/sense.dart';

import 'fixtures.dart';

void main() {
  testWidgets('traffic: arrow icons, no ↓ ↑ text; STATİK badge is soft, not white', (tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 400,
        child: SenseStatusPopup(feed: feedWith(fullJson()), onClose: () {}, tick: null, initialOpenId: 'network'),
      ),
    )));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('sense-traffic-down')), findsWidgets);
    expect(find.byKey(const ValueKey('sense-traffic-up')), findsWidgets);
    expect(find.textContaining('↓'), findsNothing);
    expect(find.textContaining('↑'), findsNothing);
    expect(find.textContaining('/24'), findsOneWidget);
    final badge = tester.widgetList<SenseStatusTagView>(find.byType(SenseStatusTagView)).firstWhere((t) => t.strong);
    expect(badge.label, 'STATİK');
    final box = tester.widget<Container>(find.descendant(of: find.byWidget(badge), matching: find.byType(Container)).first);
    expect((box.decoration as BoxDecoration).color, isNot(SenseColors.text));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('G7: card titles use the free room (disk names are not cut)', (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 400,
        child: SenseStatusPopup(feed: feedWith(fullJson()), onClose: () {}, tick: null, initialOpenId: 'storage'),
      ),
    )));
    await tester.pump(const Duration(milliseconds: 400));
    for (final name in ['Samsung SSD 980 PRO 1TB', 'WDC WD20EZBX 2TB']) {
      final p = tester.renderObject<RenderParagraph>(find.text(name));
      expect(p.didExceedMaxLines, isFalse, reason: name);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
