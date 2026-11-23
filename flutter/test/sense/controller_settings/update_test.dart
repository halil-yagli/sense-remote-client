// Sense Remote: update strip, About update box and the macOS second step
// (update plan 2026-11-21, section 6; YH C4). Pure texts for every GuiStatus
// state, the install button and its answers, the in-place macOS step, goldens.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/components/sense_version_chip.dart';
import 'package:flutter_hbb/sense/screens/controller/update/sense_update_model.dart';
import 'package:flutter_hbb/sense/screens/controller/update/sense_update_view.dart';
import 'package:flutter_hbb/sense/strings/update.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

SenseUpdateStatus _s(Map<String, Object?> json) =>
    SenseUpdateStatus.parse(jsonEncode({'current': 3, 'supported': true, ...json}));

String? _text(Map<String, Object?> json,
        [SenseUpdateUiState ui = const SenseUpdateUiState()]) =>
    senseUpdateStrip(_s(json), ui)?.text;

List<SenseUpdateAction> _actions(Map<String, Object?> json,
        [SenseUpdateUiState ui = const SenseUpdateUiState()]) =>
    senseUpdateStrip(_s(json), ui)?.actions ?? const [];

const _notes = 'https://remote.example/#surum-4';

const _available = {
  'state': 'available',
  'target': 4,
  'notes_url': _notes,
  'checked_at': 1000,
};

class _FakeBackend extends SenseUpdateBackend {
  _FakeBackend(this.json, {this.answer = '', this.cancellable = false});
  final bool cancellable;
  int cancels = 0;

  @override
  bool get canCancel => cancellable;

  @override
  Future<void> cancel() async {
    cancels++;
    json = {..._available};
  }

  Map<String, Object?> json;
  String answer;
  String seen = '';
  final installs = <int>[];
  final opened = <String>[];

  @override
  Future<String> status() async =>
      jsonEncode({'current': 3, 'supported': true, ...json});

  @override
  Future<String> install(int version) async {
    installs.add(version);
    return answer;
  }

  @override
  String seenInstalled() => seen;

  @override
  Future<void> setSeenInstalled(String key) async => seen = key;

  @override
  void openUrl(String url) => opened.add(url);
}

Widget _watch(_FakeBackend backend) => SenseUpdateWatch(
      backend: backend,
      interval: const Duration(hours: 1),
      showSplash: false,
      builder: (_, strip) => SizedBox(
          width: 760, child: strip ?? const Text('no strip', key: Key('none'))),
    );

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(1000, 700)}) async {
  await pumpSense(tester, child, size: size, center: false);
  await tester.pumpAndSettle();
}

