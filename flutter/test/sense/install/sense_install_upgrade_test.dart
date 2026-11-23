// Sense Remote: move from an older version (YH K7 geçiş, i09; update plan §8, U7). Neither
// platform signs in or registers again; hesap, rol, proje ve kimlik korunur.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/strings/install.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_wizard.dart';

import 'sense_install_wizard_test.dart'
    show FakeBackend, frames, pumpWizard, tap, currentStep;

String t(String key, [Map<String, String> args = const {}]) =>
    senseInstallText(key, args);

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
          int installed = 3,
          int current = 4,
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

/// Nothing of a new installation happened: no sign-in, no project list, no install, no
/// registration (K7: hesap, rol, proje ve kimlik korunur).
void expectNoEnrollment(FakeBackend backend) {
  expect(backend.loginStarts, 0);
  expect(backend.optionCalls, 0);
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
    testWidgets('Sürüm 3 → 4: tiles, Güncelle runs the move, no sign-in', (tester) async {
      final backend = FakeBackend();
      final u = FakeUpgrade();
      await pumpWizard(tester, backend, upgrade: u.make());
      expect(find.text(t('step-upgrade')), findsOneWidget);
      expect(find.text(t('step-account')), findsNothing);
      expect(find.text(t('upgrade-lead', {'from': '3', 'to': '4'})), findsOneWidget);
      expect(find.text('Sürüm 3'), findsOneWidget);
      expect(find.text('Sürüm 4'), findsOneWidget);
      expect(find.text(t('upgrade-login-value')), findsOneWidget);
      await tap(tester, 'sense-upgrade-start');
      expect(u.runs, 1);
      expect(find.text(t('upgrade-done-title')), findsOneWidget);
      expectNoEnrollment(backend);
    });

    testWidgets('version 2 wrote no number: shown as Sürüm 2', (tester) async {
      final u = FakeUpgrade();
      await pumpWizard(tester, FakeBackend(), upgrade: u.make(installed: 0));
      expect(find.text('Sürüm 2'), findsOneWidget);
    });

    testWidgets('declined administrator prompt: red box, then retry', (tester) async {
      final backend = FakeBackend();
      final u = FakeUpgrade()..result = 'cancelled';
      await pumpWizard(tester, backend, upgrade: u.make());
      await tap(tester, 'sense-upgrade-start');
      expect(find.text(t('upgrade-error-cancelled')), findsOneWidget);
      u.result = '';
      await tap(tester, 'sense-upgrade-start');
      expect(find.text(t('upgrade-done-title')), findsOneWidget);
    });

    testWidgets('buttons are closed while the elevated step runs', (tester) async {
      final u = FakeUpgrade()..pending = Completer();
      await pumpWizard(tester, FakeBackend(), upgrade: u.make());
      await tap(tester, 'sense-upgrade-start');
      expect(find.byKey(const Key('sense-upgrade-running')), findsOneWidget);
      await tap(tester, 'sense-upgrade-start');
      expect(u.runs, 1);
      u.pending!.complete('failed');
      await frames(tester);
      expect(find.text(t('upgrade-error-failed')), findsOneWidget);
    });

    testWidgets('same version installed: only the information and Kapat', (tester) async {
      var closed = 0;
      final u = FakeUpgrade();
      await pumpWizard(tester, FakeBackend(),
          upgrade: u.make(mode: SenseUpgradeMode.current, installed: 4),
          onClose: () => closed++);
      expect(find.byKey(const Key('sense-upgrade-start')), findsNothing);
      await tap(tester, 'sense-upgrade-close');
      expect(closed, 1);
    });

    testWidgets('native side answers not_newer: switches to the information', (tester) async {
      final u = FakeUpgrade()..result = 'not_newer';
      await pumpWizard(tester, FakeBackend(), upgrade: u.make());
      await tap(tester, 'sense-upgrade-start');
      expect(find.byKey(const Key('sense-upgrade-close')), findsOneWidget);
      expect(find.byKey(const Key('sense-upgrade-start')), findsNothing);
    });

    testWidgets('Kapat on the done page closes the setup file', (tester) async {
      var closed = 0;
      final u = FakeUpgrade();
      await pumpWizard(tester, FakeBackend(), upgrade: u.make(), onClose: () => closed++);
      await tap(tester, 'sense-upgrade-start');
      await tap(tester, 'sense-upgrade-finish-close');
      expect(closed, 1);
    });

    testWidgets('no upgrade: the normal wizard starts with the sign-in', (tester) async {
      await pumpWizard(tester, FakeBackend());
      expect(currentStep(tester), SenseInstallStep.account);
      expect(find.text(t('step-upgrade')), findsNothing);
    });
  });

  group('macOS', () {
    testWidgets('Geçişi tamamla → permissions → done, no sign-in', (tester) async {
      final backend = FakeBackend()..inApps = true;
      final u = FakeUpgrade();
      await pumpWizard(tester, backend, mac: true, upgrade: u.make(controller: true));
      expect(find.text(t('upgrade-mac-start')), findsOneWidget);
      expect(find.text(t('upgrade-note-mac')), findsOneWidget);
      await tap(tester, 'sense-upgrade-start');
      expect(currentStep(tester), SenseInstallStep.permissions);
      backend.permissions = const SenseMacPermissions(
          screenRecording: true, accessibility: true, inputMonitoring: true);
      await tester.pump(const Duration(seconds: 1));
      await frames(tester);
      await tap(tester, 'sense-perm-next');
      expect(find.text(t('upgrade-done-title-mac')), findsOneWidget);
      await tap(tester, 'sense-upgrade-finish-open');
      expect(backend.finishes, [true]);
      expectNoEnrollment(backend);
      expect(backend.inAppsCalls, 0);
    });
  });
}
