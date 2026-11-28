// Sense Remote (Sürüm 12, paket UY; A7 of the prototype difference report): golden images of
// the Controller states that had none, compared by eye with the prototype's demo selector.
//   - Kimlikle bağlan with "Aktarma sunucusu üzerinden bağlan" (FU-A1)
//   - the tile's "⋯" menu open, with "Aktarmayla bağlan" (FU-A2)
//   - the left menu dots (FU-A3)
//   - cards: Meşgul, Kapalı (Yine de dene), "Yetkin yok" and "Yetkiler panelden alınamadı"
// Images are made by the golden workflow on Linux; until one exists its test is skipped.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/computers_view.dart';
import 'package:flutter_hbb/sense/screens/controller/data/peers.dart';
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart' show SenseHomeRole;
import 'package:flutter_hbb/sense/screens/controller/shell/controller_shell.dart';
import 'package:flutter_hbb/sense/sense.dart' show SenseLevel;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Widget _window(Widget page,
        {SenseHomeRole role = SenseHomeRole.both,
        SenseControllerNav nav = SenseControllerNav.computers,
        SenseLevel? about,
        SenseLevel? host}) =>
    RepaintBoundary(
      key: const Key('golden'),
      child: SizedBox(
        width: 1180,
        height: 720,
        child: SenseControllerShellView(
          role: role,
          nav: nav,
          onNav: (_) {},
          signedIn: true,
          name: 'Halil',
          email: 'halil@example.com',
          computerCount: 8,
          version: 4,
          aboutLevel: about,
          thisComputerLevel: host,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
            child: page,
          ),
        ),
      ),
    );

Widget _list({
  List<SenseProject>? projects,
  bool idOpen = false,
  String? moreOpen,
  bool canConnect = true,
  bool grantsMissing = false,
}) =>
    SenseComputersView(
      projects: projects ?? exampleProjects(),
      now: kNow,
      health: exampleHealth(),
      canConnect: canConnect,
      canFileTransfer: canConnect,
      canTerminalTunnel: canConnect,
      canRelay: canConnect,
      grantsMissing: grantsMissing,
      onConnect: (_) {},
      onConnectRelay: (_) {},
      onConnectKind: (_, __) {},
      initialIdOpen: idOpen,
      moreOpenId: moreOpen,
    );

Future<void> _shot(WidgetTester tester, String name, Widget child, {bool overlay = false}) async {
  setWindow(tester, const Size(1180, 720));
  await tester.pumpWidget(app(Align(alignment: Alignment.topLeft, child: child)));
  await tester.pump();
  await tester.pump();
  expect(tester.takeException(), isNull);
  // The "⋯" menu is an overlay entry above the page: the picture is the whole screen.
  await expectLater(
      overlay ? find.byType(MaterialApp) : find.byKey(const Key('golden')), matchesGoldenFile(goldenFile(name)));
}

/// Busy and closed computers, and one that is fine, in one open group.
List<SenseProject> _cards() => [
      SenseProject(id: 'prj_muze', name: 'Örnek Müze', computers: [
        pc('482913207', 'Giriş Salonu PC-2', location: 'Lobi', displays: 3),
        pc('482913210', 'Projeksiyon Mac', location: 'Kubbe', displays: 3, os: 'macOS', busy: 'Mevlüt'),
        pc('482913211', 'Giriş kiosk 2', location: 'Lobi', displays: 1, online: false, lastSeen: kNow - 3 * 86400),
      ]),
    ];

void main() {
  testWidgets('Kimlikle bağlan · Aktarma sunucusu üzerinden bağlan', (tester) async {
    await _shot(tester, 'list_id_relay', _window(_list(idOpen: true)));
  }, skip: goldenSkip('list_id_relay'), tags: const ['golden']);

  testWidgets('⋯ menu open · Aktarmayla bağlan', (tester) async {
    await _shot(tester, 'list_more_menu', _window(_list(moreOpen: '482913207')), overlay: true);
  }, skip: goldenSkip('list_more_menu'), tags: const ['golden']);

  testWidgets('left menu dots · Hakkında sarı, Bu bilgisayar kırmızı', (tester) async {
    await _shot(
        tester, 'list_nav_dots', _window(_list(), about: SenseLevel.warn, host: SenseLevel.hot));
  }, skip: goldenSkip('list_nav_dots'), tags: const ['golden']);

  testWidgets('cards · Meşgul, kapalı, normal', (tester) async {
    await _shot(tester, 'list_cards_busy_off', _window(_list(projects: _cards())));
  }, skip: goldenSkip('list_cards_busy_off'), tags: const ['golden']);

  testWidgets('cards · Yetkin yok, Yetkiler panelden alınamadı', (tester) async {
    await _shot(tester, 'list_no_right',
        _window(_list(projects: _cards(), canConnect: false, grantsMissing: true), role: SenseHomeRole.controller));
  }, skip: goldenSkip('list_no_right'), tags: const ['golden']);
}
