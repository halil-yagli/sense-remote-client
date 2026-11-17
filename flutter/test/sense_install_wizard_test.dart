// Sense Remote: widget tests for the Sense setup wizard (wave 3 I6: Sense sign-in with the
// pairing code, panel projects, install, panel registration with retry / skip).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common/widgets/login.dart';
import 'package:flutter_hbb/desktop/pages/sense_install_strings.dart';
import 'package:flutter_hbb/desktop/pages/sense_install_wizard.dart';

String t(String key) => kSenseInstallTr[key]!;

const kUrl = 'https://remote.snsdpt.com/panel/istemci-onay/f1';
const kEmail = 'ad.soyad@sensedepartment.com';

class FakeBackend implements SenseInstallBackend {
  int loginStarts = 0;
  int loginCancels = 0;
  final opened = <String>[];
  SenseLoginStatus status = const SenseLoginStatus('requesting');

  int projectCalls = 0;
  SenseProjectList projectList = const SenseProjectList.ok([
    SenseProject('prj_1', 'Örnek Müze'),
    SenseProject('prj_2', 'Ekip'),
  ]);

  final installs = <SenseInstallRequest>[];
  Completer<String>? pendingInstall;
  String installResult = '';

  final enrolls = <SenseEnrollRequest>[];
  Completer<SenseEnrollResult>? pendingEnroll;
  SenseEnrollResult enrollResult = const SenseEnrollResult.ok(['Örnek Müze']);

  final finishes = <bool>[];

  @override
  Future<void> loginStart() async {
    loginStarts++;
  }

  @override
  Future<SenseLoginStatus> loginStatus() async => status;

  @override
  Future<void> loginCancel() async {
    loginCancels++;
  }

  @override
  Future<void> openUrl(String url) async {
    opened.add(url);
  }

