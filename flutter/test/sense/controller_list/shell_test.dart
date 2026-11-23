// Sense Remote: the Controller window (plan B3; YH C1): left menu by role,
// signed out = only the role chip, the name + "Sürüm N" at the bottom, the
// account box (e-mail, Çıkış yap → in-place second step, outside click closes).
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart' show SenseHomeRole;
import 'package:flutter_hbb/sense/screens/controller/shell/account_box.dart';
import 'package:flutter_hbb/sense/screens/controller/shell/controller_shell.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Future<List<SenseControllerNav>> _pumpShell(
  WidgetTester tester, {
  SenseHomeRole role = SenseHomeRole.controller,
  bool signedIn = true,
  SenseControllerNav nav = SenseControllerNav.computers,
  VoidCallback? onSignOut,
  Future<int> Function()? openConnections,
}) async {
  final navs = <SenseControllerNav>[];
  setWindow(tester, const Size(1180, 720));
  await tester.pumpWidget(app(SenseControllerShellView(
    role: role,
    nav: nav,
    onNav: navs.add,
    signedIn: signedIn,
    name: 'Halil',
    email: 'halil@example.com',
    computerCount: 8,
    version: 4,
    onSignOut: onSignOut,
    openConnections: openConnections,
    child: const Center(child: Text('sayfa')),
  )));
  return navs;
}

void main() {
  testWidgets('Controller: Bilgisayarlar (8), Ayarlar, Hakkında; name and Sürüm 4', (tester) async {
    final navs = await _pumpShell(tester);
    expect(find.text('Controller'), findsOneWidget);
    expect(find.text('Bilgisayarlar'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('Ayarlar'), findsOneWidget);
    expect(find.text('Hakkında'), findsOneWidget);
    expect(find.byKey(const Key('sense-controller-nav-thisComputer')), findsNothing);
    expect(find.text('Halil'), findsOneWidget);
    expect(find.text('Sürüm 4'), findsOneWidget);
    expect(find.text('halil@example.com'), findsNothing, reason: 'e-posta yalnız kutuda');
    await tester.tap(find.text('Ayarlar'));
    await tester.tap(find.byKey(const Key('sense-controller-version')));
    expect(navs, [SenseControllerNav.settings, SenseControllerNav.about]);
  });

  testWidgets('Host + Controller also gets Bu bilgisayar', (tester) async {
    await _pumpShell(tester, role: SenseHomeRole.both);
    expect(find.text('Host + Controller'), findsOneWidget);
    expect(find.byKey(const Key('sense-controller-nav-thisComputer')), findsOneWidget);
  });

  testWidgets('Host + Controller: "Bu bilgisayar" stays on one line next to the badge', (tester) async {
    await _pumpShell(tester, role: SenseHomeRole.both);
    final title = tester.getSize(find.byKey(const Key('sense-controller-rail-title')));
    final oneLine = tester.getSize(find.text('Hakkında')).height;
    expect(title.height, lessThanOrEqualTo(oneLine + 1), reason: 'etiket kırılmamalı');
    expect(find.byKey(const Key('sense-controller-role-chip')), findsOneWidget);
  });

  testWidgets('signed out: only the role chip, no menu, no name', (tester) async {
    await _pumpShell(tester, signedIn: false);
    expect(find.text('Controller'), findsOneWidget);
    expect(find.text('Bilgisayarlar'), findsNothing);
    expect(find.text('Ayarlar'), findsNothing);
    expect(find.text('Halil'), findsNothing);
    expect(find.text('sayfa'), findsOneWidget);
  });

  testWidgets('account box: e-mail, Çıkış yap → second step; Vazgeç; confirm signs out', (tester) async {
    var out = 0;
    await _pumpShell(tester, onSignOut: () => out++, openConnections: () async => 0);
    await tester.tap(find.byKey(const Key('sense-account-name')));
    await tester.pump();
    expect(find.text('halil@example.com'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-account-signout')));
    await tester.pump();
    expect(find.text('Çıkış yapılsın mı? Açık bağlantı yok.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-confirm-cancel')));
    await tester.pump();
    expect(find.text('Çıkış yapılsın mı? Açık bağlantı yok.'), findsNothing);
    expect(find.byKey(const Key('sense-account-signout')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-account-signout')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sense-confirm-ok')));
    await tester.pump();
    expect(out, 1);
    expect(find.byKey(const Key('sense-account-box')), findsNothing);
  });

  testWidgets('open connections change the question', (tester) async {
    await _pumpShell(tester, openConnections: () async => 2);
    await tester.tap(find.byKey(const Key('sense-account-name')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sense-account-signout')));
    await tester.pump();
    expect(find.text('Çıkış yapılsın mı? Açık bağlantı var.'), findsOneWidget);
  });

  testWidgets('a click outside closes the box; the name toggles it', (tester) async {
    await _pumpShell(tester);
    await tester.tap(find.byKey(const Key('sense-account-name')));
    await tester.pump();
    expect(find.byKey(const Key('sense-account-box')), findsOneWidget);
    await tester.tapAt(const Offset(800, 300));
    await tester.pump();
    expect(find.byKey(const Key('sense-account-box')), findsNothing);
    await tester.tap(find.byKey(const Key('sense-account-name')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sense-account-name')));
    await tester.pump();
    expect(find.byKey(const Key('sense-account-box')), findsNothing);
  });

  test('name at the bottom: display name, else the e-mail before @', () {
    expect(senseAccountName('Halil', 'halil@example.com'), 'Halil');
    expect(senseAccountName(' ', 'mevlut@example.com'), 'mevlut');
  });

  testWidgets('account box alone (pure)', (tester) async {
    await tester.pumpWidget(app(SizedBox(
      width: 212,
      child: SenseAccountBox(name: 'Halil', email: 'h@example.com', onSignOut: () {}, initiallyOpen: true),
    )));
    expect(find.text('h@example.com'), findsOneWidget);
  });
}
