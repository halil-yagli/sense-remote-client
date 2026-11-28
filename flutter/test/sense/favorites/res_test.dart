// Sense Remote (Sürüm 12, #171, #158): the Host's answers in the "Sık kullanılanlar" list —
// ping with the address as the one argument, the window list (`res.windows`) and closing one
// by process id, the IP card from the Host (`res.ip`), and the bodies exactly as the Host
// builds them (`src/sense/shortcuts/results.rs`, `peer_msg.rs` tests).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/catalog.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_io.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_list.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_model.dart';
import 'package:flutter_hbb/sense/strings/favorites.dart';

import 'support.dart';

Future<SenseFavoritesModel> pumpPanes(WidgetTester t, FakeFavIo io, {List<String>? notes, SenseFavOs os = SenseFavOs.win}) async {
  setWindow(t, const Size(500, 1400));
  final m = SenseFavoritesModel(
      io: io, os: os, peerId: 'p1', computerName: 'Giriş Salonu PC-2', onNotice: notes?.add);
  await m.load();
  await t.pumpWidget(listApp(SenseFavoritesList(model: m, onNotify: notes?.add)));
  await t.pump();
  addTearDown(m.dispose);
  return m;
}

FakeFavIo paneIo(List<String> ids, {SenseFavOs os = SenseFavOs.win}) => FakeFavIo(prefs: {
      os: prefsJson(os: os, items: [for (final id in ids) {'id': id, 'key': null}])
    }, setAnswer: '');