  @override
  Future<SenseProjectList> projects() async {
    projectCalls++;
    return projectList;
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
}

Future<void> pumpWizard(WidgetTester tester, FakeBackend backend) async {
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
}

Finder get next => find.byKey(const Key('sense-next'));

/// The check mark inside a selected panel project chip.
Finder checked(String projectId) => find.descendant(
    of: find.byKey(Key('sense-project-$projectId')),
    matching: find.byIcon(Icons.check));

bool enabled(WidgetTester tester, Finder finder) =>
    tester.widget<ButtonStyleButton>(finder).onPressed != null;

Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// One poll of the sign-in state (the wizard reads it every second).
Future<void> poll(WidgetTester tester, SenseLoginStatus status,
    FakeBackend backend) async {
  backend.status = status;
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

const waiting =
    SenseLoginStatus('waiting', url: kUrl, pairingCode: '482913');
const signedIn =
    SenseLoginStatus('done', email: kEmail, displayName: 'Ad Soyad');

Future<void> signIn(WidgetTester tester, FakeBackend backend) async {
  await tapAndSettle(tester, find.byKey(const Key('sense-login')));
  await poll(tester, waiting, backend);
  await poll(tester, signedIn, backend);
}

/// Sign-in -> role -> info -> summary with the given choices.
Future<void> goToSummary(WidgetTester tester, FakeBackend backend,
    {bool host = true, bool controller = false}) async {
  await signIn(tester, backend);
  await tapAndSettle(tester, next);
  if (host) {
    await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
  }
  if (controller) {
    await tapAndSettle(tester, find.byKey(const Key('sense-role-controller')));
  }
  await tapAndSettle(tester, next);
  await tester.enterText(find.byKey(const Key('sense-name')), '  Galeri kioskı ');
  await tester.enterText(find.byKey(const Key('sense-location')), 'Galeri 1');
  await tapAndSettle(tester, find.byKey(const Key('sense-project-prj_1')));
  // Typed but not confirmed with Enter: still added on "Devam".
  await tester.enterText(find.byKey(const Key('sense-project')), 'Yeni Müze');
  await tester.enterText(find.byKey(const Key('sense-note')), '2 ekran');
  await tapAndSettle(tester, next);
}

void main() {
  testWidgets('starts at the Sense sign-in; Devam waits for it',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final backend = FakeBackend();
    await pumpWizard(tester, backend);

    expect(find.text(t('step-account')), findsOneWidget);
    expect(find.text(t('google-sign-in')), findsOneWidget);
    expect(find.text(t('domain-hint')), findsOneWidget);
    expect(find.textContaining('RustDesk'), findsNothing);
    expect(enabled(tester, next), isFalse);

    await tapAndSettle(tester, find.byKey(const Key('sense-login')));
    expect(backend.loginStarts, 1);
    expect(find.byKey(const Key('sense-login-requesting')), findsOneWidget);

    // The code is shown large, 3+3 like the panel; the browser opens only on request.
    await poll(tester, waiting, backend);
    expect(find.text('482 913'), findsOneWidget);
    expect(find.text(t('pairing-hint')), findsOneWidget);
    expect(find.bySemanticsLabel('${t('pairing-spoken')}4 8 2 9 1 3'),
        findsOneWidget);
    expect(backend.opened, isEmpty);
    await tapAndSettle(tester, find.byKey(const Key('sense-open-browser')));
    expect(backend.opened, [kUrl]);
    expect(enabled(tester, next), isFalse);

    await poll(tester, signedIn, backend);
    expect(find.byKey(const Key('sense-account')), findsOneWidget);
    expect(find.text(kEmail), findsOneWidget);
    expect(find.text('AS'), findsOneWidget);
    expect(find.text(t('verified')), findsOneWidget);
    expect(enabled(tester, next), isTrue);
    expect(backend.projectCalls, 1);
    semantics.dispose();
  });

  testWidgets('copy link copies the approval URL', (tester) async {
    final copied = <Object?>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add(call.arguments);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-login')));
    await poll(tester, waiting, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-copy-link')));
    expect(copied, [
      {'text': kUrl}
    ]);
    expect(find.text(t('link-copied')), findsOneWidget);
  });

  testWidgets('timeout asks for a new code; other errors offer a retry',
      (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-login')));
    await poll(tester, waiting, backend);
    await poll(tester,
        const SenseLoginStatus('failed', error: 'timeout'), backend);
    expect(find.text(t('login-timeout')), findsOneWidget);
    expect(find.text('482 913'), findsNothing);
    expect(find.text(t('new-code')), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('sense-login')));
    expect(backend.loginStarts, 2);
    await poll(
        tester,
        const SenseLoginStatus('failed',
            error: 'failed', detail: 'Hesap kapalı'),
        backend);
    expect(find.text('${t('login-failed')}\nHesap kapalı'), findsOneWidget);
    expect(find.text(t('retry')), findsOneWidget);
    expect(enabled(tester, next), isFalse);
  });

  testWidgets('cancel and another account go back to the start',
      (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-login')));
    await poll(tester, waiting, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-login-cancel')));
    expect(backend.loginCancels, 1);
    expect(find.text(t('google-sign-in')), findsOneWidget);
    // The old attempt's state no longer counts.
    backend.status = signedIn;
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const Key('sense-account')), findsNothing);

    await signIn(tester, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-other-account')));
    expect(backend.loginCancels, 2);
    expect(enabled(tester, next), isFalse);
  });

  testWidgets('role step: one or both roles, back to the account',
      (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await signIn(tester, backend);
    await tapAndSettle(tester, next);

    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Controller'), findsOneWidget);
    expect(enabled(tester, next), isFalse);
    expect(find.text(t('no-role')), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
    expect(find.text('Host.'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('sense-role-controller')));
    expect(find.text('Host + Controller${t('both-desc')}'), findsOneWidget);
    await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
    expect(find.text('Controller.'), findsOneWidget);

    await tapAndSettle(tester, find.byKey(const Key('sense-back')));
    expect(find.byKey(const Key('sense-account')), findsOneWidget);
  });

  testWidgets('info step: panel projects, new projects, name required',
      (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await signIn(tester, backend);
    await tapAndSettle(tester, next);
    await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
    await tapAndSettle(tester, next);

    expect(find.text('Örnek Müze'), findsOneWidget);
    expect(find.text('Ekip'), findsOneWidget);
    expect(enabled(tester, next), isFalse);
    await tester.enterText(find.byKey(const Key('sense-name')), '   ');
    await tester.pump();
    expect(enabled(tester, next), isFalse);
    await tester.enterText(find.byKey(const Key('sense-name')), 'Kiosk');
    await tester.pump();
    expect(enabled(tester, next), isTrue);

    // A typed name matching a panel project selects it (Turkish case rules).
    await tester.enterText(find.byKey(const Key('sense-project')), 'EKİP');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(checked('prj_2'), findsOneWidget);
    expect(checked('prj_1'), findsNothing);
    expect(find.byKey(const Key('sense-new-project-EKİP')), findsNothing);

    await tester.enterText(find.byKey(const Key('sense-project')), 'Yeni Müze');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('sense-project')), 'yeni müze');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sense-new-project-Yeni Müze')), findsOneWidget);
    expect(find.text(t('new-tag')), findsOneWidget);

    // Remove the new one, unselect the panel one.
    await tapAndSettle(tester, find.byTooltip(t('remove-project')));
    expect(find.byKey(const Key('sense-new-project-Yeni Müze')), findsNothing);
    await tapAndSettle(tester, find.byKey(const Key('sense-project-prj_2')));
    expect(checked('prj_2'), findsNothing);
  });

