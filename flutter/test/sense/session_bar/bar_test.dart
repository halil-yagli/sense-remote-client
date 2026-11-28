// Sense Remote: the session bar, island and lists in use (YH O1, O2, O7, T9; plan C1).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/island/sense_island.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'fake_backend.dart';
import 'harness.dart';

Finder menu(SenseBarMenu m) => find.byKey(ValueKey('sense-bar-menu-${m.name}'));
Finder list(SenseBarMenu m) => find.byKey(ValueKey('sense-list-${m.name}'));

void main() {
  testWidgets('wide window: full names; the bar is 46 px and above the screen', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final b = FakeBackend();
    await tester.pumpWidget(frameApp(b));
    for (final t in ['Ekranlar', 'Görüntü', 'Klavye ve fare', 'Eylemler', 'Bilgisayar durumu', 'Ekran bilgisi', 'Hayalet mod', 'Tam ekran', 'Bitir']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Giriş Salonu PC-2'), findsOneWidget);
    // Sürüm 12 (FO-B2): the image scale is on the line.
    expect(find.text('60 fps · 18 ms · %38 ölçekte'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('sense-session-bar'))).height, SenseSizes.sessionToolbarHeight);
    // O1 acceptance: the bar does not cover the remote screen.
    expect(tester.getTopLeft(find.byKey(const ValueKey('fake-remote'))).dy, SenseSizes.sessionToolbarHeight);
    await drain(tester);
  });

  testWidgets('T9: at 1366 and 1280 px the short names, nothing overflows', (tester) async {
    for (final size in const [Size(1366, 768), Size(1280, 720)]) {
      setWindow(tester, size);
      final b = FakeBackend()..recordingOn = true..viewOnly = true;
      await tester.pumpWidget(frameApp(b));
      for (final t in ['Klavye', 'Durum', 'Ekran', 'Hayalet', 'Tam']) {
        expect(find.text(t), findsOneWidget, reason: '$t at $size');
      }
      for (final m in SenseBarMenu.values) {
        await tester.tap(menu(m));
        await tester.pump();
        expect(list(m), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await drain(tester);
    }
  });

  testWidgets('the two middle groups sit around the centre (island in the middle)', (tester) async {
    setWindow(tester, const Size(1600, 900));
    await tester.pumpWidget(frameApp(FakeBackend()));
    // Sürüm 12 (#160): "Sık kullanılanlar" is the last list, next to the centre.
    final actionsRight = tester.getTopRight(menu(SenseBarMenu.favorites)).dx;
    final statusLeft = tester.getTopLeft(find.byKey(const ValueKey('sense-bar-popup-status'))).dx;
    expect((800 - actionsRight - (statusLeft - 800)).abs(), lessThan(1));
    final island = tester.getCenter(find.byType(SenseIsland));
    expect(island.dx, closeTo(800, 1));
    await drain(tester);
  });

  testWidgets('a list opens under its button, stays open on a choice, closes on an outside tap', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final b = FakeBackend();
    await tester.pumpWidget(frameApp(b));
    await tester.tap(menu(SenseBarMenu.display));
    await tester.pump();
    expect(list(SenseBarMenu.display), findsOneWidget);
    expect(b.calls, contains('refresh'));
    final button = tester.getRect(menu(SenseBarMenu.display));
    final panel = tester.getRect(list(SenseBarMenu.display));
    expect(panel.left, closeTo(button.left, 1));
    expect(panel.width, closeTo(360, 0.01));
    expect(find.text('SIK KULLANILAN'), findsOneWidget);

    await tester.tap(find.text('1:1'));
    await tester.pump();
    expect(b.viewStyle, SenseRd.viewOriginal);
    expect(list(SenseBarMenu.display), findsOneWidget, reason: 'stays open after a choice');
    expect(find.byKey(const Key('sense-toast')), findsOneWidget);

    await tester.tapAt(const Offset(1500, 800));
    await tester.pump();
    expect(list(SenseBarMenu.display), findsNothing);
    await drain(tester);
  });

  testWidgets('one popup at a time: a list closes the popups and the other way round', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final popups = FakePopups();
    await tester.pumpWidget(frameApp(FakeBackend(), popups: popups));
    await tester.tap(find.byKey(const ValueKey('sense-bar-popup-status')));
    await tester.pump();
    expect(popups.isOpen(SenseBarPopup.status), isTrue);
    await tester.tap(menu(SenseBarMenu.screens));
    await tester.pump();
    expect(popups.open, isEmpty);
    expect(list(SenseBarMenu.screens), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sense-bar-popup-info')));
    await tester.pump();
    expect(list(SenseBarMenu.screens), findsNothing);
    expect(popups.isOpen(SenseBarPopup.info), isTrue);

    // The chat (or any other popup) taking the place closes the list.
    await tester.tap(menu(SenseBarMenu.actions));
    await tester.pump();
    expect(popups.menuEvents.last, isTrue);
    popups.kick();
    await tester.pump();
    expect(list(SenseBarMenu.actions), findsNothing);
    expect(popups.menuEvents.last, isFalse);
    await drain(tester);
  });

  testWidgets('one category open at a time; closed ones show their value', (tester) async {
    setWindow(tester, const Size(1600, 900));
    await tester.pumpWidget(frameApp(FakeBackend()));
    await tester.tap(menu(SenseBarMenu.display));
    await tester.pump();
    expect(find.text('Otomatik'), findsOneWidget); // Kodek summary
    await tester.tap(find.text('Kodek'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('sense-radio-display.codec-av1')), findsOneWidget);
    await tester.tap(find.text('Ses'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('sense-radio-display.codec-av1')), findsNothing);
    expect(find.text('Uzak bilgisayarın sesini kapat'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('restart asks in place first (T7), no window', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final b = FakeBackend();
    await tester.pumpWidget(frameApp(b));
    await tester.tap(menu(SenseBarMenu.actions));
    await tester.pump();
    await tester.tap(find.text('Uzak bilgisayarı yeniden başlat…'));
    await tester.pump();
    expect(find.text('Uzak bilgisayar yeniden başlatılsın mı?'), findsOneWidget);
    expect(b.calls, isNot(contains('restart')));
    expect(find.byType(Dialog), findsNothing);
    await tester.tap(find.text('Yeniden başlat'));
    await tester.pump();
    expect(b.calls, contains('restart'));
    await drain(tester);
  });

  testWidgets('ghost mode: one tap on, one tap off, no window (O1, S9-b)', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final b = FakeBackend();
    await tester.pumpWidget(frameApp(b));
    await tester.tap(find.byKey(const ValueKey('sense-bar-ghost')));
    await tester.pump();
    expect(b.ghostOn, isTrue);
    expect(find.text('Hayalet mod açık'), findsOneWidget);
    expect(find.byKey(const ValueKey('sense-ghost-line')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('sense-ghost-line'))).height, 3);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sense-bar-ghost')));
    await tester.pump();
    expect(b.ghostOn, isFalse);
    expect(find.byKey(const ValueKey('sense-ghost-line')), findsNothing);
    await drain(tester);
  });

  testWidgets('ghost mode that needs display 1, and core notes, show a short note in place', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final b = FakeBackend()..ghostNeedsDisplay1 = true;
    await tester.pumpWidget(frameApp(b));
    await tester.tap(find.byKey(const ValueKey('sense-bar-ghost')));
    await tester.pump();
    expect(b.ghostOn, isFalse);
    expect(find.text('Hayalet mod için önce Ekran 1’e geç'), findsOneWidget);
    b.sendGhostNote('denied');
    await tester.pump();
    expect(find.text('Hayalet mod reddedildi'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    await drain(tester);
    expect(find.byKey(const ValueKey('sense-bar-ghost-note')), findsNothing);
  });

  testWidgets('Bitir ends at once (no note window); Tam ekran toggles', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final b = FakeBackend();
    await tester.pumpWidget(frameApp(b));
    await tester.tap(find.byKey(const ValueKey('sense-bar-fullscreen')));
    await tester.pump();
    expect(b.fullscreen, isTrue);
    await tester.tap(find.byKey(const ValueKey('sense-bar-end')));
    await tester.pump();
    expect(b.calls, contains('end'));
    expect(find.byType(Dialog), findsNothing);
    await drain(tester);
  });

  testWidgets('status tags: recording red + dot, view only / input lock orange', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final b = FakeBackend()..recordingOn = true..viewOnly = true;
    await tester.pumpWidget(frameApp(b));
    expect(find.byKey(const ValueKey('sense-bar-rec-dot')), findsOneWidget);
    expect(find.byKey(const ValueKey('sense-bar-tag-recording')), findsOneWidget);
    expect(find.text('Yalnız izle'), findsOneWidget);
    b.set(() => b.inputLocked = true);
    await tester.pump();
    expect(find.text('Giriş kilitli'), findsOneWidget);
    await drain(tester);
  });

  // Sürüm 10 (#110): the logo / connection area opens the connection card, never Ekran
  // bilgisi; open popups close first (one popup at a time).
  testWidgets('connection line colours; the area opens the connection card', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final popups = FakePopups();
    var cards = 0;
    final b = FakeBackend(link: SenseLinkSample(fps: 60, rttMs: 200, onRestoreLayer: () => cards++));
    await tester.pumpWidget(frameApp(b, popups: popups));
    final text = tester.widget<Text>(find.byKey(const ValueKey('sense-bar-link-text')));
    expect(text.data, startsWith('Dalgalı'));
    expect(text.style?.color, SenseColors.warn);
    await tester.tap(find.byKey(const ValueKey('sense-bar-popup-status')));
    await tester.pump();
    expect(popups.isOpen(SenseBarPopup.status), isTrue);
    await tester.tap(find.byKey(const ValueKey('sense-bar-link')));
    await tester.pump();
    expect(cards, 1);
    expect(popups.open, isEmpty, reason: 'the card takes the one popup place');
    expect(popups.isOpen(SenseBarPopup.info), isFalse, reason: 'Ekran bilgisi only from its own button');
    // An open list closes too.
    await tester.tap(menu(SenseBarMenu.screens));
    await tester.pump();
    expect(list(SenseBarMenu.screens), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sense-bar-link')));
    await tester.pump();
    expect(cards, 2);
    expect(list(SenseBarMenu.screens), findsNothing);
    await drain(tester);
  });

  testWidgets('without a connection layer the area does nothing (no Ekran bilgisi)', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final popups = FakePopups();
    await tester.pumpWidget(frameApp(FakeBackend(), popups: popups));
    await tester.tap(find.byKey(const ValueKey('sense-bar-link')));
    await tester.pump();
    expect(popups.open, isEmpty);
    await drain(tester);
  });

  testWidgets('island: 52×20 at rest, 116×28 on hover, flips without turning, hides the bar', (tester) async {
    setWindow(tester, const Size(1600, 900));
    final b = FakeBackend();
    await tester.pumpWidget(frameApp(b));
    final body = find.byKey(const ValueKey('sense-island-body'));
    expect(tester.getSize(body), const Size(SenseSizes.islandWidth, SenseSizes.islandHeight));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(body));
    await tester.pump();
    await tester.pump(SenseMotion.islandExpand.duration);
    expect(tester.getSize(body), const Size(SenseSizes.islandWidthHover, SenseSizes.islandHeightHover));
    expect(find.text('Gizle'), findsOneWidget);
    // Flipped: scaleY −1, never a rotation (T4, O2 acceptance).
    final flip = tester.widget<Transform>(find.descendant(
        of: find.byKey(const ValueKey('sense-island-flip')), matching: find.byType(Transform)).first);
    expect(flip.transform.entry(1, 1), closeTo(-1, 1e-6));
    expect(flip.transform.entry(0, 1).abs() + flip.transform.entry(1, 0).abs(), 0);
    expect(find.descendant(of: find.byType(SenseIsland), matching: find.byType(RotationTransition)), findsNothing);

    await tester.tap(body);
    await tester.pump();
    await tester.pump(SenseMotion.toolbarHide.duration);
    expect(b.barHidden, isTrue);
    expect(tester.getSize(find.byKey(const ValueKey('sense-bar-slot'))).height, 0);
    expect(find.text('Göster'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(SenseIsland)).dy, 0);
    await drain(tester);
  });
}
