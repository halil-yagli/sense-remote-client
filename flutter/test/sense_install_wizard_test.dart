// Sense Remote: widget tests for the Sense setup wizard (steps, role, info, install result).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/pages/sense_install_strings.dart';
import 'package:flutter_hbb/desktop/pages/sense_install_wizard.dart';

String t(String key) => kSenseInstallTr[key]!;

class Harness {
  final requests = <SenseInstallRequest>[];
  final finishes = <bool>[];
  Completer<String>? pending;
  String result = '';

  Widget build() => MaterialApp(
        home: SenseInstallWizard(
          initialPath: r'C:\Program Files\SenseRemote',
          icon: const SizedBox(),
          onInstall: (request) {
            requests.add(request);
            final completer = pending;
            return completer != null
                ? completer.future
                : Future.value(result);
          },
          onFinish: finishes.add,
        ),
      );
}

Future<void> pumpWizard(WidgetTester tester, Harness harness) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(harness.build());
  await tester.pumpAndSettle();
}

Finder get next => find.byKey(const Key('sense-next'));

bool enabled(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).onPressed != null;

Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Role step -> info step -> summary step with the given choices.
Future<void> goToSummary(WidgetTester tester,
    {bool host = true, bool controller = false}) async {
  if (host) await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
  if (controller) {
    await tapAndSettle(tester, find.byKey(const Key('sense-role-controller')));
  }
  await tapAndSettle(tester, next);
  await tester.enterText(find.byKey(const Key('sense-name')), '  Galeri kioskı ');
  await tester.enterText(find.byKey(const Key('sense-project')), 'Örnek Müze');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('sense-project')), 'örnek müze');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
  // Typed but not confirmed with Enter: still added on "Devam".
  await tester.enterText(find.byKey(const Key('sense-project')), 'Ekip');
  await tester.enterText(find.byKey(const Key('sense-location')), 'Galeri 1');
  await tapAndSettle(tester, next);
}

void main() {
  testWidgets('starts at the role step; account step is marked as coming soon',
      (tester) async {
    final harness = Harness();
    await pumpWizard(tester, harness);

    expect(find.text(t('step-account')), findsOneWidget);
    expect(find.text(t('soon')), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Controller'), findsOneWidget);
    expect(find.textContaining('RustDesk'), findsNothing);
    expect(enabled(tester, next), isFalse);
    expect(find.text(t('no-role')), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
    expect(enabled(tester, next), isTrue);
    expect(find.text('Host.'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('sense-role-controller')));
    expect(find.text('Host + Controller${t('both-desc')}'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
    expect(find.text('Controller.'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('sense-role-controller')));
    expect(enabled(tester, next), isFalse);
  });

  testWidgets('info step needs a computer name', (tester) async {
    final harness = Harness();
    await pumpWizard(tester, harness);
    await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
    await tapAndSettle(tester, next);

    expect(find.byKey(const Key('sense-name')), findsOneWidget);
    expect(enabled(tester, next), isFalse);
    await tester.enterText(find.byKey(const Key('sense-name')), '   ');
    await tester.pump();
    expect(enabled(tester, next), isFalse);
    await tester.enterText(find.byKey(const Key('sense-name')), 'Kiosk');
    await tester.pump();
    expect(enabled(tester, next), isTrue);

    await tapAndSettle(tester, find.text(t('back')));
    expect(find.byKey(const Key('sense-role-host')), findsOneWidget);
  });

  testWidgets('summary -> install -> installed, with the chosen role and info',
      (tester) async {
    final harness = Harness()..pending = Completer<String>();
    await pumpWizard(tester, harness);
    await goToSummary(tester, host: true, controller: true);

    final summary = find.byKey(const Key('sense-summary'));
    expect(summary, findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('Host + Controller')),
        findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text('Galeri kioskı')),
        findsOneWidget);
    expect(
        find.descendant(of: summary, matching: find.text('Örnek Müze, Ekip')),
        findsOneWidget);
    expect(find.descendant(of: summary, matching: find.text(t('update-value'))),
        findsOneWidget);
    expect(
        find.descendant(of: summary, matching: find.text(t('password-value'))),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('sense-install')));
    await tester.pump();
    expect(find.text(t('installing')), findsOneWidget);
    expect(enabled(tester, find.byKey(const Key('sense-install'))), isFalse);

    expect(harness.requests, hasLength(1));
    final request = harness.requests.single;
    expect(request.role, 'both');
    expect(request.name, 'Galeri kioskı');
    expect(request.projects, ['Örnek Müze', 'Ekip']);
    expect(request.location, 'Galeri 1');
    expect(request.options, ' startmenu desktopicon');
    expect(request.path, r'C:\Program Files\SenseRemote');
    expect(jsonDecode(request.infoJson), {
      'name': 'Galeri kioskı',
      'projects': ['Örnek Müze', 'Ekip'],
      'location': 'Galeri 1',
      'note': '',
    });

    harness.pending!.complete('');
    await tester.pumpAndSettle();
    expect(find.text(t('done-title')), findsOneWidget);
    expect(find.byKey(const Key('sense-done')), findsOneWidget);
    expect(
        find.text('${t('done-lead')} ${t('done-lead-locked')}'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('sense-finish-open')));
    expect(harness.finishes, [true]);
  });

  testWidgets('declined administrator prompt stays on the summary',
      (tester) async {
    final harness = Harness()..result = 'cancelled';
    await pumpWizard(tester, harness);
    await goToSummary(tester);

    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(find.text(t('error-cancelled')), findsOneWidget);
    expect(find.byKey(const Key('sense-summary')), findsOneWidget);
    expect(enabled(tester, find.byKey(const Key('sense-install'))), isTrue);
    expect(harness.requests.single.role, 'host');
  });

  testWidgets('install errors are shown', (tester) async {
    final harness = Harness()..result = 'invalid-name';
    await pumpWizard(tester, harness);
    await goToSummary(tester, host: false, controller: true);
    expect(harness.requests, isEmpty);

    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(find.text(t('error-invalid-name')), findsOneWidget);
    expect(harness.requests.single.role, 'controller');

    harness.result = 'install failed with elevated exit code 1';
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(
        find.text(
            '${t('error-failed')}\ninstall failed with elevated exit code 1'),
        findsOneWidget);
  });

  testWidgets('advanced options change the install options', (tester) async {
    final harness = Harness();
    await pumpWizard(tester, harness);
    await goToSummary(tester);

    expect(find.text(t('desktop-icon')), findsNothing);
    await tapAndSettle(tester, find.byKey(const Key('sense-advanced')));
    expect(find.text(r'C:\Program Files\SenseRemote'), findsOneWidget);
    await tapAndSettle(tester, find.text(t('desktop-icon')));
    await tapAndSettle(tester, find.text(t('printer')));
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(harness.requests.single.options, ' startmenu printer');
  });

  test('role values match src/sense.rs', () {
    SenseInstallRequest request(bool host, bool controller) =>
        SenseInstallRequest(
          host: host,
          controller: controller,
          name: 'a',
          projects: const [],
          location: '',
          note: '',
          path: '',
          startMenu: false,
          desktopIcon: false,
          printer: false,
        );
    expect(request(true, false).role, 'host');
    expect(request(false, true).role, 'controller');
    expect(request(true, true).role, 'both');
    expect(request(true, true).options, '');
    expect(senseRoleLabel(true, true), 'Host + Controller');
  });

  test('every Turkish text has an English counterpart', () {
    expect(kSenseInstallTr.keys.toSet(), kSenseInstallEn.keys.toSet());
  });
}
