// Sense Remote (Sürüm 12, #160–#163, #167): golden images of the "Sık kullanılanlar" list,
// compared by eye with the prototype's "Sık kullanılanlar" list (`favHTML`; Karşı bilgisayar
// Windows / Mac / Linux, "Klavye ve fare yetkisi yok"). Images are made on CI
// (sense-golden.yml); until one exists its test is skipped. Data: the prototype's own
// example list (`ST.fav`, `ST.favKey`, `ST.favRecent`, `ST.favCust`).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/catalog.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_list.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_model.dart';

import 'support.dart';

Future<void> shot(
  WidgetTester t,
  String name, {
  required FakeFavIo io,
  SenseFavOs os = SenseFavOs.win,
  bool input = true,
  Future<void> Function(WidgetTester t, SenseFavoritesModel m)? act,
  double maxHeight = 1300,
}) async {
  setWindow(t, const Size(420, 1400));
  final m = SenseFavoritesModel(
    io: io,
    os: os,
    peerId: 'golden',
    computerName: 'Giriş Salonu PC-2',
    inputAllowed: input,
    ipInfo: () => const SenseFavIpInfo(ip: '192.168.10.42', gateway: ['192.168.10.1'], dns: ['192.168.10.1', '8.8.8.8']),
  );
  await m.load();
  await t.pumpWidget(listApp(SenseFavoritesList(model: m, maxHeight: maxHeight)));
  await t.pump();
  if (act != null) await act(t, m);
  await t.pump(const Duration(milliseconds: 400));
  await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile(name)));
  m.dispose();
}

FakeFavIo winIo() => FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs()}, setAnswer: '');

Future<void> tapKey(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  await t.pump();
}

void main() {
  setUp(senseFavResetMemory);

  testWidgets('dolu: Windows list, Sistem hareketleri open',
      (t) => shot(t, 'fav_win_full', io: winIo(), act: (t, m) => tapKey(t, 'sense-fav-group-actions')),
      skip: goldenSkip('fav_win_full'), tags: const ['golden']);

  testWidgets('boş: nothing chosen yet, this build keeps it in memory',
      (t) => shot(t, 'fav_empty', io: FakeFavIo()),
      skip: goldenSkip('fav_empty'), tags: const ['golden']);

  testWidgets('arama: "ağ"', (t) => shot(t, 'fav_search', io: winIo(), act: (t, m) async {
        await t.enterText(find.byKey(const ValueKey('sense-fav-search')), 'ağ');
        await t.pump();
      }), skip: goldenSkip('fav_search'), tags: const ['golden']);

  testWidgets('pasif: no keyboard and mouse permission',
      (t) => shot(t, 'fav_passive', io: winIo(), input: false),
      skip: goldenSkip('fav_passive'), tags: const ['golden']);

  testWidgets('Mac list, Mac’e özel open', (t) => shot(t, 'fav_mac',
      io: FakeFavIo(prefs: {SenseFavOs.mac: prototypeMacPrefs()}, setAnswer: ''),
      os: SenseFavOs.mac,
      act: (t, m) => tapKey(t, 'sense-fav-group-mac')), skip: goldenSkip('fav_mac'), tags: const ['golden']);

  testWidgets('Linux placeholder', (t) => shot(t, 'fav_linux', io: FakeFavIo(), os: SenseFavOs.linux),
      skip: goldenSkip('fav_linux'), tags: const ['golden']);

  FakeFavIo paneIo() => FakeFavIo(prefs: {
        SenseFavOs.win: prefsJson(os: SenseFavOs.win, items: [
          {'id': 'win.ipinfo', 'key': null},
          {'id': 'win.logoff', 'key': 3},
          {'id': 'win.taskmgr', 'key': 1},
          {'id': 'win.ping', 'key': null},
        ], recent: ['win.taskmgr'])
      }, setAnswer: '')
        // Sürüm 12 (#171): the Host answers with its own values.
        ..hostPeer = 'golden'
        ..host['win.ipinfo'] = ((_) => (ok: true, err: null, res: kResIp))
        ..host['win.ping'] = ((_) => (ok: true, err: null, res: kResPing));

  testWidgets('window list from the Host (#171), the one that does not answer first',
      (t) => shot(t, 'fav_windows',
          io: FakeFavIo(prefs: {
            SenseFavOs.win: prefsJson(os: SenseFavOs.win, items: [
              {'id': 'win.killhung', 'key': 2},
              {'id': 'win.taskmgr', 'key': 1},
            ])
          }, setAnswer: '')
            ..hostPeer = 'golden'
            ..host['win.killhung'] = ((_) => (ok: true, err: null, res: kResWindows)),
          act: (t, m) => tapKey(t, 'sense-fav-run-win.killhung')),
      skip: goldenSkip('fav_windows'), tags: const ['golden']);

  testWidgets('IP card under its row', (t) => shot(t, 'fav_ip', io: paneIo(),
      act: (t, m) => tapKey(t, 'sense-fav-run-win.ipinfo')), skip: goldenSkip('fav_ip'), tags: const ['golden']);

  testWidgets('in-place question (Oturumu kapat)', (t) => shot(t, 'fav_ask', io: paneIo(),
      act: (t, m) => tapKey(t, 'sense-fav-run-win.logoff')), skip: goldenSkip('fav_ask'), tags: const ['golden']);

  testWidgets('ping pane after Başlat', (t) => shot(t, 'fav_ping', io: paneIo(), act: (t, m) async {
        await tapKey(t, 'sense-fav-run-win.ping');
        await tapKey(t, 'sense-fav-ping-start');
      }), skip: goldenSkip('fav_ping'), tags: const ['golden']);

  testWidgets('key slots under a row', (t) => shot(t, 'fav_keys', io: winIo(),
      act: (t, m) => tapKey(t, 'sense-fav-key-win.taskmgr')), skip: goldenSkip('fav_keys'), tags: const ['golden']);

  testWidgets('custom form and a pending request', (t) => shot(t, 'fav_custom_form',
          io: FakeFavIo(
              prefs: {SenseFavOs.win: prototypeWinPrefs()},
              setAnswer: '',
              customAnswer: '{"id":"a1","status":"pending"}'), act: (t, m) async {
        await m.requestCustom(const SenseFavCustomForm(
            name: 'Kiosk tarayıcısı',
            os: SenseFavOs.win,
            kind: SenseFavCustomKind.url,
            target: 'https://sergi.example/kiosk',
            scope: SenseFavCustomScope.project));
        await t.pump();
        await tapKey(t, 'sense-fav-group-custom');
        await tapKey(t, 'sense-fav-add');
      }), skip: goldenSkip('fav_custom_form'), tags: const ['golden']);

  testWidgets('dar: bar buttons, name (wide) and star (narrow, #167)', (t) async {
    setWindow(t, const Size(420, 220));
    await t.pumpWidget(listApp(const Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        SenseFavoritesButton(compact: false),
        SizedBox(width: 12),
        SenseFavoritesButton(compact: false, open: true),
      ]),
      SizedBox(height: 12),
      Row(mainAxisSize: MainAxisSize.min, children: [
        SenseFavoritesButton(compact: true),
        SizedBox(width: 12),
        SenseFavoritesButton(compact: true, open: true),
      ]),
    ])));
    await t.pump();
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('fav_buttons')));
  }, skip: goldenSkip('fav_buttons'), tags: const ['golden']);
}
