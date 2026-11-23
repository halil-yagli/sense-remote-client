// Sense Remote (C2): golden images of the session popups, compared side by side
// with the locked design (prototip/onayli/2026-11-22_bilgisayar-durumu_ONAYLI.html)
// and img c06, s01, s04, c07, s07 (İnşa planı §5). Window 1440 × 900 like the
// prototype shots: popup 400 px, 10 px from the top right, stage 854 px high.
// Images are made on CI (sense-golden.yml); until one exists its test is skipped.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/session/popups/display/display_popup.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_popup.dart';

import 'fixtures.dart';

const String _dir = 'test/goldens/session_popups';
String _file(String name) => '../../goldens/session_popups/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_dir/$name.png').existsSync();

const Size _stage = Size(420, 854);

Future<void> _shoot(WidgetTester tester, String name, WidgetBuilder popup) async {
  tester.view.physicalSize = const Size(1440, 854);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = SensePopupController();
  addTearDown(c.dispose);
  await tester.pumpWidget(app(Align(
    alignment: Alignment.topRight,
    child: RepaintBoundary(
      key: const Key('golden'),
      child: SizedBox.fromSize(
        size: _stage,
        child: SensePopupHost(controller: c, widthOverride: SenseSizes.popupWidthMedium, child: const SizedBox.expand()),
      ),
    ),
  )));
  c.open('golden', popup);
  await tester.pump();
  await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file(name)));
  await tester.pumpWidget(const SizedBox());
}

void main() {
  for (final (name, open) in [
    ('status_c06_depolama', 'storage'),
    ('status_s01_islemci', 'cpu'),
    ('status_s02_ekran_karti', 'gpu'),
    ('status_s04_ag', 'network'),
  ]) {
    testWidgets('golden: Bilgisayar durumu, $open open', (tester) async {
      await _shoot(tester, name,
          (_) => SenseStatusPopup(feed: feedWith(fullJson()), onClose: () {}, tick: null, initialOpenId: open));
    }, skip: _skip(name), tags: const ['golden']);
  }

  for (final (name, open) in [
    ('display_c07_ekran2', 'display-1'),
    ('display_s07_oturum', 'session'),
  ]) {
    testWidgets('golden: Ekran bilgisi, $open open', (tester) async {
      await _shoot(tester, name,
          (_) => SenseDisplayPopup(
              feed: feedWith(fullJson()), video: ValueNotifier(kVideo), onClose: () {}, initialOpenId: open));
    }, skip: _skip(name), tags: const ['golden']);
  }
}
