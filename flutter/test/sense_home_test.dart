// Sense Remote: Sense home screens (Controller project cards, Host home,
// About) — pure helpers and widget tests (wave 3, I9).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/desktop/pages/sense_home_about.dart';
import 'package:flutter_hbb/desktop/pages/sense_home_controller.dart';
import 'package:flutter_hbb/desktop/pages/sense_home_host.dart';
import 'package:flutter_hbb/desktop/pages/sense_home_mac.dart';
import 'package:flutter_hbb/desktop/pages/sense_home_strings.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_test/flutter_test.dart';

String t(String key) => kSenseHomeTr[key]!;

DeviceGroupPayload _group(String name, String projectId, String sortKey) =>
    DeviceGroupPayload.fromJson({
      'name': name,
      'sense': {'project_id': projectId, 'sort_key': sortKey},
    });

PeerPayload _payload(String id, String name, String location,
        List<List<String>> projects) =>
    PeerPayload.fromJson({
      'id': id,
      'info': {'device_name': name, 'os': 'windows / 10'},
      'status': 1,
      'device_group_name': '',
      'note': location,
      'sense': {
        'device_id': 'dev_$id',
        'online': true,
        'app_version': 1,
        'projects': projects
            .map((p) => {'project_id': p[0], 'sort_key': p[1]})
            .toList(),
      },
    });

/// Panel order: "Örnek Müze" before "Fuar Standı"; peer 300 is in both.
class Fixture {
  final groups = [
    _group('Örnek Müze', 'prj_m', 'a0'),
    _group('Fuar Standı', 'prj_f', 'a1'),
  ];
  late final payloads = [
    _payload('200', 'Media server A', 'Ana salon', [
      ['prj_m', 'a0']
    ]),
    _payload('300', 'Galeri kioskı', 'Galeri 1', [
      ['prj_m', 'a1'],
      ['prj_f', 'a0'],
    ]),
    _payload('100', 'LED işlemci PC', 'Arka oda', [
      ['prj_f', 'a1']
    ]),
    _payload('400', 'Eski kiosk', 'Depo', []),
  ];
  late final order = SensePanelOrder.build(groups, payloads);
  late final peers = payloads.map(PeerPayload.toPeer).toList();
  List<String> get names => groups.map((g) => g.name).toList();

  Fixture({Set<String> online = const {'200', '300'}}) {
    for (final p in peers) {
      p.online = online.contains(p.id);
    }
  }
}

List<List<String>> _shape(List<SenseHomeProject> projects) => [
      for (final p in projects) [p.name, ...p.computers.map((c) => c.id)]
    ];

/// Sense Remote (Mac M7): the Host card as the home page mounts it — in the
/// scrolling left pane, 280 px wide (the window height follows the content).
Widget _hostPane(Widget child) =>
    SingleChildScrollView(child: SizedBox(width: 280, child: child));

