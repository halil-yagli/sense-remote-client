// Sense Remote (Sürüm 12, OT): one in-place question for every list row that asks (#158,
// FO-A10), the custom resolution tried for 15 s and taken back unless kept (FO-A7/B7), the
// "Karşı tarafın sohbet penceresini göster" switch (#151) and the drawing info row (FO-A9).
// Timers run on the widget tester's fake clock (tester.pump(duration)).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/button.dart';
import 'package:flutter_hbb/sense/screens/session/data/frame_rate.dart';
import 'package:flutter_hbb/sense/screens/session/lists/backend.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_model.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_specs.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/screens/session/lists/session_list.dart';
import 'package:flutter_hbb/sense/strings/session.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'fake_backend.dart';
import 'harness.dart';
import 's9_lists_test.dart' show entriesOf;

const _virtual = SensePeerFacts(displaysCount: 3, resolutionsCount: 3, virtualResolution: true, rustDeskIdd: true);

Future<void> _pumpList(WidgetTester tester, SenseListSpec spec, List<String> notes) async {
  setWindow(tester, const Size(800, 900));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: SenseColors.bg,
      body: Align(
        alignment: Alignment.topLeft,
        child: SenseSessionList(spec: spec, onNotify: notes.add, maxHeight: 880),
      ),
    ),
  ));
}

Future<void> _pumpEntry(WidgetTester tester, SenseListEntry entry, List<String> notes) async {
  setWindow(tester, const Size(800, 900));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: SenseColors.bg,
      body: SizedBox(width: kSenseListWidth, child: SenseListEntryView(entry: entry, notify: notes.add)),
    ),
  ));
}

SenseSizeInputEntry _customRes(SenseSessionBackend b) => senseScreensList(b)
    .sections
    .firstWhere((s) => s.id == 'resolution')
    .entries
    .whereType<SenseSizeInputEntry>()
    .single;

const _w = ValueKey('sense-size-screens.customResolution-Genişlik');
const _h = ValueKey('sense-size-screens.customResolution-Yükseklik');
const _try = ValueKey('sense-size-apply-screens.customResolution');
const _box = ValueKey('sense-size-trial-screens.customResolution');

