// Sense Remote (P3, B6): the setup window's size follows the screen and the buttons stay on
// it. The page is drawn like `SenseInstallPage` does (Theme + Scaffold + wizard) at the
// sizes of the window: 800 × 600 (first size), 1280 × 800, and the smallest one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_wizard.dart';

import 'sense_install_upgrade_test.dart' show FakeUpgrade;
import 'sense_install_wizard_test.dart' show FakeBackend, frames;

Future<void> pumpAt(WidgetTester tester, Size size, FakeUpgrade upgrade,
    {bool mac = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(Theme(
    data: senseTheme(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: senseTheme(),
      home: Scaffold(
        backgroundColor: SenseColors.bg,
        body: SenseInstallWizard(
          initialPath: r'C:\Program Files\Sense Remote',
          backend: FakeBackend(),
          mac: mac,
          upgrade: upgrade.make(),
          version: '6',
        ),
      ),
    ),
  ));
  await frames(tester);
}

void main() {
  group('senseInstallWindowFor', () {
    test('big screen: the prototype size', () {
      final f = senseInstallWindowFor(const Size(1920, 1040));
      expect(f.size, kSenseInstallSize);
      expect(f.min, kSenseInstallMinSize);
    });

    test('short screen: never bigger than the screen', () {
      final f = senseInstallWindowFor(const Size(1092, 614));
      expect(f.size.height, 614 - kSenseInstallScreenMargin);
      expect(f.size.width, kSenseInstallSize.width);
      expect(f.min.height, kSenseInstallMinSize.height);
    });

    test('tiny screen: the minimum follows the size', () {
      final f = senseInstallWindowFor(const Size(700, 500));
      expect(f.size, const Size(660, 460));
      expect(f.min, f.size);
    });

    test('unknown screen: the prototype size', () {
      expect(senseInstallWindowFor(null).size, kSenseInstallSize);
    });
  });

  for (final size in const [
    Size(800, 600),
    Size(1280, 800),
    Size(760, 540),
    Size(820, 574),
  ]) {
    testWidgets('upgrade: Güncelle is on the window and can be tapped at ${size.width.toInt()}×${size.height.toInt()}',
        (tester) async {
      final upgrade = FakeUpgrade();
      await pumpAt(tester, size, upgrade);
      expect(tester.takeException(), isNull);

      final start = find.byKey(const Key('sense-upgrade-start'));
      expect(start, findsOneWidget);
      final rect = tester.getRect(start);
      final window = Offset.zero & size;
      expect(window.contains(rect.topLeft) && window.contains(rect.bottomRight), isTrue,
          reason: 'button $rect is outside the window $window');

      await tester.tap(start);
      await frames(tester);
      expect(upgrade.runs, 1);
    });
  }
}
