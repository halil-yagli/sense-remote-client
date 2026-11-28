// Sense Remote (Sürüm 12, #166, FU-A6): the "Neler yeni" one-line summary in the update strip.
// The text comes signed with the release (`GuiStatus.notes_summary`, at most 120 characters);
// the strip shows it after the bold line, the status dot of the menu follows the same status.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/controller/shell/nav_dots.dart' show senseAboutNavLevel;
import 'package:flutter_hbb/sense/screens/controller/update/sense_update_model.dart';
import 'package:flutter_hbb/sense/screens/controller/update/sense_update_view.dart';
import 'package:flutter_hbb/sense/sense.dart' show SenseLevel;
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

SenseUpdateStatus _s(Map<String, Object?> json) =>
    SenseUpdateStatus.parse(jsonEncode({'current': 3, 'supported': true, ...json}));

const _summary = 'sohbetten dosya, sesli arama, yeni araç çubuğu';
const _available = {'state': 'available', 'target': 4, 'checked_at': 1000, 'notes_summary': _summary};

void main() {
  group('senseNotesSummary', () {
    test('plain text stays', () => expect(senseNotesSummary(_summary), _summary));

    test('nothing or only blanks is none', () {
      expect(senseNotesSummary(null), isNull);
      expect(senseNotesSummary(''), isNull);
      expect(senseNotesSummary('  \n\t '), isNull);
    });

    test('one line: control characters and runs of spaces become one space', () {
      expect(senseNotesSummary('yeni\naraç\u0000 çubuğu   geldi'), 'yeni araç çubuğu geldi');
    });

    test('at most 120 characters, cut with an ellipsis', () {
      final long = List.filled(130, 'ş').join();
      final out = senseNotesSummary(long)!;
      expect(out.runes.length, 120);
      expect(out.endsWith('…'), isTrue);
      expect(senseNotesSummary(List.filled(120, 'ş').join())!.runes.length, 120);
    });
  });

  group('status and strip', () {
    test('GuiStatus carries the summary; an old core without it is fine', () {
      expect(_s(_available).notesSummary, _summary);
      expect(_s({...(_available)}..remove('notes_summary')).notesSummary, isNull);
      expect(_s({..._available, 'notes_summary': 5}).notesSummary, isNull);
    });

    test('"Yeni sürüm hazır" keeps its text; the summary is the detail', () {
      final strip = senseUpdateStrip(_s(_available))!;
      expect(strip.text, 'Yeni sürüm hazır: Sürüm 4');
      expect(strip.detail, 'Neler yeni: $_summary');
    });

    test('no summary, no detail (the strip is as before)', () {
      expect(senseUpdateStrip(_s({..._available, 'notes_summary': null}))!.detail, isNull);
    });

    test('only the "hazır" strip carries it', () {
      expect(senseUpdateStrip(_s({..._available, 'state': 'downloading', 'progress_pct': 10}))!.detail, isNull);
      expect(senseUpdateStrip(_s({..._available, 'state': 'failed', 'error': 'download_failed'}))!.detail, isNull);
      expect(
          senseUpdateStrip(_s({..._available, 'blocked': 'session_active'}), const SenseUpdateUiState(requested: true))!
              .detail,
          isNull);
    });
  });

  group('menu dot next to Hakkında', () {
    test('yellow while a verified newer release waits, else none', () {
      expect(senseAboutNavLevel(_s(_available)), SenseLevel.warn);
      expect(senseAboutNavLevel(_s({'state': 'idle', 'checked_at': 1})), isNull);
      expect(senseAboutNavLevel(_s({'state': 'downloading', 'target': 4})), isNull);
      expect(senseAboutNavLevel(_s({'state': 'available', 'target': 3})), isNull, reason: 'not newer');
    });

    testWidgets('the watch hands every status to onStatus', (tester) async {
      final seen = <SenseUpdateStatus>[];
      await pumpSense(
          tester,
          SenseUpdateWatch(
            backend: _Backend(_available),
            showSplash: false,
            interval: const Duration(hours: 1),
            onStatus: seen.add,
            builder: (context, strip) => strip ?? const SizedBox(),
          ));
      await tester.pump();
      expect(seen, isNotEmpty);
      expect(seen.last.hasReadyRelease, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('strip view', () {
    SenseUpdateStripView view(Map<String, Object?> json) =>
        SenseUpdateStripView(strip: senseUpdateStrip(_s(json))!, onAction: (_) {});

    testWidgets('the summary follows the bold line on the same text', (tester) async {
      await pumpSense(tester, SizedBox(width: 900, child: view(_available)));
      final text = tester.widget<Text>(find.byKey(const Key('sense-update-text')));
      expect(text.textSpan!.toPlainText(), 'Yeni sürüm hazır: Sürüm 4 · Neler yeni: $_summary');
      expect(find.byKey(const Key('sense-update-update')), findsOneWidget);
    });

    testWidgets('without a summary the text is the plain line', (tester) async {
      await pumpSense(tester, SizedBox(width: 900, child: view({..._available, 'notes_summary': null})));
      expect(find.text('Yeni sürüm hazır: Sürüm 4'), findsOneWidget);
    });

    testWidgets('narrow strip: text above the buttons, no overflow', (tester) async {
      await pumpSense(tester, SizedBox(width: 280, child: view(_available)), size: const Size(400, 400));
      expect(tester.takeException(), isNull);
    });
  });

  group('golden images', () {
    testWidgets('strip with the "Neler yeni" summary', (tester) async {
      await pumpSense(
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
                  SenseUpdateStripView(strip: senseUpdateStrip(_s(_available))!, onAction: (_) {}),
                  const SizedBox(height: 10),
                  SenseUpdateStripView(
                      strip: senseUpdateStrip(_s({..._available, 'notes_url': 'https://remote.example/#surum-4'}))!,
                      onAction: (_) {}),
                ]),
              ),
            ),
          ),
          size: const Size(900, 260));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenPath('update_strip_summary')));
    }, skip: goldenSkip('update_strip_summary'), tags: const ['golden']);
  });
}

class _Backend extends SenseUpdateBackend {
  _Backend(this.json);
  final Map<String, Object?> json;

  @override
  Future<String> status() async => jsonEncode({'current': 3, 'supported': true, ...json});

  @override
  Future<String> install(int version) async => '';

  @override
  String seenInstalled() => '';

  @override
  Future<void> setSeenInstalled(String key) async {}

  @override
  void openUrl(String url) {}
}
