// Sense Remote: Sürüm 11, paket UI (B1, B2, B5, B12, B13, B15). A grey row always says why,
// the recording notice follows the real state, "Özel kalite" keeps the quality chosen
// before, and the ghost button names the reason it is grey.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_model.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_specs.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/screens/session/lists/session_list.dart';
import 'package:flutter_hbb/sense/strings/session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_backend.dart';
import 'harness.dart';

SensePeerFacts _facts({bool viewOnly = false, bool privacyOn = false, int displays = 3, int current = 0}) =>
    SensePeerFacts(
      displaysCount: displays,
      currentDisplay: current,
      viewOnly: viewOnly,
      privacyOn: privacyOn,
      localMultiScreens: true,
      rustDeskIdd: true,
      resolutionsCount: 3,
      codecFormat: 'VP9',
      elevationOffered: true,
      viewCameraSupported: true,
      localWindows: true,
    );

Iterable<SenseListEntry> _all(FakeBackend b) sync* {
  for (final m in SenseBarMenu.values) {
    yield* senseBuildList(m, b).allEntries;
  }
}

void main() {
  group('B2/B15: a grey row says why (cross table over the facts)', () {
    for (final viewOnly in [false, true]) {
      for (final privacy in [false, true]) {
        for (final displays in [1, 2, 5]) {
          for (final onAll in [false, true]) {
            if (onAll && displays == 1) continue;
            test('viewOnly=$viewOnly ghost=$privacy displays=$displays all=$onAll', () {
              final b = FakeBackend(
                  facts: _facts(
                      viewOnly: viewOnly,
                      privacyOn: privacy,
                      displays: displays,
                      current: onAll ? SenseRd.allDisplays : 0))
                ..viewOnly = viewOnly
                ..fingerprint = ''
                ..screenshotBusy = true
                ..forceRelayEverywhere = true
                ..showRemoteCursorLocked = true;
              for (final e in _all(b)) {
                if (e.noRights || !e.disabled) continue;
                expect(e.shownHint, isNotNull, reason: '${e.id} is grey and gives no reason');
                expect(e.shownHint, isNotEmpty, reason: e.id);
              }
            });
          }
        }
      }
    }

    test('virtual display rows name ghost mode as the reason', () {
      final b = FakeBackend(facts: _facts(privacyOn: true));
      final e = {for (final x in _all(b)) x.id: x};
      expect(e['screens.virtual.add']!.disabled, isTrue);
      expect(e['screens.virtual.add']!.shownHint, SenseSessionStrings.whyGhost);
      expect(e['screens.virtual.removeAll']!.shownHint, SenseSessionStrings.whyGhost);
    });

    test('empty fingerprint: "henüz alınmadı"', () {
      final b = FakeBackend()..fingerprint = '';
      final e = {for (final x in _all(b)) x.id: x};
      expect(e['actions.fingerprint']!.shownHint, SenseSessionStrings.whyNotTaken);
    });

    test('view only: the keyboard rows say "Yalnız izle açıkken değişmez"', () {
      final b = FakeBackend(facts: _facts(viewOnly: true))..viewOnly = true;
      final e = {for (final x in _all(b)) x.id: x};
      for (final id in ['mouse.reverseWheel', 'mouse.swapButtons', 'mouse.trackpad', 'actions.lockAfterEnd']) {
        expect(e[id]!.shownHint, SenseSessionStrings.whyViewOnly, reason: id);
      }
    });
  });

  group('B5: the recording notice waits for the real state', () {
    test('started: "Kayıt başladı"', () async {
      final b = FakeBackend();
      final rec = {for (final x in _all(b)) x.id: x}['actions.record']! as SenseToggleEntry;
      rec.onChanged!(true);
      expect(await rec.toastAfterChange!(), SenseSessionStrings.recordStarted);
      expect(b.recordingOn, isTrue);
    });

    test('did not start: says so, not "Kayıt · açık"', () async {
      final b = _StuckRecording();
      final rec = {for (final x in _all(b)) x.id: x}['actions.record']! as SenseToggleEntry;
      rec.onChanged!(true);
      expect(await rec.toastAfterChange!(), SenseSessionStrings.recordStartFailed);
    });
  });

  test('B12: turning "Özel kalite" off brings back the quality set before', () {
    final b = FakeBackend()..imageQuality = SenseRd.qualityBest;
    SenseToggleEntry custom() => {for (final x in _all(b)) x.id: x}['display.customQuality']! as SenseToggleEntry;
    custom().onChanged!(true);
    expect(b.imageQuality, SenseRd.qualityCustom);
    custom().onChanged!(false);
    expect(b.imageQuality, SenseRd.qualityBest);
  });

  testWidgets('B13: the screen that is already shown gives no notice', (tester) async {
    final b = FakeBackend();
    final notes = <String>[];
    final spec = senseScreensList(b);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 360, child: SenseListEntryView(entry: spec.frequent.first, notify: notes.add)),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('sense-tile-0')));
    await tester.pump();
    expect(notes, isEmpty);
    await tester.tap(find.byKey(const ValueKey('sense-tile-1')));
    await tester.pump();
    expect(notes, [SenseSessionStrings.screenN(2)]);
  });

  group('B1: the ghost button says why it is grey', () {
    testWidgets('view only', (tester) async {
      setWindow(tester, const Size(1600, 900));
      final b = FakeBackend(facts: _facts(viewOnly: true))
        ..viewOnly = true
        ..ghostAvailable = false;
      await tester.pumpWidget(frameApp(b));
      await tester.pump();
      expect(find.byTooltip(SenseSessionStrings.ghostUnavailableViewOnly), findsOneWidget);
    });

    testWidgets('an open ghost mode can be switched off while view only is on', (tester) async {
      setWindow(tester, const Size(1600, 900));
      final b = FakeBackend(facts: _facts(viewOnly: true))
        ..viewOnly = true
        ..ghostOn = true
        ..ghostAvailable = true;
      await tester.pumpWidget(frameApp(b));
      await tester.tap(find.byKey(const ValueKey('sense-bar-ghost')));
      await tester.pump();
      expect(b.ghostOn, isFalse);
      await drain(tester);
    });
  });
}

class _StuckRecording extends FakeBackend {
  @override
  void toggleRecording() => calls.add('recording-stuck');
}
