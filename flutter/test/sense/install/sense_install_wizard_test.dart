// Sense Remote: behaviour of the setup wizard (YH K1–K7). Every button, switch, chip and
// state of the steps; the golden images are in sense_install_golden_test.dart.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/strings/install.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_wizard.dart';

String t(String key, [Map<String, String> args = const {}]) =>
    senseInstallText(key, args);

const kUrl = 'https://panel.example.test/panel/istemci-onay/f1';
const kEmail = 'ad.soyad@sensedepartment.com';
const kCode = '482913';

const kMuseum = SenseProject('prj_1', 'Örnek Müze', [
  SenseLocation('loc_1', 'Lobi'),
  SenseLocation('loc_2', 'Ana salon'),
  SenseLocation('loc_3', 'Galeri 1'),
  SenseLocation('loc_4', 'Kubbe'),
]);
const kFair = SenseProject('prj_2', 'Örnek Fuar Standı', [SenseLocation('loc_5', 'Stand')]);
const kOffice = SenseProject('prj_3', 'Ofis');

class FakeBackend implements SenseInstallBackend {
  int loginStarts = 0;
  int loginCancels = 0;
  final opened = <String>[];
  final copied = <String>[];
  SenseLoginStatus status = const SenseLoginStatus('requesting');

  int optionCalls = 0;
  SenseInstallOptions options = const SenseInstallOptions.ok([kMuseum, kFair, kOffice]);

  bool notEmpty = false;
  final folderChecks = <String>[];

  final installs = <SenseInstallRequest>[];
  Completer<String>? pendingInstall;
  String installResult = '';

  final enrolls = <SenseEnrollRequest>[];
  Completer<SenseEnrollResult>? pendingEnroll;
  SenseEnrollResult enrollResult = const SenseEnrollResult.ok(['Örnek Müze'], 'Galeri 1');

  final finishes = <bool>[];

  @override
  Future<void> loginStart() async => loginStarts++;

  @override
  Future<SenseLoginStatus> loginStatus() async => status;

  @override
  Future<void> loginCancel() async => loginCancels++;

  @override
  Future<void> openUrl(String url) async => opened.add(url);

  @override
  Future<void> copy(String text) async => copied.add(text);

  @override
  Future<SenseInstallOptions> installOptions() async {
    optionCalls++;
    return options;
  }

  @override
  Future<bool> folderNotEmpty(String path) async {
    folderChecks.add(path);
    return notEmpty;
  }

  @override
  Future<String> install(SenseInstallRequest request) {
    installs.add(request);
    return pendingInstall?.future ?? Future.value(installResult);
  }

  @override
  Future<SenseEnrollResult> enroll(SenseEnrollRequest request) {
    enrolls.add(request);
    return pendingEnroll?.future ?? Future.value(enrollResult);
  }

  @override
  void finish(bool openApp) => finishes.add(openApp);

  // macOS.
  bool inApps = true;
  int inAppsCalls = 0;
  SenseMacPermissions permissions = const SenseMacPermissions();
  int permissionReads = 0;
  final openedPermissions = <SenseMacPermission>[];
  int agentRestarts = 0;
  String restartResult = '';

  @override
  Future<bool> inApplications() async {
    inAppsCalls++;
    return inApps;
  }

  @override
  Future<SenseMacPermissions> macPermissions() async {
    permissionReads++;
    return permissions;
  }

  @override
  Future<void> openMacPermission(SenseMacPermission permission) async =>
      openedPermissions.add(permission);

  @override
  Future<String> restartAgent() async {
    agentRestarts++;
    return restartResult;
  }
}

/// A few frames; never waits for the spinners (they turn for ever).
Future<void> frames(WidgetTester tester, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pumpWizard(WidgetTester tester, FakeBackend backend,
    {bool mac = false,
    SenseUpgrade? upgrade,
    String version = '4',
    Future<String?> Function(String)? onPickPath,
    VoidCallback? onClose}) async {
  tester.view.physicalSize = kSenseInstallSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: senseTheme(),
    home: Scaffold(
      body: SenseInstallWizard(
        key: const Key('golden'),
        initialPath: r'C:\Program Files\Sense Remote',
        backend: backend,
        mac: mac,
        upgrade: upgrade,
        version: version,
        onPickPath: onPickPath,
        onClose: onClose,
      ),
    ),
  ));
  await frames(tester);
}