  testWidgets('project list errors can be retried; empty list explains',
      (tester) async {
    final backend = FakeBackend()
      ..projectList = const SenseProjectList.error('network');
    await pumpWizard(tester, backend);
    await signIn(tester, backend);
    await tapAndSettle(tester, next);
    await tapAndSettle(tester, find.byKey(const Key('sense-role-host')));
    await tapAndSettle(tester, next);

    expect(find.text(t('projects-error-network')), findsOneWidget);
    backend.projectList = const SenseProjectList.ok([]);
    await tapAndSettle(tester, find.byKey(const Key('sense-projects-retry')));
    expect(backend.projectCalls, 2);
    expect(find.byKey(const Key('sense-projects-error')), findsNothing);
    expect(find.text(t('projects-empty')), findsOneWidget);
  });

  testWidgets('summary -> install -> panel registration -> done',
      (tester) async {
    final backend = FakeBackend()
      ..pendingInstall = Completer<String>()
      ..pendingEnroll = Completer<SenseEnrollResult>();
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend, host: true, controller: true);

    final summary = find.byKey(const Key('sense-summary'));
    Finder inSummary(String text) =>
        find.descendant(of: summary, matching: find.text(text));
    expect(inSummary(kEmail), findsOneWidget);
    expect(inSummary('Host + Controller'), findsOneWidget);
    expect(inSummary('Galeri kioskı'), findsOneWidget);
    expect(inSummary('Örnek Müze, Yeni Müze (${t('new-tag')})'), findsOneWidget);
    expect(inSummary('Galeri 1'), findsOneWidget);
    expect(inSummary('2 ekran'), findsOneWidget);
    expect(inSummary(t('password-value')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sense-install')));
    await tester.pump();
    expect(find.text(t('installing')), findsOneWidget);
    expect(enabled(tester, find.byKey(const Key('sense-install'))), isFalse);

    final request = backend.installs.single;
    expect(request.role, 'both');
    expect(request.options, ' startmenu desktopicon');
    expect(request.path, r'C:\Program Files\SenseRemote');
    // K-YEREL: only name and location stay on the computer.
    expect(jsonDecode(request.infoJson),
        {'name': 'Galeri kioskı', 'location': 'Galeri 1'});

    backend.pendingInstall!.complete('');
    await tester.pump();
    await tester.pump();
    expect(find.text(t('registering')), findsOneWidget);
    expect(jsonDecode(backend.enrolls.single.toJson()), {
      'name': 'Galeri kioskı',
      'location': 'Galeri 1',
      'note': '2 ekran',
      'project_ids': ['prj_1'],
      'new_projects': ['Yeni Müze'],
    });

    backend.pendingEnroll!
        .complete(const SenseEnrollResult.ok(['Örnek Müze', 'Yeni Müze']));
    await tester.pumpAndSettle();
    expect(find.text(t('done-title')), findsOneWidget);
    final done = tester.widget<Text>(find.byKey(const Key('sense-done'))).data!;
    expect(done, contains(t('done-lead')));
    expect(
        done,
        contains(t('done-panel-projects')
            .replaceAll('{projects}', 'Örnek Müze, Yeni Müze')));
    expect(done, contains(t('done-lead-locked')));

    await tapAndSettle(tester, find.byKey(const Key('sense-finish-open')));
    expect(backend.finishes, [true]);
  });

  testWidgets('registration failure: retry, then skip -> waiting for approval',
      (tester) async {
    final backend = FakeBackend()
      ..enrollResult = const SenseEnrollResult.error('network');
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend, host: false, controller: true);
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));

