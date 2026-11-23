// Sense Remote: golden images of the setup wizard, one per prototype image (YH K1–K7,
// Calisma/dokuman/img/i01–i09.png). 860 × 620 like the setup window; the images are
// compared with the prototype by eye before they are accepted (İnşa planı §5).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_wizard.dart';

import 'sense_install_upgrade_test.dart' show FakeUpgrade;
import 'sense_install_wizard_test.dart';

/// The Google "G" is an SVG decoded off the test clock.
Future<void> settleImages(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
  await frames(tester);
}

Future<void> golden(WidgetTester tester, String name) async {
  await settleImages(tester);
  await expectLater(
      find.byKey(const Key('golden')), matchesGoldenFile('../../goldens/install/$name.png'));
}

void main() {
  testWidgets('i01 Sense hesabı · bekliyor', (tester) async {
    await pumpWizard(tester, FakeBackend());
    await golden(tester, 'i01_account');
  });

  testWidgets('i02 Sense hesabı · eşleştirme kodu', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await tap(tester, 'sense-google');
    await poll(tester, kWaiting, backend);
    await golden(tester, 'i02_code');
  });

  testWidgets('K2 Sense hesabı · doğrulandı', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await signIn(tester, backend);
    await golden(tester, 'k2_account_done');
  });

  testWidgets('K2 Sense hesabı · süre doldu', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await tap(tester, 'sense-google');
    await poll(tester, const SenseLoginStatus('failed', error: 'timeout'), backend);
    await golden(tester, 'k2_account_timeout');
  });

  testWidgets('i03 rol · Host', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await toRole(tester, backend);
    await tap(tester, 'sense-role-host');
    await golden(tester, 'i03_role');
  });

  testWidgets('i04 bilgisayar bilgisi', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await toInfo(tester, backend);
    await fillInfo(tester);
    await golden(tester, 'i04_info');
  });

  testWidgets('i05 bilgisayar bilgisi · projesiz', (tester) async {
    final backend = FakeBackend()..options = const SenseInstallOptions.ok([]);
    await pumpWizard(tester, backend);
    await toInfo(tester, backend);
    await golden(tester, 'i05_info_no_project');
  });

  testWidgets('K4 bilgisayar bilgisi · yer yok', (tester) async {
    final backend = FakeBackend()..options = const SenseInstallOptions.ok([kOffice]);
    await pumpWizard(tester, backend);
    await toInfo(tester, backend);
    await tester.enterText(find.byKey(const Key('sense-name')), 'Ofis PC');
    await tap(tester, 'sense-project-prj_3');
    await golden(tester, 'k4_info_no_location');
  });

  testWidgets('i06 özet · Gelişmiş açık', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await toSummary(tester, backend);
    await tap(tester, 'sense-advanced');
    await golden(tester, 'i06_summary');
  });

  testWidgets('K5 özet · panele kayıt yapılamadı', (tester) async {
    final backend = FakeBackend()..enrollResult = const SenseEnrollResult.error('network');
    await pumpWizard(tester, backend);
    await toSummary(tester, backend);
    await tap(tester, 'sense-install');
    await golden(tester, 'k5_register_failed');
  });

  testWidgets('i07 macOS izinleri', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend, mac: true);
    await toSummary(tester, backend);
    await tap(tester, 'sense-install');
    backend.permissions = const SenseMacPermissions(screenRecording: true);
    await tester.pump(const Duration(seconds: 1));
    await frames(tester);
    await golden(tester, 'i07_mac_permissions');
  });

  testWidgets('i08 Kuruldu · Host', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await toSummary(tester, backend);
    await tap(tester, 'sense-install');
    await golden(tester, 'i08_done');
  });

  testWidgets('i09 güncelleme · Sürüm 3 → 4', (tester) async {
    await pumpWizard(tester, FakeBackend(), upgrade: FakeUpgrade().make());
    await golden(tester, 'i09_upgrade');
  });
}