void main() {
  group('GuiStatus parsing', () {
    test('unreadable status is nothing, never "hazır"', () {
      for (final raw in ['', 'null', '[]', '{', '{"state":42}']) {
        final s = SenseUpdateStatus.parse(raw);
        expect(s.state,
            raw == '{"state":42}' ? SenseUpdateState.unknown : SenseUpdateState.idle);
        expect(senseUpdateStrip(s), isNull, reason: raw);
        expect(senseAboutUpdateText(s, 0), isNull, reason: raw);
      }
    });

    test('notes link only for http(s) with a host', () {
      expect(_s({'notes_url': 'javascript:alert(1)'}).notesUrl, isNull);
      expect(_s({'notes_url': 'file:///etc/passwd'}).notesUrl, isNull);
      expect(_s({'notes_url': _notes}).notesUrl, _notes);
    });

    test('progress is clamped', () {
      expect(_s({'progress_pct': 140}).progressPct, 100);
    });
  });

  group('strip text and buttons, every state (§6)', () {
    test('GuiStatus supported false or missing: strip only informs', () {
      for (final extra in [
        {'supported': false},
        <String, Object?>{},
      ]) {
        final s = SenseUpdateStatus.parse(
            jsonEncode({'current': 3, ..._available, ...extra}));
        expect(s.supported, isFalse);
        expect(senseUpdateStrip(s)!.text, 'Yeni sürüm hazır: Sürüm 4');
        expect(senseUpdateStrip(s)!.actions, [SenseUpdateAction.notes]);
        final failed = SenseUpdateStatus.parse(jsonEncode(
            {'current': 3, 'state': 'failed', 'target': 4, ...extra}));
        expect(senseUpdateStrip(failed)!.actions, isEmpty);
      }
      expect(_s(_available).supported, isTrue);
    });

    test('available: Güncelle and Neler yeni', () {
      expect(_text(_available), 'Yeni sürüm hazır: Sürüm 4');
      expect(_actions(_available),
          [SenseUpdateAction.update, SenseUpdateAction.notes]);
      expect(_actions({...(_available), 'notes_url': null}),
          [SenseUpdateAction.update]);
    });

    test('"hazır" only for a newer target (hint alone never shows it)', () {
      expect(_text({'state': 'available', 'target': 3}), isNull);
      expect(_text({'state': 'available'}), isNull);
      expect(_text({'state': 'idle', 'target': 4}), isNull);
      expect(senseAboutUpdateText(_s({'state': 'idle', 'target': 4}), 0), isNull);
    });

    test('blocked=session_active after Güncelle', () {
      const ui = SenseUpdateUiState(requested: true);
      final json = {...(_available), 'blocked': 'session_active'};
      expect(_text(json, ui),
          'Bağlantı sürüyor; Sürüm 4 bağlantı bitince kurulacak.');
      expect(_actions(json, ui), isEmpty);
      // Before pressing, the offer stays.
      expect(_text(json), 'Yeni sürüm hazır: Sürüm 4');
      // Local request waiting for the connection to end.
      expect(
          _text({
            'state': 'waiting_idle',
            'target': 4,
            'source': 'local',
            'blocked': 'session_active'
          }),
          'Bağlantı sürüyor; Sürüm 4 bağlantı bitince kurulacak.');
    });

    test('scheduled by the panel', () {
      expect(_text({'state': 'scheduled', 'target': 4, 'source': 'panel'}),
          "Sense ekibi bu bilgisayarı Sürüm 4'e güncelliyor. Bağlantı yokken kendiliğinden kurulur.");
      expect(
          _text({
            'state': 'waiting_idle',
            'target': 6,
            'source': 'panel',
            'blocked': 'session_active'
          }),
          "Sense ekibi bu bilgisayarı Sürüm 6'ya güncelliyor. Bağlantı yokken kendiliğinden kurulur.");
      expect(_actions({'state': 'scheduled', 'target': 4, 'source': 'panel'}),
          isEmpty);
    });

    test('scheduled for the night: Şimdi güncelle', () {
      final json = {
        'state': 'scheduled',
        'target': 4,
        'source': 'panel',
        'blocked': 'night_window'
      };
      expect(_text(json), 'Sürüm 4 bu gece 03:00–05:00 arasında kurulacak.');
      expect(_actions(json), [SenseUpdateAction.updateNow]);
    });

    test('downloading, verifying, installing', () {
      expect(
          _text({'state': 'downloading', 'target': 4, 'progress_pct': 42}),
          'Sürüm 4 indiriliyor · %42');
      expect(_text({'state': 'downloading', 'target': 4}),
          'Sürüm 4 indiriliyor…');
      expect(_text({'state': 'verifying', 'target': 4}),
          'Sürüm 4 doğrulanıyor (imza + SHA-256)…');
      expect(_text({'state': 'installing', 'target': 4}),
          'Sürüm 4 kuruluyor. Sense Remote birkaç saniye kapanıp açılacak.');
      for (final st in ['downloading', 'verifying', 'installing']) {
        expect(_actions({'state': st, 'target': 4}), isEmpty);
        expect(senseUpdateStrip(_s({'state': st, 'target': 4}))!.busy, isTrue);
      }
    });

    test('installed: shown once, Kapat', () {
      final json = {
        'current': 4,
        'state': 'idle',
        'last_result': {'state': 'installed', 'from': 3, 'to': 4, 'at': 77}
      };
      expect(_text(json), 'Güncellendi: Sürüm 4');
      expect(_actions(json), [SenseUpdateAction.close]);
      expect(senseInstalledNoticeKey(_s(json)), '4:77');
      expect(_text(json, const SenseUpdateUiState(seenInstalled: '4:77')),
          isNull);
      // A result for another version is not "updated to this one".
      expect(
          _text({
            'current': 3,
            'last_result': {'state': 'installed', 'from': 2, 'to': 4, 'at': 1}
          }),
          isNull);
      expect(_text({'current': 4, 'state': 'installed'}),
          'Güncellendi: Sürüm 4');
    });

    test('failed: reason in Turkish, no internal detail, Tekrar dene', () {
      final json = {
        'state': 'failed',
        'target': 4,
        'error': 'hash_mismatch',
        'error_detail': 'sha256_differs'
      };
      expect(_text(json),
          'Güncelleme yapılamadı: indirilen dosya doğrulanamadı. Sürüm 3 ile çalışmaya devam ediliyor.');
      expect(_text(json), isNot(contains('sha256')));
      expect(_actions(json), [SenseUpdateAction.retry]);
      expect(_text({'state': 'failed', 'error': 'something_new'}),
          contains('bilinmeyen bir sorun'));
      expect(_actions({'state': 'failed'}), isEmpty);
    });

    test('rolled back', () {
      final json = {
        'state': 'rolled_back',
        'target': 4,
        'error': 'health_timeout'
      };
      expect(_text(json), "Sürüm 4 kurulamadı; Sürüm 3'e geri dönüldü.");
      expect(_actions(json), [SenseUpdateAction.retry]);
      expect(senseUpdateRequestVersion(_s(json)), 4);
    });

    test('every error name has its own Turkish reason', () {
      const errors = [
        'manifest_invalid', 'order_invalid', 'downgrade', 'download_failed',
        'size_mismatch', 'hash_mismatch', 'disk_space', 'install_failed',
        'version_mismatch', 'health_timeout', 'identity_changed',
        'rolled_back', 'rollback_failed', 'busy', 'unsupported',
      ];
      for (final e in errors) {
        expect(kSenseUpdateTr.containsKey('err_$e'), isTrue, reason: e);
        expect(senseUpdateReason(e), isNot(senseUpdateText('err_unknown')));
      }
    });

    test('not supported here: the strip only informs', () {
      const ui = SenseUpdateUiState(supported: false);
      expect(_text(_available, ui), 'Yeni sürüm hazır: Sürüm 4');
      expect(_actions(_available, ui), [SenseUpdateAction.notes]);
      expect(
          _actions({
            'state': 'scheduled',
            'target': 4,
            'blocked': 'night_window'
          }, ui),
          isEmpty);
      expect(_actions({'state': 'failed', 'target': 4}, ui), isEmpty);
      expect(_actions({'state': 'rolled_back', 'target': 4}, ui), isEmpty);
    });

    test('nothing to say when idle', () {
      expect(_text({'state': 'idle', 'checked_at': 5}), isNull);
    });
  });

  group('texts', () {
    test('Turkish dative after the version number', () {
      const cases = {
        1: "'e", 2: "'ye", 3: "'e", 4: "'e", 5: "'e", 6: "'ya", 7: "'ye",
        8: "'e", 9: "'a", 10: "'a", 20: "'ye", 30: "'a", 40: "'a", 50: "'ye",
        60: "'a", 70: "'e", 80: "'e", 90: "'a", 100: "'e", 1000: "'e",
        12: "'ye", 26: "'ya", 109: "'a",
      };
      cases.forEach((n, s) => expect(senseTurkishDative(n), s, reason: '$n'));
    });

    test('install answers (§3.7)', () {
      expect(senseInstallAnswerText(''), isNull);
      expect(senseInstallAnswerText('not_newer'), 'Bu bilgisayar zaten güncel.');
      expect(senseInstallAnswerText('busy'), 'Güncelleme zaten sürüyor.');
      expect(senseInstallAnswerText('no_release'), contains('bulunamadı'));
      expect(senseInstallAnswerText('ipc_failed'), contains('servisine'));
      expect(senseInstallAnswerText('unsupported'), contains('Sense ekibi'));
      expect(senseInstallAnswerText('weird'), 'Güncelleme başlatılamadı.');
    });

    test('About line: Güncel or Sürüm N hazır, and the last check', () {
      expect(senseAboutUpdateText(_s({'state': 'idle', 'checked_at': 1000}), 1130),
          'Güncel · Son denetim: 2 dk önce');
      expect(senseAboutUpdateText(_s(_available), 1010),
          'Sürüm 4 hazır · Son denetim: az önce');
      expect(senseAboutUpdateText(_s({'state': 'idle'}), 1000), isNull);
      // Busy: no "Güncel" claim, only the check time.
      expect(
          senseAboutUpdateText(
              _s({'state': 'downloading', 'target': 4, 'checked_at': 0}), 7200),
          'Son denetim: 2 sa önce');
      expect(senseAgoText(0, 3 * 86400), '3 gün önce');
    });

    test('Turkish only (YH T2): no English table any more', () {
      expect(File('lib/sense/strings/update.dart').readAsStringSync(), isNot(contains('kSenseUpdateEn')));
    });

    test('no upstream product name in the update screens', () {
      const files = [
        'lib/sense/screens/controller/update/sense_update_model.dart',
        'lib/sense/screens/controller/update/sense_update_view.dart',
        'lib/sense/strings/update.dart',
        'lib/sense/components/sense_version_chip.dart',
      ];
      final banned = RegExp('rust' 'desk', caseSensitive: false);
      for (final path in files) {
        expect(banned.hasMatch(File(path).readAsStringSync()), isFalse,
            reason: path);
      }
      for (final t in kSenseUpdateTr.values) {
        expect(banned.hasMatch(t), isFalse, reason: t);
      }
    });
  });

  group('strip binding', () {
    testWidgets('Güncelle asks for the target; connection active text',
        (tester) async {
      final b = _FakeBackend({..._available});
      await _pump(tester, _watch(b));
      expect(find.text('Yeni sürüm hazır: Sürüm 4'), findsOneWidget);
      b.json = {..._available, 'blocked': 'session_active'};
      await tester.tap(find.byKey(const Key('sense-update-update')));
      await tester.pumpAndSettle();
      expect(b.installs, [4]);
      expect(find.text(senseUpdateText('session_active', {'n': '4'})), findsOneWidget);
      expect(find.byKey(const Key('sense-update-update')), findsNothing);
    });

    testWidgets('refused answers are said; unsupported leaves only info',
        (tester) async {
      final b = _FakeBackend({..._available}, answer: 'busy');
      await _pump(tester, _watch(b));
      await tester.tap(find.byKey(const Key('sense-update-update')));
      await tester.pumpAndSettle();
      expect(find.text('Güncelleme zaten sürüyor.'), findsOneWidget);

      b.answer = 'unsupported';
      // A new state clears the answer; the button comes back.
      b.json = {'state': 'failed', 'target': 4, 'error': 'busy'};
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, _watch(b));
      await tester.tap(find.byKey(const Key('sense-update-retry')));
      await tester.pumpAndSettle();
      expect(b.installs, [4, 4]);
      expect(find.text(senseUpdateText('install_unsupported')), findsOneWidget);
      // Next status: information only, no button any more.
      b.json = {..._available};
      await tester.pump(const Duration(hours: 1));
      await tester.pumpAndSettle();
      expect(find.text('Yeni sürüm hazır: Sürüm 4'), findsOneWidget);
      expect(find.byKey(const Key('sense-update-update')), findsNothing);
      expect(find.byKey(const Key('sense-update-notes')), findsOneWidget);
    });

    testWidgets('Neler yeni opens the notes; Kapat is remembered',
        (tester) async {
      final b = _FakeBackend({..._available});
      await _pump(tester, _watch(b));
      await tester.tap(find.byKey(const Key('sense-update-notes')));
      expect(b.opened, [_notes]);

      b.json = {
        'current': 4,
        'last_result': {'state': 'installed', 'from': 3, 'to': 4, 'at': 9}
      };
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, _watch(b));
      expect(find.text('Güncellendi: Sürüm 4'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-update-close')));
      await tester.pumpAndSettle();
      expect(b.seen, '4:9');
      expect(find.byKey(const Key('none')), findsOneWidget);
      // Next start: still closed.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, _watch(b));
      expect(find.byKey(const Key('none')), findsOneWidget);
    });

    testWidgets('macOS: the warning is the second step of the strip; Vazgeç does not update',
        (tester) async {
      final b =
          _FakeBackend({..._available, 'mac_permission_warning': true});
      await _pump(tester, _watch(b));
      await tester.tap(find.byKey(const Key('sense-update-update')));
      await tester.pumpAndSettle();
      expect(find.text(senseUpdateText('mac_body')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-update-macCancel')));
      await tester.pumpAndSettle();
      expect(b.installs, isEmpty);

      await tester.tap(find.byKey(const Key('sense-update-update')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sense-update-macGo')));
      await tester.pumpAndSettle();
      expect(b.installs, [4]);
    });

    testWidgets('Windows: no warning before the request', (tester) async {
      final b = _FakeBackend({..._available});
      await _pump(tester, _watch(b));
      await tester.tap(find.byKey(const Key('sense-update-update')));
      await tester.pumpAndSettle();
      expect(find.text(senseUpdateText('mac_body')), findsNothing);
      expect(b.installs, [4]);
    });

    testWidgets('version label opens About; nothing without a number',
        (tester) async {
      var opened = 0;
      await _pump(
          tester,
          Column(children: [
            SenseVersionChip(version: 3, onTap: () => opened++),
            const SenseVersionChip(version: null),
          ]));
      expect(find.text('Sürüm 3'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-version-chip')));
      expect(opened, 1);
      expect(find.byKey(const Key('sense-version-chip')), findsOneWidget);
    });
  });

  group('strip: download cancel, splash, done frame', () {
    test('Vazgeç only when the backend can stop the download', () {
      final json = {'state': 'downloading', 'target': 4, 'progress_pct': 10};
      expect(_actions(json), isEmpty);
      expect(_actions(json, const SenseUpdateUiState(canCancel: true)), [SenseUpdateAction.cancel]);
      // A panel order's download is not stopped from the computer (D3e).
      expect(_actions({...json, 'source': 'panel'}, const SenseUpdateUiState(canCancel: true)), isEmpty);
      expect(_actions({...json, 'source': 'local'}, const SenseUpdateUiState(canCancel: true)),
          [SenseUpdateAction.cancel]);
    });

    test('the bridge offers Vazgeç where the core can cancel (Windows)', () {
      expect(SenseUpdateBridge().canCancel, Platform.isWindows);
    });

    testWidgets('Vazgeç stops the download', (tester) async {
      final b = _FakeBackend({'state': 'downloading', 'target': 4, 'progress_pct': 42}, cancellable: true);
      await _pump(tester, _watch(b));
      expect(find.byKey(const Key('sense-update-progress')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-update-cancel')));
      await tester.pumpAndSettle();
      expect(b.cancels, 1);
      expect(find.text('Yeni sürüm hazır: Sürüm 4'), findsOneWidget);
    });

    testWidgets('installing covers the screen with the splash', (tester) async {
      final b = _FakeBackend({'state': 'installing', 'target': 4});
      await pumpSense(
          tester,
          SenseUpdateWatch(
              backend: b,
              interval: const Duration(hours: 1),
              builder: (_, strip) => SizedBox(width: 1000, height: 600, child: strip)),
          center: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Sürüm 4 kuruluyor · Sense Remote yeniden açılıyor'), findsOneWidget);
    });

    test('updated notice has the green frame; failed the red one', () {
      final done = senseUpdateStrip(_s({
        'current': 4,
        'last_result': {'state': 'installed', 'from': 3, 'to': 4, 'at': 1}
      }))!;
      expect(done.done, isTrue);
      expect(senseUpdateStrip(_s({'state': 'failed', 'target': 4}))!.problem, isTrue);
    });

    test('macOS step: only while an update can be asked for', () {
      const ui = SenseUpdateUiState(askingMac: true);
      final ask = senseUpdateStrip(_s({..._available, 'mac_permission_warning': true}), ui)!;
      expect(ask.asking, isTrue);
      expect(ask.text, senseUpdateText('mac_body'));
      expect(ask.actions, [SenseUpdateAction.macCancel, SenseUpdateAction.macGo]);
      expect(senseUpdateStrip(_s({'state': 'verifying', 'target': 4}), ui)!.asking, isFalse);
    });
  });

  group('About box', () {
    test('Güncel only after a check; ready with Güncelle', () {
      final cur = senseAboutUpdateBox(_s({'state': 'idle', 'checked_at': 1000}), 1240, host: false);
      expect(cur.title, 'Güncel');
      expect(cur.current, isTrue);
      expect(cur.body, 'Son denetim 4 dk önce · panelden otomatik');
      expect(cur.action, SenseAboutUpdateAction.check);

      final never = senseAboutUpdateBox(_s({'state': 'idle'}), 0, host: false);
      expect(never.current, isFalse);
      expect(never.title, isNot('Güncel'));

      final ready = senseAboutUpdateBox(_s(_available), 1000, host: false);
      expect(ready.title, 'Yeni sürüm hazır: Sürüm 4');
      expect(ready.body, contains('onayınla kurulur'));
      expect(ready.action, SenseAboutUpdateAction.update);
      expect(senseAboutUpdateBox(_s(_available), 1000, host: true).body, contains('bağlantı yokken'));

      final unsupported =
          senseAboutUpdateBox(SenseUpdateStatus.parse(jsonEncode({'current': 3, ..._available})), 1000, host: false);
      expect(unsupported.action, SenseAboutUpdateAction.check);
    });
  });

  group('golden images', () {
    SenseUpdateStripView strip(Map<String, Object?> json, [SenseUpdateUiState ui = const SenseUpdateUiState()]) =>
        SenseUpdateStripView(
            strip: senseUpdateStrip(_s(json), ui)!,
            progressPct: _s(json).state == SenseUpdateState.downloading ? _s(json).progressPct : null,
            onAction: (_) {});

    testWidgets('every strip state', (tester) async {
      final states = <Widget>[
        strip(_available),
        strip({..._available, 'mac_permission_warning': true}, const SenseUpdateUiState(askingMac: true)),
        strip({..._available, 'blocked': 'session_active'}, const SenseUpdateUiState(requested: true)),
        strip({'state': 'scheduled', 'target': 4, 'source': 'panel'}),
        strip({'state': 'scheduled', 'target': 4, 'source': 'panel', 'blocked': 'night_window'}),
        strip({'state': 'downloading', 'target': 4, 'progress_pct': 42}, const SenseUpdateUiState(canCancel: true)),
        strip({'state': 'verifying', 'target': 4}),
        strip({'state': 'installing', 'target': 4}),
        strip({
          'current': 4,
          'last_result': {'state': 'installed', 'from': 3, 'to': 4, 'at': 1}
        }),
        strip({'state': 'failed', 'target': 4, 'error': 'download_failed'}),
        strip({'state': 'rolled_back', 'target': 4}),
      ];
      await _pump(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: const Key('golden'),
              child: Container(
                color: Colors.black,
                width: 900,
                padding: const EdgeInsets.all(20),
                child: Column(children: [
                  for (final s in states) Padding(padding: const EdgeInsets.only(bottom: 10), child: s),
                ]),
              ),
            ),
          ),
          size: const Size(900, 900));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenPath('update_strip_states')));
    }, skip: goldenSkip('update_strip_states'));

    testWidgets('narrow strip (Host window 280 px), macOS step', (tester) async {
      await _pump(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: const Key('golden'),
              child: Container(
                color: Colors.black,
                width: 280,
                padding: const EdgeInsets.all(10),
                child: Column(children: [
                  strip(_available),
                  const SizedBox(height: 10),
                  strip({..._available, 'mac_permission_warning': true}, const SenseUpdateUiState(askingMac: true)),
                ]),
              ),
            ),
          ),
          size: const Size(280, 400));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenPath('update_strip_narrow')));
    }, skip: goldenSkip('update_strip_narrow'));
  });
}
