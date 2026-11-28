// Sense Remote (Sürüm 12, OT-b): the bar line with the scale (FO-B2), the Görüntü category
// order (FO-B3), "Yönetici olarak terminal aç" with the red "dikkat" (FO-B4), the ▾ at every
// width (FO-B9), the recording note and folder (#156), and "Sık kullanılanlar" as the fifth
// list of the bar (#160, #167) with its events routed from the session listener.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/caret.dart';
import 'package:flutter_hbb/sense/screens/session/bar/sense_session_bar.dart' show senseBarLineText;
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_list.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_model.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_specs.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/screens/session/record_notice.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'fake_backend.dart';
import 'harness.dart';
import 's9_lists_test.dart' show entriesOf;

Finder _menu(SenseBarMenu m) => find.byKey(ValueKey('sense-bar-menu-${m.name}'));
Finder _list(SenseBarMenu m) => find.byKey(ValueKey('sense-list-${m.name}'));

void main() {
  group('FO-B2 bar line with the scale', () {
    const good = SenseLinkSample(path: SenseLinkPath.direct, fps: 59, rttMs: 19);
    test('"59 fps · 19 ms · %31 ölçekte" (prototype `#sclp`)', () {
      expect(senseBarLineText(good, senseLinkLine(good).text, 31), '59 fps · 19 ms · %31 ölçekte');
    });
    test('Dalgalı keeps the scale too; no scale known → the line as it was', () {
      const wavy = SenseLinkSample(fps: 7, rttMs: 20, wavy: true);
      expect(senseBarLineText(wavy, senseLinkLine(wavy).text, 50), 'Dalgalı · 7 fps · 20 ms · %50 ölçekte');
      expect(senseBarLineText(good, '59 fps · 19 ms', null), '59 fps · 19 ms');
    });
    test('no scale while connecting, without image or reconnecting', () {
      const connecting = SenseLinkSample();
      expect(senseBarLineText(connecting, 'Bağlanıyor…', 31), 'Bağlanıyor…');
      const lost = SenseLinkSample(fps: 0, rttMs: 20, reconnectAttempt: 2);
      final text = senseLinkLine(lost).text;
      expect(senseBarLineText(lost, text, 31), text);
    });
    testWidgets('the bar shows it', (tester) async {
      setWindow(tester, const Size(1600, 900));
      await tester.pumpWidget(frameApp(FakeBackend()));
      final t = tester.widget<Text>(find.byKey(const ValueKey('sense-bar-link-text')));
      expect(t.data, '60 fps · 18 ms · %38 ölçekte');
      await drain(tester);
    });
  });

  test('FO-B3 Görüntü: Kodek · Gelişmiş çizim · Ses', () {
    final s = senseDisplayList(FakeBackend()).sections;
    final titles = s.map((x) => x.title).toList();
    expect(titles.indexOf('Kodek'), lessThan(titles.indexOf('Gelişmiş çizim')));
    expect(titles.indexOf('Gelişmiş çizim'), lessThan(titles.indexOf('Ses')));
  });

  test('FO-B4 "Yönetici olarak terminal aç · Windows" with the red "dikkat"', () {
    final b = FakeBackend(facts: const SensePeerFacts(os: SensePeerOs.windows));
    final e = entriesOf(b)['actions.terminalAdmin']! as SenseActionEntry;
    expect(e.label, 'Yönetici olarak terminal aç');
    expect(e.hint, 'Windows');
    expect(e.tag, 'dikkat');
    expect(e.tagLevel, SenseLevel.hot);
    final plain = entriesOf(b)['actions.terminal']! as SenseActionEntry;
    expect(plain.tag, 'teknik', reason: 'the other rows keep "teknik"');
    expect(plain.tagLevel, isNull);
  });

  testWidgets('FO-B9 the ▾ shows on every list button at 1280 px too', (tester) async {
    for (final size in const [Size(1280, 720), Size(1600, 900)]) {
      setWindow(tester, size);
      await tester.pumpWidget(frameApp(FakeBackend()));
      for (final m in SenseBarMenu.values) {
        expect(find.descendant(of: _menu(m), matching: find.byType(SenseCaret)), findsOneWidget,
            reason: '${m.name} at $size');
      }
      expect(tester.takeException(), isNull);
      await drain(tester);
    }
  });

  group('#156 recordings are on this computer', () {
    test('the note says where: "Bu bilgisayara kaydedildi · Klasörü aç"', () {
      expect(SenseRecordStrings.saved, 'Bu bilgisayara kaydedildi');
    });
    testWidgets('the pill reads the whole sentence', (tester) async {
      await tester.pumpWidget(MaterialApp(home: SenseRecordNoticeBar(onOpen: () {})));
      expect(find.text('Bu bilgisayara kaydedildi · '), findsOneWidget);
      expect(find.text('Klasörü aç'), findsOneWidget);
    });
    test('Eylemler › "Kayıt klasörünü aç" next to the recording switch', () {
      final b = FakeBackend();
      final spec = senseActionsList(b);
      final ids = spec.frequent.map((e) => e.id).toList();
      expect(ids.indexOf('actions.recordFolder'), ids.indexOf('actions.record') + 1);
      final e = spec.frequent.firstWhere((x) => x.id == 'actions.recordFolder') as SenseActionEntry;
      expect(e.label, 'Kayıt klasörünü aç');
      expect(e.hint, 'bu bilgisayarda');
      e.onTap!();
      expect(b.calls, contains('recordFolder'));
    });
    test('not offered where the session cannot record or open the folder', () {
      final noRec = FakeBackend(facts: const SensePeerFacts(hideRecordingButton: true));
      expect(entriesOf(noRec), isNot(contains('actions.recordFolder')));
      final noFolder = FakeBackend()..canOpenRecordFolder = false;
      expect(entriesOf(noFolder), isNot(contains('actions.recordFolder')));
    });
  });

  group('#160 Sık kullanılanlar: the fifth list', () {
    testWidgets('after Eylemler; opens under its button like the others; one at a time', (tester) async {
      setWindow(tester, const Size(1600, 900));
      final popups = FakePopups();
      await tester.pumpWidget(frameApp(FakeBackend(), popups: popups));
      final actions = tester.getTopRight(_menu(SenseBarMenu.actions)).dx;
      final fav = tester.getTopLeft(_menu(SenseBarMenu.favorites)).dx;
      expect(fav, closeTo(actions, 1), reason: 'right after Eylemler');
      expect(find.text('Sık kullanılanlar'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sense-bar-popup-status')));
      await tester.pump();
      await tester.tap(_menu(SenseBarMenu.favorites));
      await tester.pump();
      expect(popups.open, isEmpty, reason: 'the list closes the popups');
      expect(_list(SenseBarMenu.favorites), findsOneWidget);
      expect(find.byType(SenseFavoritesList), findsOneWidget);
      expect(tester.getRect(_list(SenseBarMenu.favorites)).left,
          closeTo(tester.getRect(_menu(SenseBarMenu.favorites)).left, 1));

      await tester.tap(_menu(SenseBarMenu.screens));
      await tester.pump();
      expect(find.byType(SenseFavoritesList), findsNothing);
      expect(_list(SenseBarMenu.screens), findsOneWidget);
      await drain(tester);
    });

    testWidgets('#167 narrow window: a star with the tooltip, not the name', (tester) async {
      setWindow(tester, const Size(1280, 720));
      await tester.pumpWidget(frameApp(FakeBackend()));
      expect(find.byKey(const ValueKey('sense-fav-star')), findsOneWidget);
      expect(find.text('Sık kullanılanlar'), findsNothing);
      await tester.tap(_menu(SenseBarMenu.favorites));
      await tester.pump();
      expect(_list(SenseBarMenu.favorites), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a peer without a list (no Windows / macOS / Linux): no button', (tester) async {
      setWindow(tester, const Size(1600, 900));
      await tester.pumpWidget(frameApp(FakeBackend()..favoritesModel = null));
      expect(_menu(SenseBarMenu.favorites), findsNothing);
      expect(find.text('Eylemler'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('Esc closes it like the other lists', (tester) async {
      setWindow(tester, const Size(1600, 900));
      await tester.pumpWidget(frameApp(FakeBackend()));
      await tester.tap(_menu(SenseBarMenu.favorites));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_list(SenseBarMenu.favorites), findsNothing);
      await drain(tester);
    });

    test('the session listener passes the Host answer on (sense_shortcut_result)', () {
      final got = <(int, bool, String?, Map<String, dynamic>?)>[];
      void sink(int req, bool ok, String? err, Map<String, dynamic>? res) => got.add((req, ok, err, res));
      SenseFavoritesEvents.listen('peer-otb', sink);
      addTearDown(() => SenseFavoritesEvents.forget('peer-otb', sink));
      final used = SenseSessionEvents.handle('peer-otb', {
        'name': 'sense_shortcut_result',
        'req': 3,
        'ok': true,
        'err': null,
        'res': {
          'ping': {'sent': 4, 'received': 4, 'avg_ms': 18, 'loss': 0}
        },
      });
      expect(used, isTrue);
      expect(got.single.$1, 3);
      expect(got.single.$4!['ping']['avg_ms'], 18);
      expect(SenseSessionEvents.handle('peer-otb', {'name': 'sense_prefs_changed'}), isTrue);
      expect(SenseSessionEvents.handle('peer-otb', {'name': 'something_else'}), isFalse);
    });

    test('the fifth list has no spec entries of its own', () {
      final spec = senseBuildList(SenseBarMenu.favorites, FakeBackend());
      expect(spec.sections, isEmpty);
      expect(spec.frequent, isEmpty);
    });
  });
}