Future<void> tapFinder(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await frames(tester, 2);
  await tester.tap(f);
  await frames(tester);
}

Future<void> tap(WidgetTester tester, String key) => tapFinder(tester, find.byKey(Key(key)));

/// The switch of a setting row.
Future<void> tapToggle(WidgetTester tester, String key) => tapFinder(tester,
    find.descendant(of: find.byKey(Key(key)), matching: find.byType(SenseToggle)));

/// Advances the sign-in poll (every second).
Future<void> poll(WidgetTester tester, SenseLoginStatus status, FakeBackend backend) async {
  backend.status = status;
  await tester.pump(const Duration(seconds: 1));
  await frames(tester);
}

const kWaiting = SenseLoginStatus('waiting', url: kUrl, pairingCode: kCode);
const kDone = SenseLoginStatus('done', email: kEmail, displayName: 'Ad Soyad');

Future<void> signIn(WidgetTester tester, FakeBackend backend,
    {SenseLoginStatus done = kDone}) async {
  await tap(tester, 'sense-google');
  await poll(tester, kWaiting, backend);
  await poll(tester, done, backend);
}

Future<void> toRole(WidgetTester tester, FakeBackend backend) async {
  await signIn(tester, backend);
  await tap(tester, 'sense-account-next');
}

Future<void> toInfo(WidgetTester tester, FakeBackend backend,
    {bool host = true, bool controller = false}) async {
  await toRole(tester, backend);
  if (host) await tap(tester, 'sense-role-host');
  if (controller) await tap(tester, 'sense-role-controller');
  await tap(tester, 'sense-role-next');
}

Future<void> fillInfo(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('sense-name')), 'Galeri kioskı');
  await tap(tester, 'sense-project-prj_1');
  await tap(tester, 'sense-location-loc_3');
}

Future<void> toSummary(WidgetTester tester, FakeBackend backend,
    {bool host = true, bool controller = false}) async {
  await toInfo(tester, backend, host: host, controller: controller);
  await fillInfo(tester);
  await tap(tester, 'sense-info-next');
}

SenseButton button(WidgetTester tester, String key) =>
    tester.widget<SenseButton>(find.byKey(Key(key)));

bool enabled(WidgetTester tester, String key) => button(tester, key).onPressed != null;

SenseInstallStep? currentStep(WidgetTester tester) {
  for (final step in SenseInstallStep.values) {
    final f = find.byKey(Key('sense-step-${step.name}'));
    if (f.evaluate().isEmpty) continue;
    if (tester.widget<Semantics>(f).properties.selected == true) return step;
  }
  return null;
}

