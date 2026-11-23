// Sense Remote: golden images of the session bar, island and lists, to be compared with
// Calisma/dokuman/img/c01–c05, c10, c13, n10, s09 (plan C1). Window 1440 × 900 like the
// prototype shots (short names at ≤ 1500 px, T9); 1600 × 900 for the full names.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';

import 'fake_backend.dart';
import 'harness.dart';

Future<void> shot(WidgetTester tester, String name, FakeBackend b,
    {Size size = const Size(1440, 900), SenseBarMenu? open, List<String> taps = const []}) async {
  setWindow(tester, size);
  await tester.pumpWidget(frameApp(b));
  if (open != null) {
    await tester.tap(find.byKey(ValueKey('sense-bar-menu-${open.name}')));
    await tester.pump();
    for (final t in taps) {
      await tester.tap(find.text(t).last);
      await tester.pump(const Duration(milliseconds: 400));
    }
  }
  await tester.pump(const Duration(seconds: 3)); // toasts gone
  await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile(name)));
  await drain(tester);
}

void main() {
  testWidgets('c13 bar, ghost mode on', (t) => shot(t, 'bar_ghost_c13', FakeBackend()..ghostOn = true),
      skip: goldenSkip('bar_ghost_c13'), tags: const ['golden']);
  testWidgets('bar, full names (1600 px)',
      (t) => shot(t, 'bar_wide', FakeBackend(), size: const Size(1600, 900)),
      skip: goldenSkip('bar_wide'), tags: const ['golden']);
  testWidgets('bar at 1280 × 720 (T9)',
      (t) => shot(t, 'bar_1280', FakeBackend()..recordingOn = true, size: const Size(1280, 720)),
      skip: goldenSkip('bar_1280'), tags: const ['golden']);
  testWidgets('c10 bar hidden, island at the top', (t) => shot(t, 'island_hidden_c10', FakeBackend()..barHidden = true),
      skip: goldenSkip('island_hidden_c10'), tags: const ['golden']);
  testWidgets('c02 Ekranlar', (t) => shot(t, 'list_screens_c02', FakeBackend(), open: SenseBarMenu.screens),
      skip: goldenSkip('list_screens_c02'), tags: const ['golden']);
  testWidgets('c03 Görüntü, Kodek open',
      (t) => shot(t, 'list_display_c03', FakeBackend(), open: SenseBarMenu.display, taps: ['Kodek']),
      skip: goldenSkip('list_display_c03'), tags: const ['golden']);
  testWidgets('s09 Görüntü, Özel kalite open',
      (t) => shot(t, 'list_display_s09', FakeBackend(), open: SenseBarMenu.display, taps: ['Özel kalite']),
      skip: goldenSkip('list_display_s09'), tags: const ['golden']);
  testWidgets('c04 Klavye ve fare, Fare ve imleç open',
      (t) => shot(t, 'list_keyboard_c04', FakeBackend(facts: const SensePeerFacts(os: SensePeerOs.mac, sasEnabled: false, displaysCount: 3)),
          open: SenseBarMenu.keyboard, taps: ['Fare ve imleç']),
      skip: goldenSkip('list_keyboard_c04'), tags: const ['golden']);
  testWidgets('n10 Klavye ve fare, Kısayollar open',
      (t) => shot(t, 'list_keyboard_n10', FakeBackend(), open: SenseBarMenu.keyboard, taps: ['Kısayollar']),
      skip: goldenSkip('list_keyboard_n10'), tags: const ['golden']);
  testWidgets('c05 Eylemler, recording, Gelişmiş open',
      (t) => shot(t, 'list_actions_c05', FakeBackend()..recordingOn = true, open: SenseBarMenu.actions, taps: ['Gelişmiş']),
      skip: goldenSkip('list_actions_c05'), tags: const ['golden']);
}
