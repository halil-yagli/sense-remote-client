// Sense Remote (update plan 2026-11-21 §8, U7): the one-time move from version 2. Three
// branches of the setup file (older installed → upgrade; same / newer → information only; no
// role → the normal wizard), the macOS "Geçişi tamamla" flow, and never a sign-in or a
// registration on the way.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/sense_install_strings.dart';
import 'package:flutter_hbb/desktop/pages/sense_install_wizard.dart';

import 'sense_install_wizard_test.dart' show FakeBackend, pollPermissions;

String t(String key) => kSenseInstallTr[key]!;

class FakeUpgrade {
  int runs = 0;
  String result = '';
  Completer<String>? pending;

  Future<String> run() {
    runs++;
    return pending?.future ?? Future.value(result);
  }

  SenseUpgrade make(
          {SenseUpgradeMode mode = SenseUpgradeMode.upgrade,
          int installed = 0,
          int current = 3,
          bool host = true,
          bool controller = false}) =>
      SenseUpgrade(
          mode: mode,
          installed: installed,
          current: current,
          host: host,
          controller: controller,
          run: run);
}

Future<int> pumpUpgrade(WidgetTester tester, FakeBackend backend,
    SenseUpgrade upgrade,
    {bool mac = false}) async {
  tester.view.physicalSize = const Size(860, 620);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var closes = 0;
  await tester.pumpWidget(MaterialApp(
    home: SenseInstallWizard(
      initialPath: r'C:\Program Files\SenseRemote',
      icon: const SizedBox(),
      backend: backend,
      mac: mac,
      upgrade: upgrade,
      onClose: () => closes++,
    ),
  ));
  await tester.pumpAndSettle();
  return closes;
}

/// Nothing of a new installation happened: no sign-in, no project list, no install, no
/// registration.
void expectNoEnrollment(FakeBackend backend) {
  expect(backend.loginStarts, 0);
  expect(backend.projectCalls, 0);
  expect(backend.installs, isEmpty);
  expect(backend.enrolls, isEmpty);
}