void main() {
  setUp(senseFavResetMemory);

  group('result bodies (#171)', () {
    test('ping counts → one line; no reply → no average, 100 % loss', () {
      expect(senseFavPingText(kResPing), '4/4 yanıt · ort. 18 ms · kayıp %0');
      expect(senseFavPingText(kResPingLost), '0/4 yanıt · ort. — ms · kayıp %100');
      expect(senseFavPingText(const {'windows': []}), isNull);
      expect(senseFavPingText(null), isNull);
    });

    test('window list: entries without pid or name are dropped, hung kept', () {
      final w = senseFavWindowsFrom({
        'windows': [
          ...kResWindows['windows'] as List,
          {'pid': 0, 'name': 'Sistem', 'hung': false},
          {'pid': 99, 'name': '  ', 'hung': false},
        ]
      })!;
      expect(w.map((x) => x.pid), [4120, 5532, 7781]);
      expect(w.first.hung, isTrue);
      expect(senseFavWindowsFrom(const {'ping': {}}), isNull);
    });

    test('IP card from the Host; an empty address stays empty', () {
      final ip = senseFavIpFromRes(kResIp)!;
      expect(ip.ip, '192.168.10.42');
      expect(ip.dns, ['192.168.10.1', '8.8.8.8']);
      final none = senseFavIpFromRes(const {'ip': {'ip': null, 'gateway': [], 'dns': []}})!;
      expect(none.empty, isTrue);
    });

    test('the event body comes nested (core) or as a string; both are read', () {
      expect(SenseFavoritesEvents.resOf(kResPing)!['ping'], isA<Map>());
      expect(SenseFavoritesEvents.resOf('{"ip":{"ip":"10.0.0.2"}}')!['ip'], {'ip': '10.0.0.2'});
      expect(SenseFavoritesEvents.resOf(null), isNull);
      expect(SenseFavoritesEvents.resOf('null'), isNull);
      expect(SenseFavoritesEvents.resOf('garbage'), isNull);
    });

    test('ping address: the Host rule (letters, digits, . - :), no leading - or .', () {
      for (final ok in ['8.8.8.8', 'sergi.example', 'fe80::1', 'pc-2']) {
        expect(senseFavPingAddressOk(ok), isTrue, reason: ok);
      }
      for (final bad in ['', '-t', '.x', '8.8.8.8 -n 1', 'a;b', 'a&b', 'x' * 254]) {
        expect(senseFavPingAddressOk(bad), isFalse, reason: bad);
      }
    });
  });

  group('model', () {
    testWidgets('ping sends the address as arg and reads res.ping', (t) async {
      final io = FakeFavIo()..host['win.ping'] = ((run) => (ok: true, err: null, res: kResPing));
      final m = await loadedModel(io);
      final f = m.ping('win.ping', ' 8.8.8.8 ');
      await t.pump();
      expect(await f, '4/4 yanıt · ort. 18 ms · kayıp %0');
      expect(io.sent.single.$1, 'sense.shortcut-run');
      expect(io.sent.single.$2, {'req': 1, 'id': 'win.ping', 'arg': '8.8.8.8'});
      m.dispose();
    });

    testWidgets('a Host refusal is said with its reason, never a dialog', (t) async {
      final io = FakeFavIo()..host['win.ping'] = ((run) => (ok: false, err: 'no_permission', res: null));
      final m = await loadedModel(io);
      final f = m.ping('win.ping', '8.8.8.8');
      await t.pump();
      expect(await f, SenseFavoritesStrings.errNoPermission);
      m.dispose();
    });

    testWidgets('pane answers do not toast "açıldı"', (t) async {
      final notes = <String>[];
      final io = FakeFavIo()..host['win.ipinfo'] = ((run) => (ok: true, err: null, res: kResIp));
      final m = await loadedModel(io, notices: notes);
      final f = m.hostIpInfo('win.ipinfo');
      await t.pump();
      expect((await f)!.ip, '192.168.10.42');
      expect(notes, isEmpty);
      m.dispose();
    });

    testWidgets('without keyboard and mouse permission nothing is asked of the Host', (t) async {
      final io = FakeFavIo();
      final m = await loadedModel(io, input: false);
      expect((await m.request('win.killhung')).err, 'no_permission');
      expect(io.sent, isEmpty);
      m.dispose();
    });
  });

  group('panes on screen', () {
    testWidgets('ping pane shows the Host result', (t) async {
      final io = paneIo(['win.ping'])..host['win.ping'] = ((run) => (ok: true, err: null, res: kResPing));
      await pumpPanes(t, io);
      await t.tap(find.byKey(const ValueKey('sense-fav-run-win.ping')));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('sense-fav-ping-addr')), 'sergi.example');
      await t.tap(find.byKey(const ValueKey('sense-fav-ping-start')));
      await t.pump();
      await t.pump();
      expect(find.text('4/4 yanıt · ort. 18 ms · kayıp %0'), findsOneWidget);
      expect(io.sent.last.$2['arg'], 'sergi.example');
    });

    testWidgets('window list: names, hung marked, Kapat sends the pid and drops the row', (t) async {
      final notes = <String>[];
      final io = paneIo(['win.killhung'])
        ..host['win.killhung'] = ((run) => run['arg'] == null
            ? (ok: true, err: null, res: kResWindows)
            : (ok: true, err: null, res: null));
      await pumpPanes(t, io, notes: notes);
      await t.tap(find.byKey(const ValueKey('sense-fav-run-win.killhung')));
      await t.pump();
      await t.pump();
      expect(find.text('Sergi uygulaması — yanıt vermiyor'), findsOneWidget);
      expect(find.text('Medya oynatıcı'), findsOneWidget);
      expect(find.byKey(const ValueKey('sense-fav-window-close-4120')), findsOneWidget);
      expect(find.text(SenseFavoritesStrings.windowClose), findsNWidgets(3));

      await t.tap(find.byKey(const ValueKey('sense-fav-window-close-5532')));
      await t.pump();
      await t.pump();
      expect(io.sent.last.$2, {'req': 2, 'id': 'win.killhung', 'arg': '5532'});
      expect(find.text('Medya oynatıcı'), findsNothing);
      expect(notes.last, 'Medya oynatıcı kapatıldı · Giriş Salonu PC-2');
    });

    testWidgets('window list: the Host refuses closing → the reason under the list', (t) async {
      final io = paneIo(['win.killhung'])
        ..host['win.killhung'] = ((run) => run['arg'] == null
            ? (ok: true, err: null, res: kResWindows)
            : (ok: false, err: 'failed', res: null));
      await pumpPanes(t, io);
      await t.tap(find.byKey(const ValueKey('sense-fav-run-win.killhung')));
      await t.pump();
      await t.pump();
      await t.tap(find.byKey(const ValueKey('sense-fav-window-close-4120')));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('sense-fav-windows-error')), findsOneWidget);
      expect(find.text('Sergi uygulaması — yanıt vermiyor'), findsOneWidget, reason: 'row stays');
    });

    testWidgets('Mac: the button says Çık', (t) async {
      final io = paneIo(['mac.forcequit'], os: SenseFavOs.mac)
        ..host['mac.forcequit'] = ((run) => (ok: true, err: null, res: kResWindows));
      await pumpPanes(t, io, os: SenseFavOs.mac);
      await t.tap(find.byKey(const ValueKey('sense-fav-run-mac.forcequit')));
      await t.pump();
      await t.pump();
      expect(find.text(SenseFavoritesStrings.windowQuit), findsNWidgets(3));
    });

    testWidgets('IP card: the Host values replace the session data', (t) async {
      final io = paneIo(['win.ipinfo'])
        ..host['win.ipinfo'] = ((run) => (ok: true, err: null, res: kResIp));
      final m = await pumpPanes(t, io);
      m.ipInfo = () => const SenseFavIpInfo(ip: '10.0.0.9');
      await t.tap(find.byKey(const ValueKey('sense-fav-run-win.ipinfo')));
      await t.pump();
      expect(find.text('10.0.0.9'), findsOneWidget, reason: 'session data first');
      await t.pump();
      expect(find.text('192.168.10.42'), findsOneWidget);
      expect(find.text('192.168.10.1 · 8.8.8.8'), findsOneWidget);
      expect(find.text('10.0.0.9'), findsNothing);
    });
  });
}