void main() {
  group('model', () {
    test('install options with panel locations', () {
      final o = SenseInstallOptions.fromJson(jsonEncode({
        'ok': true,
        'projects': [
          {
            'id': 'prj_1',
            'name': 'Örnek Müze',
            'locations': [
              {'id': 'loc_1', 'name': 'Lobi'},
              {'location_id': 'loc_2', 'name': 'Galeri 1'},
            ],
          },
          {'id': 'prj_2', 'name': 'Ofis'},
        ],
      }));
      expect(o.ok, isTrue);
      expect(o.projects.first.locations.map((l) => l.id), ['loc_1', 'loc_2']);
      expect(o.projects.last.locations, isEmpty);
      expect(SenseInstallOptions.fromJson('{"ok":false,"error":"network"}').error, 'network');
      expect(SenseInstallOptions.fromJson('nonsense').error, 'retry');
    });

    test('registration body: location id and name, no new projects', () {
      final body = jsonDecode(const SenseEnrollRequest(
        name: 'Galeri kioskı',
        locationId: 'loc_3',
        locationName: 'Galeri 1',
        note: '',
        projectIds: ['prj_1'],
      ).toJson()) as Map<String, dynamic>;
      expect(body['location_id'], 'loc_3');
      expect(body['location'], 'Galeri 1');
      expect(body['project_ids'], ['prj_1']);
      expect(body['new_projects'], isEmpty);
    });

    test('registration result keeps the location', () {
      final r = SenseEnrollResult.fromJson(jsonEncode({
        'ok': true,
        'projects': [
          {'name': 'Örnek Müze', 'created': false}
        ],
        'location': {'location_id': 'loc_3', 'name': 'Galeri 1'},
      }));
      expect(r.projects, ['Örnek Müze']);
      expect(r.location, 'Galeri 1');
    });

    test('new panel codes', () {
      expect(senseEnrollAction('location_not_found'), SenseEnrollAction.edit);
      expect(senseEnrollAction('permission_denied'), SenseEnrollAction.retry);
      expect(senseEnrollAction('token_invalid'), SenseEnrollAction.relogin);
      expect(senseEnrollAction('rate_limited'), SenseEnrollAction.wait);
      expect(senseEnrollAction('uuid_mismatch'), SenseEnrollAction.none);
      for (final code in ['permission_denied', 'location_not_found', 'project_not_found']) {
        expect(kSenseInstallTr.containsKey('enroll-$code'), isTrue, reason: code);
      }
    });

    test('company accounts only', () {
      expect(senseCompanyEmail('A.B@SenseDepartment.com'), isTrue);
      expect(senseCompanyEmail('ab@gmail.com'), isFalse);
      expect(senseCompanyEmail('ab@sensedepartment.com.evil.test'), isFalse);
    });

    test('Turkish only: no English text left', () {
      for (final v in kSenseInstallTr.values) {
        expect(v, isNot(contains('Install')));
        expect(v, isNot(contains('Sign in')));
      }
    });
  });

  group('K1 window and steps', () {
    testWidgets('Windows: five steps, version line, Kapat', (tester) async {
      final backend = FakeBackend();
      var closed = 0;
      await pumpWizard(tester, backend, onClose: () => closed++);
      for (final k in ['step-account', 'step-role', 'step-info', 'step-summary', 'step-done']) {
        expect(find.text(t(k)), findsOneWidget, reason: k);
      }
      expect(find.text(t('step-apps')), findsNothing);
      expect(find.text(t('step-permissions')), findsNothing);
      expect(find.text('Sürüm 4 · Windows'), findsOneWidget);
      expect(currentStep(tester), SenseInstallStep.account);
      await tap(tester, 'sense-window-close');
      expect(closed, 1);
    });

    testWidgets('macOS: seven steps, no close button of its own', (tester) async {
      await pumpWizard(tester, FakeBackend(), mac: true);
      expect(find.text(t('step-apps')), findsOneWidget);
      expect(find.text(t('step-permissions')), findsOneWidget);
      expect(find.text('Sürüm 4 · macOS'), findsOneWidget);
      expect(find.byKey(const Key('sense-window-close')), findsNothing);
    });

    testWidgets('no version: only the system', (tester) async {
      await pumpWizard(tester, FakeBackend(), version: '');
      expect(find.text('Windows'), findsOneWidget);
    });

    testWidgets('no gradient circle or card; transparent mark', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      for (final c in tester.widgetList<Container>(find.byType(Container))) {
        final d = c.decoration;
        if (d is BoxDecoration) expect(d.gradient, isNull);
      }
      expect(find.byType(SenseMark), findsNWidgets(2));
    });
  });

  group('K2 Sense account', () {
    testWidgets('idle: Google button, Devam closed', (tester) async {
      await pumpWizard(tester, FakeBackend());
      expect(find.text(t('google-sign-in')), findsOneWidget);
      expect(find.text(t('sign-in-note')), findsOneWidget);
      expect(find.text(t('domain-note')), findsOneWidget);
      expect(enabled(tester, 'sense-account-next'), isFalse);
    });

    testWidgets('code: 482 913, open, copy, cancel', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await tap(tester, 'sense-google');
      expect(backend.loginStarts, 1);
      expect(find.byKey(const Key('sense-login-requesting')), findsOneWidget);
      await poll(tester, kWaiting, backend);
      expect(find.text('482 913'), findsOneWidget);
      expect(find.text(t('waiting')), findsOneWidget);
      await tap(tester, 'sense-login-open');
      expect(backend.opened, [kUrl]);
      await tap(tester, 'sense-login-copy');
      expect(backend.copied, [kUrl]);
      expect(find.text(t('link-copied')), findsOneWidget);
      await tap(tester, 'sense-login-cancel');
      expect(backend.loginCancels, 1);
      expect(find.text(t('google-sign-in')), findsOneWidget);
    });

    testWidgets('done: green box with the account, Başka hesap', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await signIn(tester, backend);
      expect(find.text(kEmail), findsOneWidget);
      expect(find.text(t('verified')), findsOneWidget);
      expect(enabled(tester, 'sense-account-next'), isTrue);
      await tap(tester, 'sense-login-other');
      expect(backend.loginCancels, 1);
      expect(enabled(tester, 'sense-account-next'), isFalse);
    });

    testWidgets('time out: red box, Yeni kod al starts again', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await tap(tester, 'sense-google');
      await poll(tester, const SenseLoginStatus('failed', error: 'timeout'), backend);
      expect(find.text(t('login-timeout')), findsOneWidget);
      await tap(tester, 'sense-login-new-code');
      expect(backend.loginStarts, 2);
    });

    testWidgets('other failure shows the panel text and Yeniden dene', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await tap(tester, 'sense-google');
      await poll(tester, const SenseLoginStatus('failed', error: 'failed', detail: 'Hesap kapalı'),
          backend);
      expect(find.text('Hesap kapalı'), findsOneWidget);
      await tap(tester, 'sense-login-retry');
      expect(backend.loginStarts, 2);
    });

    testWidgets('account outside the company is refused', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await signIn(tester, backend, done: const SenseLoginStatus('done', email: 'kisi@gmail.com'));
      expect(find.text(t('login-domain')), findsOneWidget);
      expect(backend.loginCancels, 1);
      expect(enabled(tester, 'sense-account-next'), isFalse);
    });
  });

  group('K3 role', () {
    testWidgets('Devam closed until a role is chosen; summary follows', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toRole(tester, backend);
      expect(currentStep(tester), SenseInstallStep.role);
      expect(find.text(t('role-none')), findsOneWidget);
      expect(enabled(tester, 'sense-role-next'), isFalse);
      await tap(tester, 'sense-role-host');
      expect(find.text(t('role-sum-host')), findsOneWidget);
      expect(enabled(tester, 'sense-role-next'), isTrue);
      await tap(tester, 'sense-role-controller');
      expect(find.text(t('role-sum-both')), findsOneWidget);
      await tap(tester, 'sense-role-host');
      expect(find.text(t('role-sum-controller')), findsOneWidget);
      await tap(tester, 'sense-role-controller');
      expect(enabled(tester, 'sense-role-next'), isFalse);
      await tap(tester, 'sense-back');
      expect(currentStep(tester), SenseInstallStep.account);
    });
  });

  group('K4 details', () {
    testWidgets('only assigned projects; location from the chosen project', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toInfo(tester, backend);
      expect(backend.optionCalls, 1);
      expect(find.text(t('projects-label', {'n': '3'})), findsOneWidget);
      expect(find.text(t('location-first')), findsOneWidget);
      expect(find.text(t('info-missing')), findsOneWidget);
      expect(enabled(tester, 'sense-info-next'), isFalse);
      await tester.enterText(find.byKey(const Key('sense-name')), 'Galeri kioskı');
      await tap(tester, 'sense-project-prj_1');
      for (final l in ['Lobi', 'Ana salon', 'Galeri 1', 'Kubbe']) {
        expect(find.text(l), findsOneWidget);
      }
      expect(enabled(tester, 'sense-info-next'), isFalse);
      await tap(tester, 'sense-location-loc_3');
      expect(enabled(tester, 'sense-info-next'), isTrue);
      expect(find.text(t('info-missing')), findsNothing);
      // Dropping the project drops its location.
      await tap(tester, 'sense-project-prj_1');
      expect(enabled(tester, 'sense-info-next'), isFalse);
      expect(find.text(t('location-first')), findsOneWidget);
    });

    testWidgets('two projects: the location chips name their project', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toInfo(tester, backend);
      await tap(tester, 'sense-project-prj_1');
      await tap(tester, 'sense-project-prj_2');
      expect(find.textContaining('Stand', findRichText: true), findsWidgets);
      final chip = tester.widget<SenseInteractive>(find.byKey(const Key('sense-location-loc_5')));
      expect(chip.semanticLabel, 'Örnek Fuar Standı Stand');
    });

    testWidgets('name at most 64, note at most 300', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toInfo(tester, backend);
      await tester.enterText(find.byKey(const Key('sense-name')), 'a' * 80);
      await tester.enterText(find.byKey(const Key('sense-note')), 'b' * 400);
      await frames(tester);
      expect(tester.widget<TextField>(find.byKey(const Key('sense-name'))).controller!.text.length,
          kSenseMaxName);
      expect(tester.widget<TextField>(find.byKey(const Key('sense-note'))).controller!.text.length,
          kSenseMaxNote);
    });

    testWidgets('no project: orange box, can not go on, updates by itself', (tester) async {
      final backend = FakeBackend()..options = const SenseInstallOptions.ok([]);
      await pumpWizard(tester, backend);
      await toInfo(tester, backend);
      await tester.enterText(find.byKey(const Key('sense-name')), 'Galeri kioskı');
      await frames(tester);
      expect(find.byKey(const Key('sense-projects-none')), findsOneWidget);
      expect(find.text(t('projects-label', {'n': '0'})), findsOneWidget);
      expect(enabled(tester, 'sense-info-next'), isFalse);
      // The panel makes the employee a member: the next read (10 s) shows the project.
      backend.options = const SenseInstallOptions.ok([kMuseum]);
      await tester.pump(kSenseOptionsPoll);
      await frames(tester);
      expect(backend.optionCalls, 2);
      expect(find.byKey(const Key('sense-projects-none')), findsNothing);
      expect(find.byKey(const Key('sense-project-prj_1')), findsOneWidget);
    });

    testWidgets('project without locations: orange box until one is added', (tester) async {
      final backend = FakeBackend()..options = const SenseInstallOptions.ok([kOffice]);
      await pumpWizard(tester, backend);
      await toInfo(tester, backend);
      await tester.enterText(find.byKey(const Key('sense-name')), 'Ofis PC');
      await tap(tester, 'sense-project-prj_3');
      expect(find.byKey(const Key('sense-location-none')), findsOneWidget);
      expect(find.textContaining('Projeler › Ofis › Yerler'), findsOneWidget);
      expect(enabled(tester, 'sense-info-next'), isFalse);
      backend.options = const SenseInstallOptions.ok(
          [SenseProject('prj_3', 'Ofis', [SenseLocation('loc_9', 'Toplantı odası')])]);
      await tester.pump(kSenseOptionsPoll);
      await frames(tester);
      expect(find.byKey(const Key('sense-location-none')), findsNothing);
      await tap(tester, 'sense-location-loc_9');
      expect(enabled(tester, 'sense-info-next'), isTrue);
    });

    testWidgets('project removed in the panel is unselected', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toInfo(tester, backend);
      await fillInfo(tester);
      backend.options = const SenseInstallOptions.ok([kFair]);
      await tester.pump(kSenseOptionsPoll);
      await frames(tester);
      expect(enabled(tester, 'sense-info-next'), isFalse);
    });

    testWidgets('list error: red box; token error leads to a new sign-in', (tester) async {
      final backend = FakeBackend()..options = const SenseInstallOptions.error('network');
      await pumpWizard(tester, backend);
      await toInfo(tester, backend);
      expect(find.text(t('projects-error-network')), findsOneWidget);
      backend.options = const SenseInstallOptions.ok([kMuseum]);
      await tap(tester, 'sense-projects-retry');
      expect(find.byKey(const Key('sense-project-prj_1')), findsOneWidget);
      backend.options = const SenseInstallOptions.error('token_invalid');
      await tester.pump(kSenseOptionsPoll);
      await frames(tester);
      await tap(tester, 'sense-projects-relogin');
      expect(currentStep(tester), SenseInstallStep.account);
    });

    testWidgets('Geri goes back to the role', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toInfo(tester, backend);
      await tap(tester, 'sense-back');
      expect(currentStep(tester), SenseInstallStep.role);
    });
  });

  group('K5 summary and install', () {
    testWidgets('tiles show what was chosen', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      expect(currentStep(tester), SenseInstallStep.summary);
      for (final v in [kEmail, 'Host', 'Galeri kioskı', 'Örnek Müze', 'Galeri 1',
          t('sum-update-value'), t('sum-password-value')]) {
        expect(find.text(v), findsOneWidget, reason: v);
      }
      expect(find.text(t('summary-lead')), findsOneWidget);
      expect(find.text(t('install-note')), findsOneWidget);
    });

    testWidgets('e-mail tile: one line with an ellipsis, never broken mid-word', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      final value = tester.widget<Text>(find.byKey(Key('sense-tile-value-${t('sum-account')}')));
      expect(value.maxLines, 1);
      expect(value.overflow, TextOverflow.ellipsis);
      // A value with spaces (project names) still wraps.
      final projects = tester.widget<Text>(find.byKey(Key('sense-tile-value-${t('sum-projects')}')));
      expect(projects.maxLines, isNull);
    });

    testWidgets('Gelişmiş: the printer switch can be scrolled into view and used', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-advanced');
      final printer = find.byKey(const Key('sense-printer'));
      await tester.ensureVisible(printer);
      await tester.pump();
      expect(printer, findsOneWidget);
      await tapToggle(tester, 'sense-printer');
      expect(find.textContaining(t('advanced-printer')), findsWidgets);
    });

    testWidgets('Gelişmiş: closed category with folder and three switches', (tester) async {
      final backend = FakeBackend();
      String? asked;
      await pumpWizard(tester, backend, onPickPath: (current) async {
        asked = current;
        return r'D:\Araclar\Sense Remote';
      });
      await toSummary(tester, backend);
      expect(find.text(t('install-path')), findsNothing);
      await tap(tester, 'sense-advanced');
      expect(find.text(t('install-path')), findsOneWidget);
      await tapToggle(tester, 'sense-start-menu');
      await tapToggle(tester, 'sense-desktop-icon');
      await tapToggle(tester, 'sense-printer');
      backend.notEmpty = true;
      await tap(tester, 'sense-change-path');
      expect(asked, r'C:\Program Files\Sense Remote');
      expect(find.byKey(const Key('sense-path-warning')), findsOneWidget);
      // Warning shown: the next Kur installs there (second step in place, no window).
      await tap(tester, 'sense-install');
      expect(backend.installs, hasLength(1));
      final r = backend.installs.single;
      expect(r.path, r'D:\Araclar\Sense Remote');
      expect(r.options, ' printer');
      expect(r.role, 'host');
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('Kur on a full default folder warns first', (tester) async {
      final backend = FakeBackend()..notEmpty = true;
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(backend.installs, isEmpty);
      expect(find.byKey(const Key('sense-path-warning')), findsOneWidget);
      await tap(tester, 'sense-install');
      expect(backend.installs, hasLength(1));
    });

    testWidgets('install then register: active in the panel without approval', (tester) async {
      final backend = FakeBackend()
        ..pendingInstall = Completer()
        ..pendingEnroll = Completer();
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(find.byKey(const Key('sense-installing')), findsOneWidget);
      expect(enabled(tester, 'sense-install'), isFalse);
      expect(enabled(tester, 'sense-back'), isFalse);
      expect(tester.widget<SenseInteractive>(find.byKey(const Key('sense-window-close'))).onTap,
          isNull);
      backend.pendingInstall!.complete('');
      await frames(tester);
      expect(find.byKey(const Key('sense-registering')), findsOneWidget);
      final e = backend.enrolls.single;
      expect(e.projectIds, ['prj_1']);
      expect(e.locationId, 'loc_3');
      expect(e.name, 'Galeri kioskı');
      backend.pendingEnroll!.complete(const SenseEnrollResult.ok(['Örnek Müze'], 'Galeri 1'));
      await frames(tester);
      expect(currentStep(tester), SenseInstallStep.done);
      expect(find.text(t('done-panel', {'projects': 'Örnek Müze', 'location': 'Galeri 1'})),
          findsOneWidget);
    });

    testWidgets('administrator prompt declined: red box, nothing installed', (tester) async {
      final backend = FakeBackend()..installResult = 'cancelled';
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(find.text(t('error-cancelled')), findsOneWidget);
      expect(backend.enrolls, isEmpty);
      expect(enabled(tester, 'sense-install'), isTrue);
      backend.installResult = '';
      await tap(tester, 'sense-install');
      expect(currentStep(tester), SenseInstallStep.done);
    });

    testWidgets('unknown install error: general text', (tester) async {
      final backend = FakeBackend()..installResult = 'x-strange';
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(find.text(t('error-failed')), findsOneWidget);
      expect(find.text(t('error-failed-hint')), findsOneWidget);
    });

    testWidgets('panel not reachable: Yeniden dene / Kaydı atla', (tester) async {
      final backend = FakeBackend()..enrollResult = const SenseEnrollResult.error('network');
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(find.text(t('register-failed')), findsOneWidget);
      expect(find.text(t('enroll-network')), findsOneWidget);
      await tap(tester, 'sense-enroll-retry');
      expect(backend.enrolls, hasLength(2));
      expect(backend.installs, hasLength(1));
      await tap(tester, 'sense-enroll-skip');
      expect(currentStep(tester), SenseInstallStep.done);
      expect(find.text(t('done-panel-skipped')), findsOneWidget);
    });

    testWidgets('rate limited: Yeniden dene waits 60 s', (tester) async {
      final backend = FakeBackend()..enrollResult = const SenseEnrollResult.error('rate_limited');
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(enabled(tester, 'sense-enroll-retry'), isFalse);
      await tester.pump(const Duration(seconds: 61));
      await frames(tester);
      expect(enabled(tester, 'sense-enroll-retry'), isTrue);
    });

    testWidgets('permission_denied: the right text, retry and new sign-in', (tester) async {
      final backend = FakeBackend()
        ..enrollResult = const SenseEnrollResult.error('permission_denied');
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(find.text(t('enroll-permission_denied')), findsOneWidget);
      expect(find.byKey(const Key('sense-enroll-retry')), findsOneWidget);
      expect(find.byKey(const Key('sense-enroll-relogin')), findsOneWidget);
    });

    testWidgets('location_not_found: fix the details, then it registers again', (tester) async {
      final backend = FakeBackend()
        ..enrollResult = const SenseEnrollResult.error('location_not_found');
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(find.text(t('enroll-location_not_found')), findsOneWidget);
      await tap(tester, 'sense-enroll-edit');
      expect(currentStep(tester), SenseInstallStep.info);
      backend.enrollResult = const SenseEnrollResult.ok(['Örnek Müze'], 'Kubbe');
      await tap(tester, 'sense-location-loc_4');
      await tap(tester, 'sense-info-next');
      expect(backend.enrolls.last.locationId, 'loc_4');
      expect(backend.installs, hasLength(1));
      expect(currentStep(tester), SenseInstallStep.done);
    });

    testWidgets('token_invalid: sign in again, then register', (tester) async {
      final backend = FakeBackend()..enrollResult = const SenseEnrollResult.error('token_invalid');
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      await tap(tester, 'sense-enroll-relogin');
      expect(currentStep(tester), SenseInstallStep.account);
      backend.enrollResult = const SenseEnrollResult.ok(['Örnek Müze'], 'Galeri 1');
      await signIn(tester, backend);
      await tap(tester, 'sense-account-next');
      expect(backend.enrolls, hasLength(2));
      expect(currentStep(tester), SenseInstallStep.done);
    });

    testWidgets('uuid_mismatch: only Kaydı atla', (tester) async {
      final backend = FakeBackend()..enrollResult = const SenseEnrollResult.error('uuid_mismatch');
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(find.byKey(const Key('sense-enroll-retry')), findsNothing);
      expect(find.byKey(const Key('sense-enroll-skip')), findsOneWidget);
    });
  });

  group('K6 macOS permissions', () {
    Future<void> toPermissions(WidgetTester tester, FakeBackend backend,
        {bool host = true, bool controller = false}) async {
      await pumpWizard(tester, backend, mac: true);
      await toSummary(tester, backend, host: host, controller: controller);
      await tap(tester, 'sense-install');
    }

    Future<void> read(WidgetTester tester, FakeBackend backend, SenseMacPermissions p) async {
      backend.permissions = p;
      await tester.pump(const Duration(seconds: 1));
      await frames(tester);
    }

    String status(WidgetTester tester, SenseMacPermission p) =>
        tester.widget<SenseChip>(find.byKey(Key('sense-perm-status-${p.name}'))).label;

    testWidgets('Applications folder first; outside it the wizard waits', (tester) async {
      final backend = FakeBackend()..inApps = false;
      await pumpWizard(tester, backend, mac: true);
      expect(find.byKey(const Key('sense-apps-outside')), findsOneWidget);
      backend.inApps = true;
      await tap(tester, 'sense-apps-recheck');
      expect(currentStep(tester), SenseInstallStep.account);
    });

    testWidgets('rows turn green by themselves', (tester) async {
      final backend = FakeBackend();
      await toPermissions(tester, backend);
      expect(currentStep(tester), SenseInstallStep.permissions);
      expect(find.text(t('installing-mac')), findsNothing);
      expect(status(tester, SenseMacPermission.screenRecording), t('perm-missing'));
      await tap(tester, 'sense-perm-open-screenRecording');
      expect(backend.openedPermissions, [SenseMacPermission.screenRecording]);
      await read(tester, backend, const SenseMacPermissions(screenRecording: true));
      expect(status(tester, SenseMacPermission.screenRecording), t('perm-granted'));
      expect(backend.agentRestarts, 1);
      expect(button(tester, 'sense-perm-open-accessibility').kind, SenseButtonKind.primary);
      await read(tester, backend, const SenseMacPermissions(
          screenRecording: true, accessibility: true, inputMonitoring: true));
      await tap(tester, 'sense-perm-next');
      expect(currentStep(tester), SenseInstallStep.done);
    });

    testWidgets('Daha sonra: warning in place, then Yine de devam et', (tester) async {
      final backend = FakeBackend();
      await toPermissions(tester, backend);
      await read(tester, backend, const SenseMacPermissions());
      await tap(tester, 'sense-perm-later');
      expect(find.byKey(const Key('sense-perm-warning')), findsOneWidget);
      expect(currentStep(tester), SenseInstallStep.permissions);
      await tap(tester, 'sense-perm-later');
      expect(currentStep(tester), SenseInstallStep.done);
      expect(find.text(t('done-permissions-missing')), findsOneWidget);
    });

    testWidgets('Controller needs only Input Monitoring', (tester) async {
      final backend = FakeBackend();
      await toPermissions(tester, backend, host: false, controller: true);
      await read(tester, backend, const SenseMacPermissions());
      expect(find.byKey(const Key('sense-perm-inputMonitoring')), findsOneWidget);
      expect(find.byKey(const Key('sense-perm-screenRecording')), findsNothing);
      expect(find.text(t('perm-lead-one')), findsOneWidget);
    });
  });

  group('K7 done', () {
    testWidgets('Host: lines and only Kapat', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toSummary(tester, backend);
      await tap(tester, 'sense-install');
      expect(find.text(t('done-title')), findsWidgets);
      expect(find.text(t('done-host')), findsOneWidget);
      expect(find.text(t('done-locked')), findsOneWidget);
      expect(find.byKey(const Key('sense-finish-open')), findsNothing);
      await tap(tester, 'sense-finish-close');
      expect(backend.finishes, [false]);
    });

    testWidgets('Controller: Sense Remote\'u aç', (tester) async {
      final backend = FakeBackend();
      await pumpWizard(tester, backend);
      await toSummary(tester, backend, host: false, controller: true);
      expect(find.text(t('summary-lead-controller')), findsOneWidget);
      await tap(tester, 'sense-install');
      expect(find.text(t('done-host')), findsNothing);
      await tap(tester, 'sense-finish-open');
      expect(backend.finishes, [true]);
    });
  });
}
