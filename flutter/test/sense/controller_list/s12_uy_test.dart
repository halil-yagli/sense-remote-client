// Sense Remote (Sürüm 12, paket UY): "Aktarmayla bağlan" (FU-A1, FU-A2), the menu dots (FU-A3)
// and the grants grace of the first start (#149).
//   - Kimlikle bağlan has the check row "Aktarma sunucusu üzerinden bağlan"; ticked, the box
//     connects over the relay server.
//   - the tile's "⋯" menu ends with "Aktarmayla bağlan" (the connect right), under a line.
//   - Hakkında (update waits) and Bu bilgisayar (Host not ready) get a dot.
//   - the first failed grants answers are not shown: 3 answers in a row first.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/state_model.dart' show SvcStatus;
import 'package:flutter_hbb/sense/screens/controller/computers/computers_page.dart' show senseKindAllowed;
import 'package:flutter_hbb/sense/screens/controller/computers/computers_view.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/tile_more.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/widgets.dart';
import 'package:flutter_hbb/sense/screens/controller/data/grants.dart';
import 'package:flutter_hbb/sense/screens/controller/login/login_controller.dart';
import 'package:flutter_hbb/sense/screens/controller/login/login_page.dart';
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart' show SenseHomeRole;
import 'package:flutter_hbb/sense/screens/controller/shell/controller_shell.dart';
import 'package:flutter_hbb/sense/screens/host/shell/host_shell.dart' show SenseHostNav, SenseHostShellView;
import 'package:flutter_hbb/sense/screens/controller/shell/nav_dots.dart';
import 'package:flutter_hbb/sense/sense.dart' show SenseLevel, SenseStatusDot;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _online = '482913207';

Future<({List<String> plain, List<String> relay, List<String> kinds})> _pumpView(
  WidgetTester tester, {
  bool idOpen = false,
  bool relayBox = true,
  bool file = true,
  bool terminal = true,
  bool canRelay = true,
  bool canConnect = true,
}) async {
  final plain = <String>[], relay = <String>[], kinds = <String>[];
  setWindow(tester, const Size(1180, 1400));
  await tester.pumpWidget(app(page(SenseComputersView(
    projects: exampleProjects(),
    now: kNow,
    canConnect: canConnect,
    canFileTransfer: file,
    canTerminalTunnel: terminal,
    canRelay: canRelay,
    initialIdOpen: idOpen,
    onConnect: plain.add,
    onConnectRelay: relayBox ? relay.add : null,
    onConnectKind: (id, k) => kinds.add('$id:${k.name}'),
  ))));
  await tester.pump();
  return (plain: plain, relay: relay, kinds: kinds);
}