void main() {
  group('senseUpgradeMode', () {
    test('older installed version (version 2 writes none) → upgrade', () {
      expect(
          senseUpgradeMode(roleInstalled: true, installed: 0, current: 3),
          SenseUpgradeMode.upgrade);
      expect(
          senseUpgradeMode(roleInstalled: true, installed: 2, current: 3),
          SenseUpgradeMode.upgrade);
    });

    test('same or newer installed → information only, no downgrade', () {
      expect(
          senseUpgradeMode(roleInstalled: true, installed: 3, current: 3),
          SenseUpgradeMode.current);
      expect(
          senseUpgradeMode(roleInstalled: true, installed: 4, current: 3),
          SenseUpgradeMode.current);
    });

    test('no role or no version of this build → the normal wizard', () {
      expect(
          senseUpgradeMode(roleInstalled: false, installed: 0, current: 3),
          SenseUpgradeMode.none);
      expect(
          senseUpgradeMode(roleInstalled: true, installed: 0, current: 0),
          SenseUpgradeMode.none);
    });
  });

  group('senseMacBundleTrusted', () {
    test('root owned and not group / other writable', () {
      expect(senseMacBundleTrusted('0 755\n0 755\n0 755\n0 755\n0 755\n', 5),
          isTrue);
    });

    test('dragged over by the user or writable → the move is needed', () {
      expect(senseMacBundleTrusted('501 755\n0 755\n0 755\n0 755\n0 755', 5),
          isFalse);
      expect(senseMacBundleTrusted('0 755\n0 775\n0 755\n0 755\n0 755', 5),
          isFalse);
      expect(senseMacBundleTrusted('0 755\n0 755\n0 757\n0 755\n0 755', 5),
          isFalse);
    });

    test('unreadable output never offers the move', () {
      expect(senseMacBundleTrusted('', 5), isTrue);
      expect(senseMacBundleTrusted('501 755', 5), isTrue);
      expect(senseMacBundleTrusted('x y\n0 755\n0 755\n0 755\n0 755', 5),
          isTrue);
    });
  });

  group('Windows', () {
    testWidgets('older version: Güncelle runs the move, no sign-in',
        (tester) async {
      final backend = FakeBackend();
      final upgrade = FakeUpgrade();
      await pumpUpgrade(tester, backend, upgrade.make());

      expect(find.text(t('step-upgrade')), findsOneWidget);
      expect(find.text(t('step-account')), findsNothing);
      expect(
          find.textContaining('Bu bilgisayarda Sense Remote 2 kurulu. Sürüm 3'),
          findsOneWidget);

      await tester.tap(find.byKey(const Key('sense-upgrade-start')));
      await tester.pumpAndSettle();

      expect(upgrade.runs, 1);
      expect(find.text(t('upgrade-done-title')), findsOneWidget);
      expectNoEnrollment(backend);
    });

    testWidgets('declined administrator prompt shows the error and can retry',
        (tester) async {
      final backend = FakeBackend();
      final upgrade = FakeUpgrade()..result = 'cancelled';
      await pumpUpgrade(tester, backend, upgrade.make());

      await tester.tap(find.byKey(const Key('sense-upgrade-start')));
      await tester.pumpAndSettle();
      expect(find.text(t('upgrade-error-cancelled')), findsOneWidget);

      upgrade.result = '';
      await tester.tap(find.byKey(const Key('sense-upgrade-start')));
      await tester.pumpAndSettle();
      expect(upgrade.runs, 2);
      expect(find.text(t('upgrade-done-title')), findsOneWidget);
      expectNoEnrollment(backend);
    });

    testWidgets('buttons are disabled while the elevated step runs',
        (tester) async {
      final backend = FakeBackend();
      final upgrade = FakeUpgrade()..pending = Completer<String>();
      await pumpUpgrade(tester, backend, upgrade.make());

      await tester.tap(find.byKey(const Key('sense-upgrade-start')));
      await tester.pump();
      expect(find.text(t('upgrade-running')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-upgrade-start')));
      await tester.pump();
      expect(upgrade.runs, 1);

      upgrade.pending!.complete('failed');
      await tester.pumpAndSettle();
      expect(find.text(t('upgrade-error-failed')), findsOneWidget);
    });

    testWidgets('same version installed: only the information and Kapat',
        (tester) async {
      final backend = FakeBackend();
      final upgrade = FakeUpgrade();
      await pumpUpgrade(tester, backend,
          upgrade.make(mode: SenseUpgradeMode.current, installed: 3));

      expect(find.textContaining('Bu bilgisayarda Sense Remote 3 kurulu.'),
          findsOneWidget);
      expect(find.byKey(const Key('sense-upgrade-start')), findsNothing);
      expect(find.byKey(const Key('sense-upgrade-close')), findsOneWidget);
      expect(upgrade.runs, 0);
      expectNoEnrollment(backend);
    });

    testWidgets('native side answers not_newer: switches to the information',
        (tester) async {
      final backend = FakeBackend();
      final upgrade = FakeUpgrade()..result = 'not_newer';
      await pumpUpgrade(tester, backend, upgrade.make(installed: 2));

      await tester.tap(find.byKey(const Key('sense-upgrade-start')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sense-upgrade-close')), findsOneWidget);
      expect(find.byKey(const Key('sense-upgrade-start')), findsNothing);
    });

    testWidgets('no upgrade: the normal wizard starts with the sign-in',
        (tester) async {
      final backend = FakeBackend();
      tester.view.physicalSize = const Size(860, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SenseInstallWizard(
          initialPath: r'C:\Program Files\SenseRemote',
          icon: const SizedBox(),
          backend: backend,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(t('step-account')), findsOneWidget);
      expect(find.text(t('step-upgrade')), findsNothing);
    });
  });

  group('macOS', () {
    testWidgets('Geçişi tamamla → permissions → done, no sign-in',
        (tester) async {
      final backend = FakeBackend();
      final upgrade = FakeUpgrade();
      await pumpUpgrade(tester, backend, upgrade.make(host: true), mac: true);

      // No Applications check first: the role is installed, the app runs from there.
      expect(backend.inAppsCalls, 0);
      // The title and the button both read "Geçişi tamamla".
      expect(find.descendant(
              of: find.byKey(const Key('sense-upgrade-start')),
              matching: find.text(t('upgrade-mac-start'))),
          findsOneWidget);
      expect(find.textContaining('Uygulamalar klasörüne kopyalandı'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-upgrade-start')));
      await tester.pumpAndSettle();
      expect(upgrade.runs, 1);

      // The permissions step of the installation, for the installed role (Host).
      expect(find.byKey(const Key('sense-perm-screenRecording')), findsOneWidget);
      await pollPermissions(
          tester,
          backend,
          const SenseMacPermissions(
              screenRecording: true,
              accessibility: true,
              inputMonitoring: true));
      await tester.tap(find.byKey(const Key('sense-perm-next')));
      await tester.pumpAndSettle();

      expect(find.text(t('upgrade-done-title-mac')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-upgrade-finish-close')));
      expect(backend.finishes, [false]);
      expectNoEnrollment(backend);
    });
  });
}