Future<void> _pump(WidgetTester tester, Widget child,
    {Size size = const Size(1000, 700)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

/// Sense Remote (Mac M7): fake system side of the macOS permission notice.
class _FakeMac implements SenseMacPermissionBackend {
  _FakeMac(this.now);
  SenseMacPermissions now;
  bool fail = false;
  final opened = <SenseMacPermission>[];
  int restarts = 0;

  @override
  SenseMacPermissions read() {
    if (fail) throw StateError('unreadable');
    return now;
  }

  @override
  Future<void> open(SenseMacPermission permission) async =>
      opened.add(permission);

  @override
  Future<String> restartAgent() async {
    restarts++;
    return '';
  }
}

const _macNone = SenseMacPermissions(
    screenRecording: false, accessibility: false, inputMonitoring: false);
const _macAll = SenseMacPermissions(
    screenRecording: true, accessibility: true, inputMonitoring: true);
const _screen = SenseMacPermission.screenRecording;
const _access = SenseMacPermission.accessibility;
const _input = SenseMacPermission.inputMonitoring;

void main() {
  group('macOS permissions', () {
    test('needed per role: Host all three, Controller input monitoring', () {
      expect(senseMacNeeded(SenseHomeRole.host), [_screen, _access, _input]);
      expect(senseMacNeeded(SenseHomeRole.both), [_screen, _access, _input]);
      expect(senseMacNeeded(SenseHomeRole.controller), [_input]);
      expect(senseMacNeeded(SenseHomeRole.none), isEmpty);
    });

    test('missing follows the role and the granted state', () {
      expect(senseMacMissing(SenseHomeRole.host, _macAll), isEmpty);
      expect(senseMacMissing(SenseHomeRole.host, _macNone),
          [_screen, _access, _input]);
      expect(senseMacMissing(SenseHomeRole.controller, _macNone), [_input]);
      expect(
          senseMacMissing(
              SenseHomeRole.controller,
              const SenseMacPermissions(
                  screenRecording: false,
                  accessibility: false,
                  inputMonitoring: true)),
          isEmpty);
      expect(
          senseMacMissing(
              SenseHomeRole.both,
              const SenseMacPermissions(
                  screenRecording: true,
                  accessibility: false,
                  inputMonitoring: true)),
          [_access]);
    });

    test('only screen recording and accessibility block a Host', () {
      expect(senseMacBlocksHost([]), isFalse);
      expect(senseMacBlocksHost([_input]), isFalse);
      expect(senseMacBlocksHost([_screen]), isTrue);
      expect(senseMacBlocksHost([_access, _input]), isTrue);
    });

    test('Turkish texts name what is missing', () {
      expect(senseMacMissingText([]), '');
      expect(senseMacMissingText([_screen]), 'Ekran Kaydı izni yok');
      expect(senseMacMissingText([_screen, _access]),
          'Ekran Kaydı ve Erişilebilirlik izinleri yok');
      expect(senseMacMissingText([_screen, _access, _input]),
          'Ekran Kaydı, Erişilebilirlik ve Giriş İzleme izinleri yok');
      expect(senseMacMissingNote([_input]), t('mac_perm_note_input'));
      expect(senseMacMissingNote([_access, _input]), t('mac_perm_note_host'));
    });

    test('each permission opens its own pane of System Settings', () {
      const base = 'x-apple.systempreferences:com.apple.preference.security';
      expect(senseMacSettingsUrl(_screen), '$base?Privacy_ScreenCapture');
      expect(senseMacSettingsUrl(_access), '$base?Privacy_Accessibility');
      expect(senseMacSettingsUrl(_input), '$base?Privacy_ListenEvent');
    });

    testWidgets('Host: missing permission is in the status line, with the way '
        'to System Settings; fits 280 px', (tester) async {
      final opened = <SenseMacPermission>[];
      await _pump(
          tester,
          _hostPane(
            SenseHostHomeView(
                name: 'Galeri Mac mini',
                location: 'Galeri 1',
                deviceId: '123456789',
                state: SenseHostState.ready,
                macMissing: const [_screen, _input],
                onOpenMacPermission: opened.add),
          ),
          size: const Size(280, 700));
      expect(find.text(t('ready')), findsNothing);
      expect(
          find.text('Hazır değil — Ekran Kaydı ve Giriş İzleme izinleri yok'),
          findsOneWidget);
      // The status line already names them: no second title.
      expect(find.byKey(const Key('sense-mac-perm-title')), findsNothing);
      expect(find.text(t('mac_perm_note_host')), findsOneWidget);
      await tester.tap(find.text(t('mac_perm_open')));
      expect(opened, [_screen]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Host: input monitoring alone keeps "ready" and adds a notice',
        (tester) async {
      await _pump(
          tester,
          _hostPane(
            SenseHostHomeView(
                name: 'Galeri Mac mini',
                location: '',
                deviceId: '',
                state: SenseHostState.ready,
                macMissing: const [_input],
                onOpenMacPermission: (_) {}),
          ),
          size: const Size(280, 700));
      expect(find.text(t('ready')), findsOneWidget);
      expect(find.text('Giriş İzleme izni yok'), findsOneWidget);
      expect(find.text(t('mac_perm_note_input')), findsOneWidget);
      expect(find.byKey(const Key('sense-mac-perm-open')), findsOneWidget);
    });

    testWidgets('Host: not connected keeps its own status; the notice names '
        'the permissions', (tester) async {
      await _pump(
          tester,
          _hostPane(
            SenseHostHomeView(
                name: '',
                location: '',
                deviceId: '',
                state: SenseHostState.notReady,
                macMissing: const [_access],
                onOpenMacPermission: (_) {}),
          ),
          size: const Size(280, 700));
      expect(find.text(t('not_ready')), findsOneWidget);
      expect(find.text('Erişilebilirlik izni yok'), findsOneWidget);
    });

    testWidgets('Host: all granted (and Windows) shows no permission notice',
        (tester) async {
      await _pump(
          tester,
          const SizedBox(
            width: 280,
            child: SenseHostHomeView(
                name: 'Galeri kioskı',
                location: 'Galeri 1',
                deviceId: '123456789',
                state: SenseHostState.ready),
          ),
          size: const Size(280, 600));
      expect(find.text(t('ready')), findsOneWidget);
      expect(find.byKey(const Key('sense-mac-perm-open')), findsNothing);
      expect(find.byKey(const Key('sense-mac-perm-note')), findsNothing);
    });

    testWidgets('Controller card: only input monitoring; fits the 200 px pane',
        (tester) async {
      final opened = <SenseMacPermission>[];
      await _pump(
          tester,
          SizedBox(
            width: 200,
            child: SenseMacPermissionCardView(
                missing: senseMacMissing(SenseHomeRole.controller, _macNone),
                onOpen: opened.add),
          ),
          size: const Size(200, 600));
      expect(find.byKey(const Key('sense-mac-perm-card')), findsOneWidget);
      expect(find.text('Giriş İzleme izni yok'), findsOneWidget);
      expect(find.textContaining('Ekran Kaydı'), findsNothing);
      await tester.tap(find.byKey(const Key('sense-mac-perm-open')));
      expect(opened, [_input]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('card is empty when nothing is missing', (tester) async {
      await _pump(
          tester, SenseMacPermissionCardView(missing: const [], onOpen: (_) {}));
      expect(find.byKey(const Key('sense-mac-perm-card')), findsNothing);
    });

    testWidgets('watch: follows the system state, opens the first missing '
        'pane, restarts the agent once screen recording arrives',
        (tester) async {
      final mac = _FakeMac(_macNone);
      var changes = 0;
      await _pump(
          tester,
          SenseMacPermissionWatch(
            role: SenseHomeRole.both,
            backend: mac,
            interval: const Duration(seconds: 2),
            onChanged: () => changes++,
            builder: (_, missing, open) =>
                SenseMacPermissionCardView(missing: missing, onOpen: open),
          ));
      expect(
          find.text('Ekran Kaydı, Erişilebilirlik ve Giriş İzleme izinleri yok'),
          findsOneWidget);
      expect(changes, 0);
      await tester.tap(find.byKey(const Key('sense-mac-perm-open')));
      expect(mac.opened, [_screen]);

      mac.now = const SenseMacPermissions(
          screenRecording: true, accessibility: false, inputMonitoring: false);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('Erişilebilirlik ve Giriş İzleme izinleri yok'),
          findsOneWidget);
      expect(changes, 1);
      expect(mac.restarts, 1);

      // Unreadable state keeps the last known one.
      mac.fail = true;
      await tester.pump(const Duration(seconds: 2));
      expect(changes, 1);
      mac.fail = false;

      mac.now = _macAll;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.byKey(const Key('sense-mac-perm-card')), findsNothing);
      expect(changes, 2);
      expect(mac.restarts, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('watch: screen recording already there, or a Controller, '
        'never restarts the agent', (tester) async {
      final mac = _FakeMac(const SenseMacPermissions(
          screenRecording: true, accessibility: false, inputMonitoring: false));
      await _pump(
          tester,
          SenseMacPermissionWatch(
            key: const ValueKey('host'),
            role: SenseHomeRole.host,
            backend: mac,
            builder: (_, missing, open) =>
                SenseMacPermissionCardView(missing: missing, onOpen: open),
          ));
      mac.now = _macAll;
      await tester.pump(const Duration(seconds: 2));
      expect(mac.restarts, 0);

      final controller = _FakeMac(_macNone);
      await _pump(
          tester,
          SenseMacPermissionWatch(
            key: const ValueKey('controller'),
            role: SenseHomeRole.controller,
            backend: controller,
            builder: (_, missing, open) =>
                SenseMacPermissionCardView(missing: missing, onOpen: open),
          ));
      expect(find.text('Giriş İzleme izni yok'), findsOneWidget);
      controller.now = _macAll;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(controller.restarts, 0);
      expect(find.byKey(const Key('sense-mac-perm-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('watch: unreadable state at start shows no made-up warning',
        (tester) async {
      final mac = _FakeMac(_macNone)..fail = true;
      await _pump(
          tester,
          SenseMacPermissionWatch(
            role: SenseHomeRole.host,
            backend: mac,
            builder: (_, missing, open) =>
                SenseMacPermissionCardView(missing: missing, onOpen: open),
          ));
      expect(find.byKey(const Key('sense-mac-perm-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('role and version', () {
    test('role from the applied hard settings', () {
      expect(
          senseHomeRoleFrom(
              incomingOnly: true, outgoingOnly: false, settingsDisabled: true),
          SenseHomeRole.host);
      expect(
          senseHomeRoleFrom(
              incomingOnly: false, outgoingOnly: true, settingsDisabled: false),
          SenseHomeRole.controller);
      expect(
          senseHomeRoleFrom(
              incomingOnly: false, outgoingOnly: false, settingsDisabled: true),
          SenseHomeRole.both);
      expect(
          senseHomeRoleFrom(
              incomingOnly: false,
              outgoingOnly: false,
              settingsDisabled: false),
          SenseHomeRole.none);
    });

    test('role names stay English', () {
      expect(senseRoleLabel(SenseHomeRole.host), 'Host');
      expect(senseRoleLabel(SenseHomeRole.controller), 'Controller');
      expect(senseRoleLabel(SenseHomeRole.both), 'Host + Controller');
      expect(senseRoleLabel(SenseHomeRole.none), t('role_none'));
    });

    test('Turkish upper case for labels', () {
      expect(senseHomeUpper('Galeri kioskı'), 'GALERİ KİOSKI');
    });

    test('version is a plain positive number or nothing', () {
      expect(senseVersionFrom('1'), 1);
      expect(senseVersionFrom(' 12 '), 12);
      expect(senseVersionFrom(''), isNull);
      expect(senseVersionFrom('0'), isNull);
      expect(senseVersionFrom('1.5.3'), isNull);
    });
  });

  group('senseHomeProjects', () {
    test('panel order, multi-project computer in each project, rest last', () {
      final f = Fixture();
      final projects = senseHomeProjects(
          projectNames: f.names, peers: f.peers, order: f.order);
      expect(_shape(projects), [
        ['Örnek Müze', '200', '300'],
        ['Fuar Standı', '300', '100'],
        [t('no_project'), '400'],
      ]);
      final card = projects.first.computers.first;
      expect(card.name, 'Media server A');
      expect(card.location, 'Ana salon');
      expect(card.online, isTrue);
      expect(card.displayCount, isNull);
    });

    test('search: project name shows the whole project', () {
      final f = Fixture();
      expect(
          _shape(senseHomeProjects(
              projectNames: f.names,
              peers: f.peers,
              order: f.order,
              query: 'fuar')),
          [
            ['Fuar Standı', '300', '100']
          ]);
    });

    test('search: computer, location (Turkish i folding) and ID', () {
      final f = Fixture();
      List<List<String>> q(String query) => _shape(senseHomeProjects(
          projectNames: f.names, peers: f.peers, order: f.order, query: query));
      expect(q('GALERİ'), [
        ['Örnek Müze', '300'],
        ['Fuar Standı', '300'],
      ]);
      expect(q('arka oda'), [
        ['Fuar Standı', '100']
      ]);
      expect(q('4 0 0'), [
        [t('no_project'), '400']
      ]);
      expect(q('yok böyle'), isEmpty);
    });

    test('stock server (no sense data): single group, sorted by name', () {
      final peers = [
        Peer.fromJson({'id': '2', 'hostname': 'b', 'device_group_name': 'G'}),
        Peer.fromJson({'id': '1', 'hostname': 'a', 'device_group_name': 'G'}),
      ];
      expect(
          _shape(senseHomeProjects(projectNames: ['G'], peers: peers)),
          [
            ['G', '1', '2']
          ]);
    });

    test('display count is shown only when known', () {
      final f = Fixture();
      final projects = senseHomeProjects(
          projectNames: f.names,
          peers: f.peers,
          order: f.order,
          displayCounts: {'200': 2});
      expect(projects.first.computers.first.displayCount, 2);
    });

    test('ID typed into the search box', () {
      expect(senseIdFromQuery('123 456 789'), '123456789');
      expect(senseIdFromQuery('Galeri'), isNull);
      expect(senseIdFromQuery('12'), isNull);
    });
  });

  group('Controller home view', () {
    testWidgets('project sections and cards; connect and offline', (tester) async {
      final f = Fixture();
      final connected = <String>[];
      await _pump(
          tester,
          SenseControllerHomeView(
              projectNames: f.names,
              peers: f.peers,
              order: f.order,
              onConnect: connected.add));

      expect(find.text(t('computers')), findsOneWidget);
      expect(find.text('ÖRNEK MÜZE'), findsOneWidget);
      expect(find.text('FUAR STANDI'), findsOneWidget);
      // the multi-project computer has a card in both projects
      expect(find.text('Galeri kioskı'), findsNWidgets(2));
      expect(find.text('Ana salon'), findsOneWidget);
      // projects in panel order
      expect(tester.getTopLeft(find.text('ÖRNEK MÜZE')).dy,
          lessThan(tester.getTopLeft(find.text('FUAR STANDI')).dy));

      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('sense-card-Örnek Müze-200')),
          matching: find.text(t('connect'))));
      expect(connected, ['200']);

      // offline: muted "Kapalı" that still tries
      final offline = find.descendant(
          of: find.byKey(const ValueKey('sense-card-Fuar Standı-100')),
          matching: find.text(t('offline')));
      expect(offline, findsOneWidget);
      await tester.tap(offline);
      expect(connected, ['200', '100']);
    });

    testWidgets('search filters; an ID offers connect by ID', (tester) async {
      final f = Fixture();
      final connected = <String>[];
      await _pump(
          tester,
          SenseControllerHomeView(
              projectNames: f.names,
              peers: f.peers,
              order: f.order,
              onConnect: connected.add));

      await tester.enterText(
          find.byKey(const Key('sense-home-search')), 'led');
      await tester.pumpAndSettle();
      expect(find.text('LED işlemci PC'), findsOneWidget);
      expect(find.text('Media server A'), findsNothing);
      expect(find.text('ÖRNEK MÜZE'), findsNothing);

      await tester.enterText(
          find.byKey(const Key('sense-home-search')), '987 654 321');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sense-home-message')), findsOneWidget);
      expect(find.text(t('no_match')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-home-connect-id')));
      expect(connected, ['987654321']);
    });

    testWidgets('loading, error and empty messages', (tester) async {
      Future<void> pumpWith({bool loading = false, String error = ''}) =>
          _pump(
              tester,
              SenseControllerHomeView(
                  key: UniqueKey(),
                  projectNames: const [],
                  peers: const [],
                  loading: loading,
                  error: error,
                  onConnect: (_) {}));
      await pumpWith(loading: true);
      expect(find.text(t('loading')), findsOneWidget);
      await pumpWith(error: 'x');
      expect(find.text(t('load_error')), findsOneWidget);
      await pumpWith();
      expect(find.text(t('empty')), findsOneWidget);
    });

    testWidgets('refresh button calls back', (tester) async {
      var refreshed = 0;
      await _pump(
          tester,
          SenseControllerHomeView(
              projectNames: const [],
              peers: const [],
              onConnect: (_) {},
              onRefresh: () => refreshed++));
      await tester.tap(find.byKey(const Key('sense-home-refresh')));
      expect(refreshed, 1);
    });

    // Sense Remote: connect by ID is always visible (user test 2026-11-21).
    const openKey = Key('sense-home-connect-id-open');
    const dialogKey = Key('sense-connect-id-dialog');
    const fieldKey = Key('sense-connect-id-field');
    const goKey = Key('sense-connect-id-go');

    Future<List<String>> pumpAndOpen(WidgetTester tester,
        {Size size = const Size(1000, 700)}) async {
      final f = Fixture();
      final connected = <String>[];
      await _pump(
          tester,
          SenseControllerHomeView(
              projectNames: f.names,
              peers: f.peers,
              order: f.order,
              onConnect: connected.add,
              onRefresh: () {}),
          size: size);
      expect(find.byKey(dialogKey), findsNothing);
      await tester.tap(find.byKey(openKey));
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsOneWidget);
      return connected;
    }

    testWidgets('connect by ID button is always there; hints mention the ID',
        (tester) async {
      // with computers, without a search
      final f = Fixture();
      await _pump(
          tester,
          SenseControllerHomeView(
              key: UniqueKey(),
              projectNames: f.names,
              peers: f.peers,
              order: f.order,
              onConnect: (_) {},
              onRefresh: () {}));
      expect(find.byKey(openKey), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(openKey), matching: find.text(t('connect_id'))),
          findsOneWidget);
      expect(t('search_hint'), 'Proje, bilgisayar, konum ya da kimlik');
      expect(find.text(t('search_hint')), findsOneWidget);

      // empty list: the button and a pointer to it
      await _pump(
          tester,
          SenseControllerHomeView(
              key: UniqueKey(),
              projectNames: const [],
              peers: const [],
              onConnect: (_) {}));
      expect(find.byKey(openKey), findsOneWidget);
      expect(t('empty'), contains('“${t('connect_id')}”'));
      expect(find.text(t('empty')), findsOneWidget);
    });

    testWidgets('header does not overflow in a narrow window', (tester) async {
      final f = Fixture();
      await _pump(
          tester,
          SenseControllerHomeView(
              projectNames: f.names,
              peers: f.peers,
              order: f.order,
              onConnect: (_) {},
              onRefresh: () {}),
          size: const Size(360, 700));
      expect(tester.takeException(), isNull);
      expect(find.byKey(openKey), findsOneWidget);
    });

    testWidgets('connect by ID window: title, note, no password field',
        (tester) async {
      await pumpAndOpen(tester);
      final dialog = find.byKey(dialogKey);
      expect(find.descendant(of: dialog, matching: find.text(t('connect_id'))),
          findsOneWidget);
      expect(find.text(t('connect_id_note')), findsOneWidget);
      expect(find.text(t('cancel')), findsOneWidget);
      // only the ID is asked here; the password belongs to the connection window
      final fields = tester
          .widgetList<TextField>(
              find.descendant(of: dialog, matching: find.byType(TextField)))
          .toList();
      expect(fields.length, 1);
      expect(fields.single.obscureText, isFalse);
    });

    testWidgets('invalid ID: connect is inactive; digits and spaces only',
        (tester) async {
      final connected = await pumpAndOpen(tester);

      // empty
      await tester.tap(find.byKey(goKey), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(connected, isEmpty);
      expect(find.byKey(dialogKey), findsOneWidget);

      // too short, also with Enter
      await tester.enterText(find.byKey(fieldKey), '123');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(goKey), warnIfMissed: false);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(connected, isEmpty);
      expect(find.byKey(dialogKey), findsOneWidget);

      // letters are dropped
      await tester.enterText(find.byKey(fieldKey), 'a1b2-3');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(fieldKey)).controller!.text,
          '123');
    });

    testWidgets('valid ID with spaces goes to onConnect without spaces',
        (tester) async {
      final connected = await pumpAndOpen(tester);
      await tester.enterText(find.byKey(fieldKey), '987 654 321');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(goKey));
      await tester.pumpAndSettle();
      expect(connected, ['987654321']);
      expect(find.byKey(dialogKey), findsNothing);
    });

    testWidgets('Enter connects', (tester) async {
      final connected = await pumpAndOpen(tester);
      await tester.enterText(find.byKey(fieldKey), '123 456 789');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(connected, ['123456789']);
      expect(find.byKey(dialogKey), findsNothing);
    });

    testWidgets('Esc and cancel close without connecting', (tester) async {
      final connected = await pumpAndOpen(tester);
      await tester.enterText(find.byKey(fieldKey), '123 456 789');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsNothing);

      await tester.tap(find.byKey(openKey));
      await tester.pumpAndSettle();
      // a reopened window starts empty
      expect(tester.widget<TextField>(find.byKey(fieldKey)).controller!.text,
          '');
      await tester.tap(find.byKey(const Key('sense-connect-id-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(dialogKey), findsNothing);
      expect(connected, isEmpty);
    });
  });

  group('Host home view', () {
    test('state from service status', () {
      expect(
          senseHostStateFrom(status: SvcStatus.ready, serviceStopped: false),
          SenseHostState.ready);
      expect(
          senseHostStateFrom(
              status: SvcStatus.connecting, serviceStopped: false),
          SenseHostState.connecting);
      expect(
          senseHostStateFrom(status: SvcStatus.notReady, serviceStopped: false),
          SenseHostState.notReady);
      expect(senseHostStateFrom(status: SvcStatus.ready, serviceStopped: true),
          SenseHostState.serviceStopped);
    });

    testWidgets('name, location, ready, lock note; fits 280 px',
        (tester) async {
      await _pump(
          tester,
          const SizedBox(
            width: 280,
            child: SenseHostHomeView(
                name: 'Galeri kioskı',
                location: 'Galeri 1',
                deviceId: '123456789',
                state: SenseHostState.ready),
          ),
          size: const Size(280, 600));
      expect(find.text('Galeri kioskı'), findsOneWidget);
      expect(find.text('Galeri 1'), findsOneWidget);
      expect(find.text(t('ready')), findsOneWidget);
      expect(find.text(t('locked_note')), findsOneWidget);
      expect(find.byKey(const Key('sense-host-start-service')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no name yet; stopped service can be started', (tester) async {
      var started = 0;
      await _pump(
          tester,
          SizedBox(
            width: 280,
            child: SenseHostHomeView(
                name: '',
                location: '',
                deviceId: '',
                state: SenseHostState.serviceStopped,
                onStartService: () => started++),
          ),
          size: const Size(280, 600));
      expect(find.byKey(const Key('sense-host-name')), findsOneWidget);
      expect(find.text(t('this_computer')), findsOneWidget);
      expect(find.byKey(const Key('sense-host-location')), findsNothing);
      expect(find.text(t('service_stopped')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-host-start-service')));
      expect(started, 1);
    });
  });

  group('About', () {
    test('panel line', () {
      expect(
          senseAboutPanelText(role: SenseHomeRole.controller, account: 'Halil'),
          'Bağlı · Halil');
      expect(senseAboutPanelText(role: SenseHomeRole.host, account: ''),
          t('panel_managed'));
      expect(senseAboutPanelText(role: SenseHomeRole.controller, account: ''),
          t('panel_signed_out'));
    });

    testWidgets('Sense Remote, version, role, panel, license link',
        (tester) async {
      final opened = <String>[];
      await _pump(
          tester,
          SenseAboutView(
              version: 1,
              role: SenseHomeRole.both,
              account: 'Halil',
              baseVersion: '1.5.3',
              year: 2026,
              onOpenUrl: opened.add));
      expect(find.text('Sürüm 1'), findsOneWidget);
      expect(find.text('Host + Controller'), findsOneWidget);
      expect(find.text('Bağlı · Halil'), findsOneWidget);
      expect(find.text('© 2026 Sense Department · '), findsOneWidget);

      await tester.tap(find.byKey(const Key('sense-about-licenses')));
      await tester.pumpAndSettle();
      expect(find.text(t('licenses_body')), findsOneWidget);
      expect(find.text('Taban sürüm: 1.5.3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-licenses-source')));
      await tester.tap(find.byKey(const Key('sense-licenses-text')));
      expect(opened, [kSenseSourceUrl, kSenseLicenseUrl]);
      await tester.tap(find.byKey(const Key('sense-licenses-close')));
      await tester.pumpAndSettle();
      expect(find.text(t('licenses_body')), findsNothing);
    });

    testWidgets('no version number: no version line (nothing made up)',
        (tester) async {
      await _pump(
          tester,
          SenseAboutView(
              version: null,
              role: SenseHomeRole.host,
              account: '',
              onOpenUrl: (_) {}));
      expect(find.byKey(const Key('sense-about-version')), findsNothing);
      expect(find.text('Host'), findsOneWidget);
    });
  });

  test('no upstream product name in the Sense home screens', () {
    const files = [
      'lib/desktop/pages/sense_home_controller.dart',
      'lib/desktop/pages/sense_home_connect_id.dart',
      'lib/desktop/pages/sense_home_host.dart',
      'lib/desktop/pages/sense_home_mac.dart',
      'lib/desktop/pages/sense_home_about.dart',
      'lib/desktop/pages/sense_home_strings.dart',
    ];
    final banned = RegExp('rust' 'desk', caseSensitive: false);
    for (final path in files) {
      expect(banned.hasMatch(File(path).readAsStringSync()), isFalse,
          reason: path);
    }
    for (final text in kSenseHomeTr.values) {
      expect(banned.hasMatch(text), isFalse, reason: text);
    }
  });
}