void main() {
  group('FU-A1: Kimlikle bağlan, Aktarma sunucusu üzerinden bağlan', () {
    Future<void> typeId(WidgetTester tester) async {
      await tester.enterText(find.byKey(const Key('sense-id-field')), '482 913 207');
      await tester.pump();
    }

    testWidgets('the check row is there, off, with the prototype text', (tester) async {
      await _pumpView(tester, idOpen: true);
      expect(find.byKey(const Key('sense-id-relay')), findsOneWidget);
      expect(find.text('Aktarma sunucusu üzerinden bağlan · doğrudan yol takılırsa'), findsOneWidget);
    });

    testWidgets('not ticked: connects directly', (tester) async {
      final r = await _pumpView(tester, idOpen: true);
      await typeId(tester);
      await tester.tap(find.byKey(const Key('sense-id-connect')));
      await tester.pump();
      expect(r.plain, ['482913207']);
      expect(r.relay, isEmpty);
    });

    testWidgets('ticked: connects over the relay server', (tester) async {
      final r = await _pumpView(tester, idOpen: true);
      await typeId(tester);
      await tester.tap(find.byKey(const Key('sense-id-relay')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-id-connect')));
      await tester.pump();
      expect(r.relay, ['482913207']);
      expect(r.plain, isEmpty);
    });

    testWidgets('ticked and unticked again: direct again', (tester) async {
      final r = await _pumpView(tester, idOpen: true);
      await typeId(tester);
      await tester.tap(find.byKey(const Key('sense-id-relay')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-id-relay')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-id-connect')));
      await tester.pump();
      expect(r.plain, ['482913207']);
    });

    testWidgets('a wrong ID connects nowhere, ticked or not', (tester) async {
      final r = await _pumpView(tester, idOpen: true);
      await tester.enterText(find.byKey(const Key('sense-id-field')), '12');
      await tester.tap(find.byKey(const Key('sense-id-relay')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-id-connect')));
      await tester.pump();
      expect(r.plain, isEmpty);
      expect(r.relay, isEmpty);
    });

    testWidgets('no relay callback, no check row (the box as before)', (tester) async {
      await _pumpView(tester, idOpen: true, relayBox: false);
      expect(find.byKey(const Key('sense-id-relay')), findsNothing);
    });

    testWidgets('locked without the connect right: the box connects nowhere', (tester) async {
      final r = await _pumpView(tester, idOpen: true, canConnect: false);
      await typeId(tester);
      await tester.tap(find.byKey(const Key('sense-id-connect')), warnIfMissed: false);
      await tester.pump();
      expect(r.plain, isEmpty);
      expect(r.relay, isEmpty);
    });

    testWidgets('the sign-in page has the same row', (tester) async {
      final relay = <String>[];
      final c = SenseLoginController(FakeLogin());
      setWindow(tester, const Size(1180, 900));
      await tester.pumpWidget(app(SenseLoginPage(controller: c, onConnect: (_) {}, onConnectRelay: relay.add)));
      await tester.tap(find.byKey(const Key('sense-login-id')));
      await tester.pump();
      expect(find.byKey(const Key('sense-id-relay')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('sense-id-field')), '482913207');
      await tester.tap(find.byKey(const Key('sense-id-relay')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-id-connect')));
      await tester.pump();
      expect(relay, ['482913207']);
      c.dispose();
    });

    testWidgets('the sign-in page without the callback has no row', (tester) async {
      final c = SenseLoginController(FakeLogin());
      setWindow(tester, const Size(1180, 900));
      await tester.pumpWidget(app(SenseLoginPage(controller: c, onConnect: (_) {})));
      await tester.tap(find.byKey(const Key('sense-login-id')));
      await tester.pump();
      expect(find.byKey(const Key('sense-id-field')), findsOneWidget);
      expect(find.byKey(const Key('sense-id-relay')), findsNothing);
      c.dispose();
    });
  });

  group('FU-A2: Aktarmayla bağlan in the "⋯" menu', () {
    test('relay is the last entry and only when asked', () {
      expect(senseMoreKinds(fileTransfer: true, terminalTunnel: true, relay: true), [
        SenseConnectKind.fileTransfer,
        SenseConnectKind.terminal,
        SenseConnectKind.tcpTunnel,
        SenseConnectKind.relay,
      ]);
      expect(senseMoreKinds(fileTransfer: false, terminalTunnel: false, relay: true), [SenseConnectKind.relay]);
      expect(senseMoreKinds(fileTransfer: true, terminalTunnel: true), isNot(contains(SenseConnectKind.relay)));
    });

    test('relay needs only the connect right (checked by the caller)', () {
      const ok = SenseGrants(state: SenseGrantsState.ok, perms: {SensePerm.connect});
      expect(senseKindAllowed(SenseConnectKind.relay, ok), isTrue);
      expect(senseConnectKindLabel(SenseConnectKind.relay), 'Aktarmayla bağlan');
    });

    testWidgets('the menu ends with the line and Aktarmayla bağlan · Doğrudan yol takılırsa', (tester) async {
      final r = await _pumpView(tester);
      await tester.tap(find.byKey(const Key('sense-tile-more-$_online')));
      await tester.pump();
      expect(find.text('Aktarmayla bağlan'), findsOneWidget);
      expect(find.text('Doğrudan yol takılırsa'), findsOneWidget);
      expect(find.byKey(const Key('sense-tile-more-sep-$_online')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-tile-more-relay-$_online')));
      await tester.pump();
      expect(r.kinds, ['$_online:relay']);
      expect(find.byKey(const Key('sense-tile-more-menu-$_online')), findsNothing, reason: 'menu closes');
    });

    testWidgets('the three other entries are still there', (tester) async {
      await _pumpView(tester);
      await tester.tap(find.byKey(const Key('sense-tile-more-$_online')));
      await tester.pump();
      for (final t in ['Dosya aktarımı', 'Terminal', 'TCP tünel']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
    });

    testWidgets('without file and terminal rights the menu has only the relay entry, no line', (tester) async {
      await _pumpView(tester, file: false, terminal: false);
      await tester.tap(find.byKey(const Key('sense-tile-more-$_online')));
      await tester.pump();
      expect(find.text('Aktarmayla bağlan'), findsOneWidget);
      expect(find.text('Dosya aktarımı'), findsNothing);
      expect(find.byKey(const Key('sense-tile-more-sep-$_online')), findsNothing);
    });

    testWidgets('no connect right: no menu at all', (tester) async {
      await _pumpView(tester, canConnect: false);
      expect(find.byKey(const Key('sense-tile-more-$_online')), findsNothing);
    });

    testWidgets('canRelay off (the default): the menu is as before', (tester) async {
      await _pumpView(tester, canRelay: false, file: false, terminal: false);
      expect(find.byKey(const Key('sense-tile-more-$_online')), findsNothing);
    });
  });

  group('FU-A3: dots in the left menu', () {
    Future<void> pumpShell(WidgetTester tester, {SenseLevel? about, SenseLevel? host}) async {
      setWindow(tester, const Size(1180, 720));
      await tester.pumpWidget(app(SenseControllerShellView(
        role: SenseHomeRole.both,
        nav: SenseControllerNav.computers,
        onNav: (_) {},
        signedIn: true,
        name: 'Halil',
        email: 'halil@example.com',
        computerCount: 8,
        version: 4,
        aboutLevel: about,
        thisComputerLevel: host,
        child: const Center(child: Text('sayfa')),
      )));
    }

    testWidgets('no dots by default', (tester) async {
      await pumpShell(tester);
      expect(find.byKey(const Key('sense-nav-dot-warn')), findsNothing);
      expect(find.byKey(const Key('sense-nav-dot-hot')), findsNothing);
    });

    testWidgets('yellow dot on Hakkında, red dot on Bu bilgisayar', (tester) async {
      await pumpShell(tester, about: SenseLevel.warn, host: SenseLevel.hot);
      expect(
          find.descendant(
              of: find.byKey(const Key('sense-controller-nav-about')), matching: find.byKey(const Key('sense-nav-dot-warn'))),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(const Key('sense-controller-nav-thisComputer')),
              matching: find.byKey(const Key('sense-nav-dot-hot'))),
          findsOneWidget);
    });

    testWidgets('ok and unknown draw no dot', (tester) async {
      await pumpShell(tester, about: SenseLevel.ok, host: SenseLevel.unknown);
      expect(find.byKey(const Key('sense-nav-dot-ok')), findsNothing);
      expect(find.byKey(const Key('sense-nav-dot-unknown')), findsNothing);
    });

    testWidgets('the dot is said to screen readers', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpShell(tester, about: SenseLevel.warn, host: SenseLevel.hot);
      expect(find.bySemanticsLabel(RegExp('Hakkında, güncelleme var')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Bu bilgisayar, Host hazır değil')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the Host window shows the same dots', (tester) async {
      Future<int> dots({SenseLevel? host, SenseLevel? about}) async {
        setWindow(tester, const Size(1180, 720));
        await tester.pumpWidget(app(SenseHostShellView(
          nav: SenseHostNav.thisComputer,
          onNav: (_) {},
          navLevel: host,
          aboutLevel: about,
          version: 4,
          child: const Text('sayfa'),
        )));
        return find.byType(SenseStatusDot).evaluate().length;
      }

      expect(await dots(), 0);
      expect(await dots(host: SenseLevel.hot), 1);
      expect(await dots(host: SenseLevel.hot, about: SenseLevel.warn), 2);
      expect(await dots(about: SenseLevel.warn), 1);
    });

    test('the watcher shows the dot after the delay and drops it at the first good look', () {
      var svc = SvcStatus.notReady;
      var stopped = false;
      var now = DateTime(2026, 11, 28, 12);
      final seen = <SenseLevel?>[];
      final w = SenseHostDotWatch(
          onChanged: seen.add, svc: () => svc, stopped: () => stopped, now: () => now);
      w.check();
      expect(w.level, isNull, reason: 'a moment at each start');
      now = now.add(kSenseHostDotDelay - const Duration(seconds: 1));
      w.check();
      expect(w.level, isNull);
      now = now.add(const Duration(seconds: 2));
      w.check();
      expect(w.level, SenseLevel.hot);
      w.check();
      expect(seen, [SenseLevel.hot], reason: 'told once');
      svc = SvcStatus.ready;
      w.check();
      expect(w.level, isNull);
      expect(seen, [SenseLevel.hot, null]);
      // A stopped service counts too, and the delay starts again.
      stopped = true;
      w.check();
      expect(w.level, isNull);
      now = now.add(kSenseHostDotDelay);
      w.check();
      expect(w.level, SenseLevel.hot);
      w.dispose();
    });

    test('Host dot: red only when the server cannot be reached or the service is stopped', () {
      expect(senseHostNavLevel(svc: SvcStatus.notReady, stopped: false), SenseLevel.hot);
      expect(senseHostNavLevel(svc: SvcStatus.ready, stopped: true), SenseLevel.hot);
      expect(senseHostNavLevel(svc: SvcStatus.ready, stopped: false), isNull);
      expect(senseHostNavLevel(svc: SvcStatus.connecting, stopped: false), isNull, reason: 'a moment at each start');
    });
  });

  group('#149: the first failed grants answers are not shown', () {
    Map<String, Object?> missing() => {'state': 'missing'};

    SenseGrantsWatch watch(FakeGrants fake) =>
        SenseGrantsWatch(fake, interval: const Duration(hours: 1), quickInterval: const Duration(hours: 1));

    test('an ok answer is settled at once', () async {
      final w = watch(FakeGrants())..start();
      await pumpEventQueue();
      expect(w.settled, isTrue);
      w.dispose();
    });

    test('missing is not settled for two answers; the third one says it', () async {
      final fake = FakeGrants(missing());
      final w = watch(fake)..start();
      await pumpEventQueue();
      expect(w.loaded, isTrue, reason: 'there is an answer');
      expect(w.settled, isFalse, reason: '1st');
      await w.refresh();
      expect(w.settled, isFalse, reason: '2nd');
      await w.refresh();
      expect(w.settled, isTrue, reason: '3rd');
      expect(w.grants.ok, isFalse);
      w.dispose();
    });

    test('the third answer notifies, so the screen shows the warning then', () async {
      final fake = FakeGrants(missing());
      final w = watch(fake)..start();
      await pumpEventQueue();
      var n = 0;
      w.addListener(() => n++);
      await w.refresh();
      expect(n, 0, reason: 'nothing new to show on the 2nd');
      await w.refresh();
      expect(n, 1, reason: 'settled flips on the 3rd');
      w.dispose();
    });

    test('a good answer in between starts the count again', () async {
      final fake = FakeGrants(missing());
      final w = watch(fake)..start();
      await pumpEventQueue();
      await w.refresh();
      fake.answer = jsonEncode({'state': 'ok', 'perms': SensePerm.all});
      await w.refresh();
      expect(w.settled, isTrue);
      fake.answer = jsonEncode(missing());
      await w.refresh();
      expect(w.settled, isFalse, reason: 'one miss after an ok is not a warning');
      w.dispose();
    });

    test('the quick retries ask again by themselves, then stop', () async {
      final fake = FakeGrants(missing());
      final w = SenseGrantsWatch(fake,
          interval: const Duration(hours: 1), quickInterval: const Duration(milliseconds: 10))
        ..start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(w.settled, isTrue, reason: '3 answers without any refresh');
      w.dispose();
    });

    test('settled, "Bağlanma yetkin kaldırıldı" applies; before it, grants are not judged', () async {
      final fake = FakeGrants(missing());
      final w = watch(fake)..start();
      await pumpEventQueue();
      expect(w.grants.can(SensePerm.connect), isFalse);
      expect(w.settled, isFalse, reason: 'the page treats this as "not known yet"');
      w.dispose();
    });
  });
}