void main() {
  group('#158 / FO-A10: in-place questions of the lists', () {
    test('lock asks (white Kilitle, detail); restart asks with its detail (red)', () {
      final e = entriesOf(FakeBackend());
      final lock = e['actions.lock'] as SenseActionEntry;
      expect(lock.confirmQuestion, 'Uzak ekran kilitlensin mi?');
      expect(lock.confirmDetail, 'Sahadaki kişi ekranı kendi şifresiyle açar.');
      expect(lock.confirmLabel, 'Kilitle');
      expect(lock.confirmPrimary, isTrue);
      final restart = e['actions.restart'] as SenseActionEntry;
      expect(restart.confirmQuestion, 'Uzak bilgisayar yeniden başlatılsın mı?');
      expect(restart.confirmDetail, 'Bağlantı kopar, açılınca yeniden bağlanır.');
      expect(restart.confirmPrimary, isFalse);
    });

    testWidgets('restart row: question + detail in the row, Vazgeç back, red button runs', (tester) async {
      final b = FakeBackend();
      final notes = <String>[];
      await _pumpList(tester, senseActionsList(b), notes);
      await tester.tap(find.text(SenseSessionStrings.restart));
      await tester.pump();
      expect(b.calls, isNot(contains('restart')), reason: 'nothing runs before the second step');
      expect(find.byKey(const ValueKey('sense-asking-actions.restart')), findsOneWidget);
      expect(find.text(SenseSessionStrings.restartConfirmDetail), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'the row grows, nothing overflows');
      // The buttons sit right-aligned inside the 360 px list.
      final ok = tester.getRect(find.byKey(const Key('sense-confirm-ok')));
      expect(ok.right, lessThanOrEqualTo(kSenseListWidth));
      expect(ok.right, greaterThan(kSenseListWidth - 40));
      expect(tester.widget<SenseButton>(find.byKey(const Key('sense-confirm-ok'))).kind, SenseButtonKind.danger);

      await tester.tap(find.byKey(const Key('sense-confirm-cancel')));
      await tester.pump();
      expect(find.byKey(const ValueKey('sense-asking-actions.restart')), findsNothing);
      expect(b.calls, isNot(contains('restart')));

      await tester.tap(find.text(SenseSessionStrings.restart));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-confirm-ok')));
      await tester.pump();
      expect(b.calls, contains('restart'));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('lock row asks first; Kilitle is the white button', (tester) async {
      final b = FakeBackend();
      await _pumpList(tester, senseActionsList(b), []);
      await tester.tap(find.text(SenseSessionStrings.lockScreen));
      await tester.pump();
      expect(b.calls, isNot(contains('lockScreen')));
      expect(find.text(SenseSessionStrings.lockConfirmDetail), findsOneWidget);
      expect(tester.widget<SenseButton>(find.byKey(const Key('sense-confirm-ok'))).kind, SenseButtonKind.primary);
      await tester.tap(find.byKey(const Key('sense-confirm-ok')));
      await tester.pump();
      expect(b.calls, contains('lockScreen'));
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('FO-A7/B7: custom resolution is tried for 15 s', () {
    testWidgets('trial: kept, taken back by hand, taken back when the time runs out', (tester) async {
      final applied = <String>[];
      var current = const SenseResolution(3840, 2160);
      final notes = <String>[];
      final t = SenseResolutionTrial((r) {
        applied.add(r.key);
        current = r;
      }, () => current);
      addTearDown(t.dispose);

      t.start(const SenseResolution(1920, 1080), note: notes.add);
      expect(t.active, isTrue);
      expect(t.secondsLeft, SenseResolutionTrial.seconds);
      await tester.pump(const Duration(seconds: 5));
      expect(t.secondsLeft, 10);
      t.keep();
      expect(t.active, isFalse);
      expect(notes.last, 'Çözünürlük korundu: 1920×1080');
      await tester.pump(const Duration(seconds: 20));
      expect(applied, ['1920x1080'], reason: 'kept: no revert later');

      t.start(const SenseResolution(1280, 720), note: notes.add);
      t.undo();
      expect(applied.last, '1920x1080');
      expect(notes.last, 'Eski çözünürlüğe dönüldü');

      t.start(const SenseResolution(2560, 1440), note: notes.add);
      await tester.pump(const Duration(seconds: 14));
      expect(t.active, isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(t.active, isFalse);
      expect(applied.last, '1920x1080', reason: '15 s without "Koru": the old size is back');
      expect(notes.last, 'Eski çözünürlüğe dönüldü');
    });

    testWidgets('a second try keeps the first size to go back to', (tester) async {
      var current = const SenseResolution(3840, 2160);
      final t = SenseResolutionTrial((r) => current = r, () => current);
      addTearDown(t.dispose);
      t.start(const SenseResolution(1920, 1080));
      t.start(const SenseResolution(1280, 720));
      expect(t.previous, const SenseResolution(3840, 2160));
      await tester.pump(const Duration(seconds: 15));
      expect(current, const SenseResolution(3840, 2160));
    });

    testWidgets('row: Dene → box with seconds; 15 s later the old size is back', (tester) async {
      final b = FakeBackend(facts: _virtual);
      final notes = <String>[];
      final entry = _customRes(b);
      expect(entry.trial, same(b.resolutionTrial));
      await _pumpEntry(tester, entry, notes);
      expect(find.text(SenseSessionStrings.customResolutionTry), findsOneWidget);
      expect(find.byKey(const ValueKey('sense-size-note-screens.customResolution')), findsOneWidget);
      await tester.enterText(find.byKey(_w), '1920');
      await tester.enterText(find.byKey(_h), '1080');
      await tester.tap(find.byKey(_try));
      await tester.pump();
      expect(b.calls, contains('resolution:1920x1080'));
      expect(find.byKey(_box), findsOneWidget);
      expect(find.text('Bu çözünürlük uygun mu? 1920 × 1080'), findsOneWidget);
      expect(find.text('15 sn içinde onaylamazsan eski çözünürlüğe dönülür.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('14 sn içinde onaylamazsan eski çözünürlüğe dönülür.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 14));
      expect(b.calls.last, 'resolution:3840x2160');
      expect(notes.last, SenseSessionStrings.resolutionReverted);
      expect(find.byKey(_box), findsNothing);
    });

    testWidgets('row: Koru keeps the size', (tester) async {
      final b = FakeBackend(facts: _virtual);
      final notes = <String>[];
      await _pumpEntry(tester, _customRes(b), notes);
      await tester.enterText(find.byKey(_w), '2560');
      await tester.enterText(find.byKey(_h), '1440');
      await tester.tap(find.byKey(_try));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sense-size-keep-screens.customResolution')));
      await tester.pump();
      expect(notes.last, 'Çözünürlük korundu: 2560×1440');
      await tester.pump(const Duration(seconds: 20));
      expect(b.calls.where((c) => c.startsWith('resolution:')), ['resolution:2560x1440']);
    });

    testWidgets('the trial lives with the session: it goes on with no list open', (tester) async {
      final b = FakeBackend(facts: _virtual);
      addTearDown(b.dispose);
      b.resolutionTrial.start(const SenseResolution(1920, 1080));
      await tester.pump(const Duration(seconds: 15));
      expect(b.currentResolution, const SenseResolution(3840, 2160));
    });
  });

  group('#151: Karşı tarafın sohbet penceresini göster', () {
    test('Görüntü frequent box: off at the start, sends on / off', () {
      final b = FakeBackend();
      SenseToggleEntry row() =>
          senseDisplayList(b).frequent.whereType<SenseToggleEntry>().singleWhere((e) => e.id == 'display.hostChat');
      expect(row().label, 'Karşı tarafın sohbet penceresini göster');
      expect(row().value, isFalse);
      row().onChanged!(true);
      expect(b.calls, contains('hostChat:true'));
      expect(row().value, isTrue);
    });

    test('not on a camera / file connection', () {
      expect(SenseRules.hostChat(const SensePeerFacts(defaultConn: false)), isFalse);
      expect(entriesOf(FakeBackend(facts: const SensePeerFacts(defaultConn: false))), isNot(contains('display.hostChat')));
    });
  });

  test('FO-A9: drawing settings say they touch only this computer', () {
    final render = senseDisplayList(FakeBackend()).sections.firstWhere((s) => s.id == 'render');
    final info = render.entries.last as SenseInfoEntry;
    expect(info.label, 'Bu ayarlar yalnız bu bilgisayarın çizimini etkiler');
    expect(info.detail, 'uzak bilgisayara dokunmaz');
  });

  // U168c (KQ): the session's frame limit follows the core's rule (src/sense/fps_policy.rs).
  test('U168c: 60 on a direct link with a stock quality, 30 relayed, own rate under Özel kalite', () {
    expect(senseSessionFpsCap(imageQuality: 'balanced', direct: true), 60);
    expect(senseSessionFpsCap(imageQuality: 'best', direct: false), 30);
    expect(senseSessionFpsCap(imageQuality: 'custom', customFps: 45, direct: true), 45);
    expect(senseSessionFpsCap(imageQuality: 'custom', customFps: 200, direct: true), 30, reason: 'outside 5–120');
    expect(senseReachableFps(refreshHz: 60, cap: senseSessionFpsCap(imageQuality: 'balanced', direct: true)), 60);
    expect(senseReachableFps(refreshHz: 50, cap: senseSessionFpsCap(imageQuality: 'balanced', direct: true)), 50);
    expect(senseReachableFps(refreshHz: 144, cap: senseSessionFpsCap(imageQuality: 'balanced', direct: true)), 60);
  });
}
