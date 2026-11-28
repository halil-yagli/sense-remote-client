// Sense Remote (Sürüm 12): the session note (FO-A4) in its three entry points, the
// "Bağlantıyı sen bitirdin" card (FO-A11), the bar's reconnect line (FO-A12) and the Host's
// idle value when the panel cannot be read (U167). Prototype: `noteHTML`, `endSim`, `netRender`.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/session/data/sense_peer_status.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart' as bar;
import 'package:flutter_hbb/sense/screens/session/layers/data/idle_policy.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_controller.dart';
import 'package:flutter_hbb/sense/screens/session/layers/session_end.dart';
import 'package:flutter_hbb/sense/screens/session/layers/session_layers.dart';
import 'package:flutter_hbb/sense/screens/session/popups/note/note_popup.dart';
import 'package:flutter_hbb/sense/strings/note.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const String _goldenDir = 'test/goldens/session_layers';
String _golden(String name) => '../../goldens/session_layers/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_goldenDir/$name.png').existsSync();

const _facts = SenseNoteFacts(
  computer: 'Giriş Salonu PC-2',
  duration: Duration(minutes: 42),
  messages: 3,
  files: 1,
);

/// A 1280 × 720 connection window: the glow "remote screen" with the one popup place.
Future<SensePopupController> _window(WidgetTester tester, {Widget Function(BuildContext)? child}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final popups = SensePopupController();
  addTearDown(popups.dispose);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: senseTheme(),
    darkTheme: senseTheme(),
    themeMode: kSenseThemeMode,
    builder: (context, w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: w!,
    ),
    home: Scaffold(
      body: RepaintBoundary(
        key: const Key('golden'),
        child: SenseToastHost(
          child: SensePopupHost(
            controller: popups,
            child: Stack(children: [
              const Positioned.fill(child: SenseGlowScene(style: SenseGlowStyle.scene)),
              if (child != null) Positioned.fill(child: Builder(builder: child)),
            ]),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return popups;
}

void _openPopup(SensePopupController popups, SenseNoteMode mode, List<SenseNoteResult> out, {String text = ''}) {
  popups.open(
    SenseNoteStrings.popupId,
    (_) => SenseNotePopup(mode: mode, facts: _facts, initialText: text, animateIn: false, onDone: out.add),
  );
}

void main() {
  group('note popup (FO-A4)', () {
    testWidgets('ending: live line, box, category, chips, hint, three buttons', (tester) async {
      final popups = await _window(tester);
      final out = <SenseNoteResult>[];
      _openPopup(popups, SenseNoteMode.ending, out);
      await tester.pump();
      for (final t in [
        'Oturum notu',
        'Denetim kaydına yazılır',
        'Bitirmeden önce',
        'Not isteğe bağlı',
        'Bilgisayar',
        'Giriş Salonu PC-2',
        'Süre',
        '42 dk',
        'Bu oturumda',
        '3 mesaj · 1 dosya',
        'Ne yaptın?',
        'boş',
        'Bakım',
        'Sürücü güncelleme',
        'Arıza giderme',
        'İçerik yükleme',
        'Kontrol',
        'Not yalnız denetim kaydına yazılır ve Sense ekibine görünür; sahadaki kişi görmez.',
        'Vazgeç',
        'Notsuz bitir',
        'Notu kaydet ve bitir',
      ]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      final save = tester.widget<SenseButton>(find.byKey(const Key('sense-note-save')));
      expect(save.kind, SenseButtonKind.danger, reason: 'prototype `.btn.end`');
    });

    testWidgets('chips add to the note; the summary counts characters; save returns the text', (tester) async {
      final popups = await _window(tester);
      final out = <SenseNoteResult>[];
      _openPopup(popups, SenseNoteMode.ending, out);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-note-chip-Bakım')));
      await tester.tap(find.byKey(const Key('sense-note-chip-Kontrol')));
      await tester.pump();
      expect(find.text('Bakım · Kontrol'), findsOneWidget);
      expect(find.text('15 karakter'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-note-save')));
      expect(out, [const SenseNoteResult(SenseNoteAction.saved, 'Bakım · Kontrol')]);
      expect(out.single.ends, isTrue);
    });

    testWidgets('Notsuz bitir, Vazgeç, × and Esc', (tester) async {
      final popups = await _window(tester);
      final out = <SenseNoteResult>[];
      _openPopup(popups, SenseNoteMode.ending, out, text: 'yazıldı');
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-note-skip')));
      expect(out.last, const SenseNoteResult(SenseNoteAction.skipped));
      _openPopup(popups, SenseNoteMode.mid, out);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-note-cancel')));
      expect(out.last, SenseNoteResult.cancelled);
      expect(out.last.ends, isFalse);
    });

    testWidgets('mid: "Oturum sürüyor · 42 dk", Kapat and Notu kaydet', (tester) async {
      final popups = await _window(tester);
      final out = <SenseNoteResult>[];
      _openPopup(popups, SenseNoteMode.mid, out);
      await tester.pump();
      expect(find.text('Oturum sürüyor · 42 dk'), findsOneWidget);
      expect(find.text('Kapat'), findsOneWidget);
      expect(find.text('Notsuz bitir'), findsNothing);
      expect(tester.widget<SenseButton>(find.byKey(const Key('sense-note-save'))).kind, SenseButtonKind.primary);
      await tester.enterText(find.byKey(const Key('sense-note-field')), '  Sürücü güncellendi  ');
      await tester.tap(find.byKey(const Key('sense-note-save')));
      expect(out.single, const SenseNoteResult(SenseNoteAction.saved, 'Sürücü güncellendi'));
    });

    testWidgets('senseShowSessionNote takes the one popup place; another popup cancels it', (tester) async {
      late BuildContext ctx;
      final popups = await _window(tester, child: (c) {
        ctx = c;
        return const SizedBox.expand();
      });
      final f = senseShowSessionNote(ctx, mode: SenseNoteMode.mid, facts: _facts);
      await tester.pump();
      expect(popups.isOpenWith(SenseNoteStrings.popupId), isTrue);
      popups.open('sense-status', (_) => const SizedBox());
      expect(await f, SenseNoteResult.cancelled);

      final g = senseShowSessionNote(ctx, mode: SenseNoteMode.mid, facts: _facts);
      await tester.pump();
      await tester.enterText(find.byKey(const Key('sense-note-field')), 'Kontrol');
      await tester.tap(find.byKey(const Key('sense-note-save')));
      expect(await g, const SenseNoteResult(SenseNoteAction.saved, 'Kontrol'));
      await tester.pump();
      expect(popups.isOpen, isFalse);
    });

    testWidgets('golden: note popup while ending', (tester) async {
      final popups = await _window(tester);
      _openPopup(popups, SenseNoteMode.ending, []);
      await tester.pump();
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('note_ending')));
    }, skip: _skip('note_ending'), tags: ['golden']);

    testWidgets('golden: note popup in the middle of a session', (tester) async {
      final popups = await _window(tester);
      _openPopup(popups, SenseNoteMode.mid, [], text: 'Bakım · Sürücü güncelleme');
      await tester.pump();
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('note_mid')));
    }, skip: _skip('note_mid'), tags: ['golden']);
  });

  group('the note of a connection', () {
    tearDown(() => SenseSessionNotes.forget('n1'));

    test('an empty note or a window without a sender sends nothing', () {
      expect(SenseSessionNotes.send('n1', 'x'), isFalse);
      final sent = <String>[];
      SenseSessionNotes.setSender('n1', sent.add);
      expect(SenseSessionNotes.canSend('n1'), isTrue);
      expect(SenseSessionNotes.send('n1', '   '), isFalse);
      expect(SenseSessionNotes.status('n1').value, SenseNoteStatus.none);
      expect(SenseSessionNotes.send('n1', ' Bakım '), isTrue);
      expect(sent, ['Bakım']);
      expect(SenseSessionNotes.status('n1').value, SenseNoteStatus.saved);
      expect(SenseSessionNotes.lastText('n1'), 'Bakım');
      SenseSessionNotes.markSkipped('n1');
      expect(SenseSessionNotes.status('n1').value, SenseNoteStatus.saved, reason: 'a saved note stays saved');
      SenseSessionNotes.reset('n1');
      expect(SenseSessionNotes.status('n1').value, SenseNoteStatus.none);
      expect(SenseSessionNotes.lastText('n1'), '');
    });
  });

  group('Bitir and Eylemler › Oturuma not ekle', () {
    late FakeClock clock;
    late FakeHost host;
    late SenseLayerController c;
    final sent = <String>[];

    setUp(() {
      clock = FakeClock();
      host = FakeHost(clock)..healthy();
      c = SenseLayerController(host: host, clock: () => clock.mono, wall: () => clock.wall, autoStart: false);
      SenseLayerController.attach('n2', c);
      sent.clear();
      SenseSessionNotes.setSender('n2', sent.add);
    });

    tearDown(() {
      SenseLayerController.detach('n2', c);
      SenseSessionNotes.forget('n2');
      c.dispose();
    });

    void seconds(int n) {
      for (var i = 0; i < n; i++) {
        clock.advance(const Duration(seconds: 1));
        host.healthy();
        c.tick();
      }
    }

    testWidgets('setting on: Vazgeç keeps the connection', (tester) async {
      late BuildContext ctx;
      await _window(tester, child: (x) {
        ctx = x;
        return const SizedBox.expand();
      });
      final f = senseEndWithNote(ctx, peerId: 'n2', ask: true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-note-cancel')));
      expect(await f, isFalse);
      expect(c.ended, isNull);
      expect(host.calls, isNot(contains('endKeep')));
    });

    testWidgets('setting on: Notu kaydet ve bitir sends the note and ends ("sen bitirdin")', (tester) async {
      seconds(42 * 60);
      late BuildContext ctx;
      await _window(tester, child: (x) {
        ctx = x;
        return const SizedBox.expand();
      });
      final f = senseEndWithNote(ctx, peerId: 'n2', ask: true, computer: 'Giriş Salonu PC-2');
      await tester.pump();
      expect(find.text('42 dk'), findsOneWidget, reason: 'facts from the connection');
      expect(find.text('3 mesaj · 1 dosya'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('sense-note-field')), 'Ekran 2 sürücüsü güncellendi');
      await tester.tap(find.byKey(const Key('sense-note-save')));
      expect(await f, isTrue);
      expect(sent, ['Ekran 2 sürücüsü güncellendi']);
      expect(c.ended!.reason, SenseEndReason.self);
      expect(SenseSessionNotes.status('n2').value, SenseNoteStatus.saved);
      expect(host.calls, contains('endKeep'));
    });

    testWidgets('setting on: Notsuz bitir ends without a note and without "Not ekle" later', (tester) async {
      late BuildContext ctx;
      await _window(tester, child: (x) {
        ctx = x;
        return const SizedBox.expand();
      });
      final f = senseEndWithNote(ctx, peerId: 'n2', ask: true);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-note-skip')));
      expect(await f, isTrue);
      expect(sent, isEmpty);
      expect(c.ended!.reason, SenseEndReason.self);
      expect(SenseSessionNotes.status('n2').value, SenseNoteStatus.skipped);
    });

    testWidgets('setting off: ends at once; the card then offers "Not ekle"', (tester) async {
      late BuildContext ctx;
      await _window(tester, child: (x) {
        ctx = x;
        return const SizedBox.expand();
      });
      expect(await senseEndWithNote(ctx, peerId: 'n2', ask: false), isTrue);
      expect(find.byKey(const Key('sense-note-popup')), findsNothing);
      expect(c.ended!.reason, SenseEndReason.self);
      expect(SenseSessionNotes.status('n2').value, SenseNoteStatus.none);
    });

    testWidgets('mid: the note goes out and the toast says so', (tester) async {
      late BuildContext ctx;
      await _window(tester, child: (x) {
        ctx = x;
        return const SizedBox.expand();
      });
      final f = senseAddNote(ctx, peerId: 'n2');
      await tester.pump();
      await tester.enterText(find.byKey(const Key('sense-note-field')), 'Kontrol');
      await tester.tap(find.byKey(const Key('sense-note-save')));
      await f;
      await tester.pump();
      expect(sent, ['Kontrol']);
      expect(c.ended, isNull);
      expect(find.text('Not kaydedildi · denetim kaydına yazıldı'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the ended card: Not ekle → field, the count waits, Kaydet → "kaydedildi"', (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: senseTheme(),
        builder: (context, w) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: w!,
        ),
        home: Scaffold(body: SenseSessionLayers(id: 'n2', controller: c, listenToInput: false)),
      ));
      seconds(3);
      c.endByUser();
      await tester.pump();
      expect(find.text('Bağlantıyı sen bitirdin'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-ended-add-note')));
      await tester.pump();
      expect(c.holdHome, isTrue);
      expect(find.text('Not yazılırken ana ekrana dönülmez'), findsOneWidget);
      seconds(20);
      await tester.pump();
      expect(host.calls, isNot(contains('home')));
      await tester.enterText(find.byKey(const Key('sense-ended-note-field')), 'Bakım');
      await tester.tap(find.byKey(const Key('sense-ended-note-save')));
      await tester.pump();
      expect(sent, ['Bakım']);
      expect(c.holdHome, isFalse);
      expect(find.text('Oturum notu kaydedildi · denetim kaydına yazıldı'), findsOneWidget);
      expect(find.text('5 sn sonra ana ekrana dönülüyor'), findsOneWidget);
      seconds(5);
      expect(host.calls.last, 'home');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('FO-A12: the line under the computer name while connecting again', () {
    test('red "Kesildi · Yeniden bağlanılıyor (N. deneme)", at least the 1st', () {
      const s = bar.SenseLinkSample(fps: 0, rttMs: 20, reconnectAttempt: 3);
      final line = bar.senseLinkLine(s);
      expect(line.text, 'Kesildi · Yeniden bağlanılıyor (3. deneme)');
      expect(line.level, SenseLevel.hot);
      expect(bar.senseLinkLine(const bar.SenseLinkSample(reconnectAttempt: 0)).text,
          'Kesildi · Yeniden bağlanılıyor (1. deneme)');
      expect(bar.senseLinkLine(const bar.SenseLinkSample(fps: 60, rttMs: 18)).text, '60 fps · 18 ms',
          reason: 'not lost: the usual line');
    });

    test('the controller gives the attempt while the transport is lost', () {
      final clock = FakeClock();
      final host = FakeHost(clock)..healthy();
      final c = SenseLayerController(host: host, clock: () => clock.mono, wall: () => clock.wall, autoStart: false);
      addTearDown(c.dispose);
      for (var i = 0; i < 3; i++) {
        clock.advance(const Duration(seconds: 1));
        host.healthy();
        c.tick();
      }
      expect(c.reconnectInfo, isNull);
      for (var i = 0; i < 14; i++) {
        clock.advance(const Duration(seconds: 1));
        c.tick();
      }
      expect(c.reconnectInfo, isNotNull);
      expect(c.reconnectInfo!.attempt, greaterThanOrEqualTo(1));
    });
  });

  group('U167: the Host value when the panel cannot be read', () {
    late FakeClock clock;
    late SenseLayerController c;

    setUp(() {
      clock = FakeClock();
      c = SenseLayerController(
          host: FakeHost(clock)..healthy(), clock: () => clock.mono, wall: () => clock.wall, autoStart: false);
    });
    tearDown(() => c.dispose());

    test('parsing `session_sense_idle_policy`', () {
      expect(SenseIdlePolicy.parseHost('{"min":30}'), (known: true, min: 30));
      expect(SenseIdlePolicy.parseHost('{"min":null}'), (known: true, min: null));
      expect(SenseIdlePolicy.parseHost('{"error":"unsupported"}').known, isFalse);
      expect(SenseIdlePolicy.parseHost('').known, isFalse);
      expect(SenseIdlePolicy.parseHost('[1]').known, isFalse);
    });

    test('panel down: the Host value right away; the panel still wins when it answers', () async {
      var n = 0;
      final limits = <Duration?>[];
      await SenseIdlePolicy.load('1', c,
          fetch: (_) async => ++n < 3
              ? senseParsePeerStatusResponse(503, '')
              : senseParsePeerStatusResponse(200, '{"online":true,"idle_disconnect_min":10}'),
          wait: (_) async => limits.add(c.idleLimit),
          hostIdle: () => (known: true, min: 30));
      expect(limits.first, const Duration(minutes: 30));
      expect(c.idleLimit, const Duration(minutes: 10));
    });

    test('no panel info: the Host value, asked once', () async {
      var n = 0;
      await SenseIdlePolicy.load('1', c,
          fetch: (_) async {
            n++;
            return senseParsePeerStatusResponse(404, '');
          },
          wait: (_) async {},
          hostIdle: () => (known: true, min: 30));
      expect(n, 1);
      expect(c.idleLimit, const Duration(minutes: 30));
    });

    test('no panel info, the Host value comes a little later', () async {
      var reads = 0;
      await SenseIdlePolicy.load('1', c,
          fetch: (_) async => senseParsePeerStatusResponse(404, ''),
          wait: (_) async {},
          hostIdle: () => ++reads < 3 ? SenseIdlePolicy.unknownHost : (known: true, min: 15));
      expect(c.idleLimit, const Duration(minutes: 15));
    });

    test('an older Host and no panel: never cut', () async {
      await SenseIdlePolicy.load('1', c,
          fetch: (_) async => senseParsePeerStatusResponse(500, ''),
          wait: (_) async {},
          hostIdle: () => SenseIdlePolicy.unknownHost);
      expect(c.idleLimit, isNull);
    });
  });
}
