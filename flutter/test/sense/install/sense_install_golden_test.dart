// Sense Remote: golden images of the setup wizard, one per prototype image (YH K1–K7,
// Calisma/dokuman/img/i01–i09.png). 860 × 620 like the setup window; the images are
// compared with the prototype by eye before they are accepted (İnşa planı §5).

import 'dart:io';

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

/// The goldens of all screens are made centrally in one run once the screens are merged
/// (main session decision, 2026-11-23); until a file exists its test is skipped, so the PR
/// check does not fail on a missing image. `--update-goldens` always runs them.
bool _missing(String name) =>
    !autoUpdateGoldenFiles && !File('test/goldens/install/$name.png').existsSync();

void main() {
  testWidgets('i01 Sense hesabı · bekliyor', (tester) async {
    await pumpWizard(tester, FakeBackend());
    await golden(tester, 'i01_account');
  }, skip: _missing('i01_account'), tags: const ['golden']);

  testWidgets('i02 Sense hesabı · eşleştirme kodu', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await tap(tester, 'sense-google');
    await poll(tester, kWaiting, backend);
    await golden(tester, 'i02_code');
  }, skip: _missing('i02_code'), tags: const ['golden']);

  testWidgets('K2 Sense hesabı · doğrulandı', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await signIn(tester, backend);
    await golden(tester, 'k2_account_done');
  }, skip: _missing('k2_account_done'), tags: const ['golden']);

  testWidgets('K2 Sense hesabı · süre doldu', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await tap(tester, 'sense-google');
    await poll(tester, const SenseLoginStatus('failed', error: 'timeout'), backend);
    await golden(tester, 'k2_account_timeout');
  }, skip: _missing('k2_account_timeout'), tags: const ['golden']);

  testWidgets('i03 rol · Host', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await toRole(tester, backend);
    await tap(tester, 'sense-role-host');
    await golden(tester, 'i03_role');
  }, skip: _missing('i03_role'), tags: const ['golden']);

  testWidgets('i04 bilgisayar bilgisi', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await toInfo(tester, backend);
    await fillInfo(tester);
    await golden(tester, 'i04_info');
  }, skip: _missing('i04_info'), tags: const ['golden']);

  testWidgets('i05 bilgisayar bilgisi · projesiz', (tester) async {
    final backend = FakeBackend()..options = const SenseInstallOptions.ok([]);
    await pumpWizard(tester, backend);
    await toInfo(tester, backend);
    await golden(tester, 'i05_info_no_project');
  }, skip: _missing('i05_info_no_project'), tags: const ['golden']);

  testWidgets('K4 bilgisayar bilgisi · yer yok', (tester) async {
    final backend = FakeBackend()..options = const SenseInstallOptions.ok([kOffice]);
    await pumpWizard(tester, backend);
    await toInfo(tester, backend);
    await tester.enterText(find.byKey(const Key('sense-name')), 'Ofis PC');
    await tap(tester, 'sense-project-prj_3');
    await golden(tester, 'k4_info_no_location');
  }, skip: _missing('k4_info_no_location'), tags: const ['golden']);

  testWidgets('i06 özet · Gelişmiş açık', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await toSummary(tester, backend);
    await tap(tester, 'sense-advanced');
    // The window scrolls: bring the last row (Sense Remote yazıcısı) into the image.
    await tester.ensureVisible(find.byKey(const Key('sense-printer')));
    await tester.pump();
    await golden(tester, 'i06_summary');
  }, skip: _missing('i06_summary'), tags: const ['golden']);

  testWidgets('K5 özet · panele kayıt yapılamadı', (tester) async {
    final backend = FakeBackend()..enrollResult = const SenseEnrollResult.error('network');
    await pumpWizard(tester, backend);
    await toSummary(tester, backend);
    await tap(tester, 'sense-install');
    await golden(tester, 'k5_register_failed');
  }, skip: _missing('k5_register_failed'), tags: const ['golden']);

  testWidgets('i07 macOS izinleri', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend, mac: true);
    await toSummary(tester, backend);
    await tap(tester, 'sense-install');
    backend.permissions = const SenseMacPermissions(screenRecording: true);
    await tester.pump(const Duration(seconds: 1));
    await frames(tester);
    await golden(tester, 'i07_mac_permissions');
  }, skip: _missing('i07_mac_permissions'), tags: const ['golden']);

  testWidgets('i08 Kuruldu · Host', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await toSummary(tester, backend);
    await tap(tester, 'sense-install');
    await golden(tester, 'i08_done');
  }, skip: _missing('i08_done'), tags: const ['golden']);

  testWidgets('i09 güncelleme · Sürüm 3 → 4', (tester) async {
    await pumpWizard(tester, FakeBackend(), upgrade: FakeUpgrade().make());
    await golden(tester, 'i09_upgrade');
  }, skip: _missing('i09_upgrade'), tags: const ['golden']);
}