    expect(find.byKey(const Key('sense-register-failed')), findsOneWidget);
    expect(find.text(t('enroll-network')), findsOneWidget);
    expect(backend.enrolls, hasLength(1));

    backend.enrollResult = const SenseEnrollResult.error('something_new');
    await tapAndSettle(tester, find.byKey(const Key('sense-retry-register')));
    expect(backend.enrolls, hasLength(2));
    expect(find.text(t('enroll-other')), findsOneWidget);

    // Another computer holds the ID: no retry, only skip.
    backend.enrollResult = const SenseEnrollResult.error('uuid_mismatch');
    await tapAndSettle(tester, find.byKey(const Key('sense-retry-register')));
    expect(find.text(t('enroll-uuid_mismatch')), findsOneWidget);
    expect(find.byKey(const Key('sense-retry-register')), findsNothing);

    await tapAndSettle(tester, find.byKey(const Key('sense-skip-register')));
    final done = tester.widget<Text>(find.byKey(const Key('sense-done'))).data!;
    expect(done, contains(t('done-pending')));
    expect(done, isNot(contains(t('done-lead-locked'))));

    // Leaving through the title bar also goes through `finish` after installing.
    await tapAndSettle(tester, find.byKey(const Key('sense-window-close')));
    expect(backend.finishes, [false]);
  });

  for (final code in ['token_invalid', 'install_scope', 'device_mismatch']) {
    testWidgets('registration "$code": sign in again, then register',
        (tester) async {
      final backend = FakeBackend()
        ..enrollResult = SenseEnrollResult.error(code);
      await pumpWizard(tester, backend);
      await goToSummary(tester, backend);
      await tapAndSettle(tester, find.byKey(const Key('sense-install')));
      expect(find.text(t('enroll-$code')), findsOneWidget);
      expect(find.byKey(const Key('sense-retry-register')), findsNothing);

      await tapAndSettle(
          tester, find.byKey(const Key('sense-relogin-register')));
      expect(backend.loginCancels, 1);
      expect(find.text(t('google-sign-in')), findsOneWidget);
      backend.enrollResult = const SenseEnrollResult.ok(['Örnek Müze']);
      await signIn(tester, backend);
      // Devam registers directly: the role is installed and can not change.
      await tapAndSettle(tester, next);
      expect(backend.installs, hasLength(1));
      expect(backend.enrolls, hasLength(2));
      // The project choice survives the new sign-in.
      expect(jsonDecode(backend.enrolls.last.toJson())['project_ids'], ['prj_1']);
      expect(find.byKey(const Key('sense-done')), findsOneWidget);
    });
  }

  for (final code in ['validation', 'project_not_found']) {
    testWidgets('registration "$code": edit the details, then register',
        (tester) async {
      final backend = FakeBackend()
        ..enrollResult = SenseEnrollResult.error(code);
      await pumpWizard(tester, backend);
      await goToSummary(tester, backend);
      await tapAndSettle(tester, find.byKey(const Key('sense-install')));
      expect(find.text(t('enroll-$code')), findsOneWidget);

      await tapAndSettle(tester, find.byKey(const Key('sense-edit-register')));
      expect(find.byKey(const Key('sense-name')), findsOneWidget);
      expect(find.text(t('back')), findsNothing);
      await tapAndSettle(tester, find.byKey(const Key('sense-project-prj_1')));
      await tapAndSettle(tester, next);
      expect(find.byKey(const Key('sense-install')), findsNothing);
      expect(find.byKey(const Key('sense-advanced')), findsNothing);

      backend.enrollResult = const SenseEnrollResult.ok([]);
      await tapAndSettle(tester, find.byKey(const Key('sense-register-save')));
      expect(backend.installs, hasLength(1));
      expect(jsonDecode(backend.enrolls.last.toJson())['project_ids'], isEmpty);
      expect(find.byKey(const Key('sense-done')), findsOneWidget);
    });
  }

  testWidgets('registration "rate_limited": wait a minute, then retry',
      (tester) async {
    final backend = FakeBackend()
      ..enrollResult = const SenseEnrollResult.error('rate_limited');
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(find.text(t('enroll-rate_limited')), findsOneWidget);
    final retry = find.byKey(const Key('sense-retry-register'));
    expect(enabled(tester, retry), isFalse);
    expect(find.text('${t('retry')} (60 ${t('seconds-short')})'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('${t('retry')} (30 ${t('seconds-short')})'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(enabled(tester, retry), isTrue);
    backend.enrollResult = const SenseEnrollResult.ok(['Örnek Müze']);
    await tapAndSettle(tester, retry);
    expect(backend.enrolls, hasLength(2));
    expect(find.byKey(const Key('sense-done')), findsOneWidget);
  });

  test('every panel registration error has a message and an action', () {
    const actions = {
      'token_invalid': SenseEnrollAction.relogin,
      'install_scope': SenseEnrollAction.relogin,
      'device_mismatch': SenseEnrollAction.relogin,
      'validation': SenseEnrollAction.edit,
      'project_not_found': SenseEnrollAction.edit,
      'uuid_mismatch': SenseEnrollAction.none,
      'rate_limited': SenseEnrollAction.wait,
      'retry': SenseEnrollAction.retry,
      'network': SenseEnrollAction.retry,
      'other': SenseEnrollAction.retry,
      'something_new': SenseEnrollAction.retry,
      // Sense Remote (review K3-5): local codes of src/sense/enroll.rs.
      'invalid-name': SenseEnrollAction.edit,
      'invalid-location': SenseEnrollAction.edit,
      'invalid-note': SenseEnrollAction.edit,
      'invalid-project': SenseEnrollAction.edit,
      'not-installed': SenseEnrollAction.none,
      'build': SenseEnrollAction.none,
      'identity': SenseEnrollAction.none,
      'identity-store': SenseEnrollAction.none,
      // Panel #31.
      'device_closed': SenseEnrollAction.none,
      'reinstall_not_allowed': SenseEnrollAction.retry,
    };
    actions.forEach((code, action) {
      expect(senseEnrollAction(code), action, reason: code);
      if (code != 'something_new') {
        expect(kSenseInstallTr['enroll-$code'], isNotNull, reason: code);
      }
    });
  });

  testWidgets('registration without projects says the computer is active',
      (tester) async {
    final backend = FakeBackend()
      ..enrollResult = const SenseEnrollResult.ok([]);
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    final done = tester.widget<Text>(find.byKey(const Key('sense-done'))).data!;
    expect(done, contains(t('done-panel-none')));
    expect(done, contains(t('done-lead-locked')));
  });

  // Sense Remote (design review T3-2): a Host has no large window to open.
  testWidgets('Host only: the done page only closes', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend);
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    final done = tester.widget<Text>(find.byKey(const Key('sense-done'))).data!;
    expect(done, contains(t('done-host-background')));
    expect(find.byKey(const Key('sense-finish-open')), findsNothing);
    await tapAndSettle(tester, find.byKey(const Key('sense-finish-close')));
    expect(backend.finishes, [false]);
  });

  // Sense Remote (design review T3-11): the version comes from the build.
  testWidgets('the sidebar shows the build version, none without it',
      (tester) async {
    tester.view.physicalSize = const Size(860, 620);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget wizard(String version) => MaterialApp(
          home: SenseInstallWizard(
            initialPath: r'C:\Program Files\SenseRemote',
            icon: const SizedBox(),
            backend: FakeBackend(),
            version: version,
          ),
        );
    await tester.pumpWidget(wizard('7'));
    await tester.pumpAndSettle();
    expect(find.text('${t('version')} 7'), findsOneWidget);
    await tester.pumpWidget(wizard(''));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sense-version')), findsNothing);
  });

  // Sense Remote (panel #31): closed computer -> only skip; already active -> retry or skip.
  testWidgets('closed or already registered computer', (tester) async {
    final backend = FakeBackend()
      ..enrollResult = const SenseEnrollResult.error('device_closed');
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend, host: false, controller: true);
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(find.text(t('enroll-device_closed')), findsOneWidget);
    expect(find.byKey(const Key('sense-retry-register')), findsNothing);
    expect(find.byKey(const Key('sense-skip-register')), findsOneWidget);
  });

  testWidgets('already registered computer can retry after the panel allows it',
      (tester) async {
    final backend = FakeBackend()
      ..enrollResult = const SenseEnrollResult.error('reinstall_not_allowed');
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend, host: false, controller: true);
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(find.text(t('enroll-reinstall_not_allowed')), findsOneWidget);
    expect(find.byKey(const Key('sense-skip-register')), findsOneWidget);
    backend.enrollResult = const SenseEnrollResult.ok(['Örnek Müze']);
    await tapAndSettle(tester, find.byKey(const Key('sense-retry-register')));
    expect(backend.enrolls, hasLength(2));
    expect(find.byKey(const Key('sense-done')), findsOneWidget);
  });

  testWidgets('declined administrator prompt stays on the summary',
      (tester) async {
    final backend = FakeBackend()..installResult = 'cancelled';
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend);

    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(find.text(t('error-cancelled')), findsOneWidget);
    expect(find.byKey(const Key('sense-summary')), findsOneWidget);
    expect(enabled(tester, find.byKey(const Key('sense-install'))), isTrue);
    expect(backend.installs.single.role, 'host');
    expect(backend.enrolls, isEmpty);
  });

  testWidgets('install errors are shown', (tester) async {
    final backend = FakeBackend()..installResult = 'not-signed-in';
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend, host: false, controller: true);

    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(find.text(t('error-not-signed-in')), findsOneWidget);
    expect(backend.installs.single.role, 'controller');

    backend.installResult = 'install failed with elevated exit code 1';
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(
        find.text(
            '${t('error-failed')}\ninstall failed with elevated exit code 1'),
        findsOneWidget);
    expect(backend.enrolls, isEmpty);
  });

  testWidgets('advanced options change the install options', (tester) async {
    final backend = FakeBackend();
    await pumpWizard(tester, backend);
    await goToSummary(tester, backend);

    expect(find.text(t('desktop-icon')), findsNothing);
    await tapAndSettle(tester, find.byKey(const Key('sense-advanced')));
    expect(find.text(r'C:\Program Files\SenseRemote'), findsOneWidget);
    await tapAndSettle(tester, find.text(t('desktop-icon')));
    await tapAndSettle(tester, find.text(t('printer')));
    await tapAndSettle(tester, find.byKey(const Key('sense-install')));
    expect(backend.installs.single.options, ' startmenu printer');
  });

  testWidgets('app login window shows the pairing code 3+3', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SensePairingCode(code: '123456'))));
    expect(find.text('123 456'), findsOneWidget);
    expect(find.text(t('pairing-hint')), findsOneWidget);
    expect(find.bySemanticsLabel('${t('pairing-spoken')}1 2 3 4 5 6'),
        findsOneWidget);
    semantics.dispose();
  });

  test('role values match src/sense.rs; info keeps name and location only',
      () {
    SenseInstallRequest request(bool host, bool controller) =>
        SenseInstallRequest(
          host: host,
          controller: controller,
          name: 'a',
          location: 'b',
          path: '',
          startMenu: false,
          desktopIcon: false,
          printer: false,
        );
    expect(request(true, false).role, 'host');
    expect(request(false, true).role, 'controller');
    expect(request(true, true).role, 'both');
    expect(request(true, true).options, '');
    expect(jsonDecode(request(true, false).infoJson), {'name': 'a', 'location': 'b'});
    expect(senseRoleLabel(true, true), 'Host + Controller');
  });

  test('native JSON is read defensively', () {
    final status = SenseLoginStatus.fromJson(jsonEncode({
      'state': 'waiting',
      'url': kUrl,
      'pairing_code': '482913',
    }));
    expect(status.isWaiting, isTrue);
    expect(status.pairingCode, '482913');
    final done = SenseLoginStatus.fromJson(jsonEncode({
      'state': 'done',
      'user': {'name': kEmail, 'display_name': 'Ad Soyad'},
    }));
    expect(done.email, kEmail);
    expect(SenseLoginStatus.fromJson('nope').isFailed, isTrue);
    expect(SenseLoginStatus.fromJson('{"state":1}').isFailed, isTrue);

    final list = SenseProjectList.fromJson(jsonEncode({
      'ok': true,
      'projects': [
        {'id': 'prj_1', 'name': 'Örnek Müze'}
      ],
    }));
    expect(list.ok, isTrue);
    expect(list.projects.single.id, 'prj_1');
    expect(SenseProjectList.fromJson('{"ok":false,"error":"network"}').error,
        'network');
    expect(SenseProjectList.fromJson('[]').error, 'retry');

    final enrolled = SenseEnrollResult.fromJson(jsonEncode({
      'ok': true,
      'projects': [
        {'name': 'Örnek Müze', 'created': false}
      ],
    }));
    expect(enrolled.projects, ['Örnek Müze']);
    expect(SenseEnrollResult.fromJson('{"ok":false,"error":"uuid_mismatch"}').error,
        'uuid_mismatch');
    expect(SenseEnrollResult.fromJson('').error, 'other');
  });

  test('pairing code format and Turkish lower case', () {
    expect(formatSensePairingCode('482913'), '482 913');
    expect(formatSensePairingCode('12345'), '12345');
    expect(spokenSensePairingCode('482913'), '4 8 2 9 1 3');
    expect(senseTrLower('EKİP'), 'ekip');
    expect(senseTrLower('IŞIK'), 'ışık');
  });

  test('every Turkish text has an English counterpart; enroll codes covered',
      () {
    expect(kSenseInstallTr.keys.toSet(), kSenseInstallEn.keys.toSet());
    for (final code in [
      'token_invalid',
      'install_scope',
      'device_mismatch',
      'validation',
      'project_not_found',
      'uuid_mismatch',
      'rate_limited',
      'retry',
      'network',
    ]) {
      expect(kSenseInstallTr['enroll-$code'], isNotNull, reason: code);
    }
  });
}
