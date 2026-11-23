// Sense Remote: golden images of the Controller window (plan B3), compared by
// eye with Calisma/dokuman/img a05 (sign-in), a01 (list), a02 (LED box),
// a06 (account box), a12 (location filter) and the four states.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/computers_view.dart';
import 'package:flutter_hbb/sense/screens/controller/data/peers.dart';
import 'package:flutter_hbb/sense/screens/controller/login/login_controller.dart';
import 'package:flutter_hbb/sense/screens/controller/login/login_page.dart';
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart' show SenseHomeRole;
import 'package:flutter_hbb/sense/screens/controller/shell/controller_shell.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Widget _window(Widget page,
        {bool signedIn = true, bool accountOpen = false, SenseHomeRole role = SenseHomeRole.controller}) =>
    RepaintBoundary(
      key: const Key('golden'),
      child: SizedBox(
        width: 1180,
        height: 720,
        child: SenseControllerShellView(
          role: role,
          nav: SenseControllerNav.computers,
          onNav: (_) {},
          signedIn: signedIn,
          name: 'Halil',
          email: 'halil@example.com',
          computerCount: 8,
          version: 4,
          accountOpen: accountOpen,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
            child: page,
          ),
        ),
      ),
    );

Widget _list({
  List<SenseProject>? projects,
  SenseListState state = SenseListState.ready,
  String? location,
  String? ledOpen,
  bool idOpen = false,
  String query = '',
}) =>
    SenseComputersView(
      projects: projects ?? exampleProjects(),
      state: state,
      now: kNow,
      health: exampleHealth(),
      onConnect: (_) {},
      initialLocation: location,
      ledOpenId: ledOpen,
      initialIdOpen: idOpen,
      initialQuery: query,
    );

Future<void> _shot(WidgetTester tester, String name, Widget child) async {
  setWindow(tester, const Size(1180, 720));
  await tester.pumpWidget(app(Align(alignment: Alignment.topLeft, child: child)));
  await tester.pump();
  await tester.pump();
  expect(tester.takeException(), isNull);
  await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile(name)));
}

void main() {
  testWidgets('a05: Sense hesabınla gir', (tester) async {
    final c = SenseLoginController(FakeLogin());
    await _shot(tester, 'login_a05', _window(SenseLoginPage(controller: c, onConnect: (_) {}), signedIn: false));
    c.dispose();
  }, skip: goldenSkip('login_a05'), tags: const ['golden']);

  testWidgets('a01: Bilgisayarlar', (tester) async {
    await _shot(tester, 'list_a01', _window(_list()));
  }, skip: goldenSkip('list_a01'), tags: const ['golden']);

  testWidgets('a02: LED box of a red computer', (tester) async {
    await _shot(tester, 'list_a02_led', _window(_list(ledOpen: '482913207')));
  }, skip: goldenSkip('list_a02_led'), tags: const ['golden']);

  testWidgets('a06: account box open', (tester) async {
    await _shot(tester, 'list_a06_account', _window(_list(), accountOpen: true));
  }, skip: goldenSkip('list_a06_account'), tags: const ['golden']);

  testWidgets('a12: location filter Lobi', (tester) async {
    await _shot(tester, 'list_a12_location', _window(_list(location: 'Lobi')));
  }, skip: goldenSkip('list_a12_location'), tags: const ['golden']);

  testWidgets('Host + Controller menu, Kimlikle bağlan open', (tester) async {
    await _shot(tester, 'list_both_id', _window(_list(idOpen: true), role: SenseHomeRole.both));
  }, skip: goldenSkip('list_both_id'), tags: const ['golden']);

  testWidgets('states: loading, error, empty, no result', (tester) async {
    setWindow(tester, const Size(1180, 900));
    await tester.pumpWidget(app(Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: const Key('golden'),
        child: SizedBox(
          width: 960,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final w in [
              _list(projects: const [], state: SenseListState.loading),
              _list(projects: const [], state: SenseListState.error),
              _list(projects: const []),
              _list(query: 'zzz'),
            ])
              Padding(padding: const EdgeInsets.all(12), child: w),
          ]),
        ),
      ),
    )));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('list_states')));
  }, skip: goldenSkip('list_states'), tags: const ['golden']);
}
