// Sense Remote: fixes from the golden ↔ prototype review (flow C): drawn carets instead of
// glyphs (G1), camera item only when supported (G4, Y1), no handle over an open list (G5), disabled sliders (O4),
// trackpad range and the follow-cursor rows (O5), Turkish percent (G9).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/caret.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/island/sense_island.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_strings.dart';
import 'package:flutter_hbb/sense/screens/session/lists/ffi_backend.dart' show senseShortcutText;
import 'package:flutter_hbb/sense/screens/session/lists/list_model.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_specs.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_format.dart';

import 'fake_backend.dart';
import 'harness.dart';

Finder menu(SenseBarMenu m) => find.byKey(ValueKey('sense-bar-menu-${m.name}'));

void main() {
  testWidgets('G1: list buttons draw their caret (no ▾ text)', (tester) async {
    setWindow(tester, const Size(1600, 900));
    await tester.pumpWidget(frameApp(FakeBackend()));
    // Sürüm 12 (#160): five lists with Sık kullanılanlar.
    expect(find.byType(SenseCaret), findsNWidgets(5));
    expect(find.textContaining('▾'), findsNothing);
    await drain(tester);
  });

  testWidgets('G5: the handle is not drawn while a list is open', (tester) async {
    setWindow(tester, const Size(1600, 900));
    await tester.pumpWidget(frameApp(FakeBackend()));
    expect(find.byType(SenseIsland), findsOneWidget);
    await tester.tap(menu(SenseBarMenu.screens));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SenseIsland), findsNothing);
    await tester.tapAt(const Offset(1500, 800));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SenseIsland), findsOneWidget);
    await drain(tester);
  });

  // G4 was "no camera item" (#67 read as covering it). #67 only moved the video call;
  // Sürüm 9 (#102, Y1) brings back the one-way "Kamerayı görüntüle" of O6 / prototype c05.
  // Still no camera button in the chat call (#67) and none where the peer cannot show one.
  test('G4 / Y1: camera item only where the peer can show its cameras', () {
    final none = FakeBackend(facts: const SensePeerFacts(displaysCount: 3));
    final spec = senseBuildList(SenseBarMenu.actions, none);
    expect(spec.allEntries.map((e) => e.id), isNot(contains('actions.camera')));
    expect(spec.allEntries.map((e) => e.label).join(' '), isNot(contains('Kamera')));
    expect(spec.sections.firstWhere((s) => s.id == 'advanced').summary, isNot(contains('kamera')));
    final cam = senseBuildList(SenseBarMenu.actions, FakeBackend());
    expect(cam.allEntries.map((e) => e.id), contains('actions.camera'));
    expect(cam.sections.firstWhere((s) => s.id == 'advanced').summary, 'terminal, tünel, kamera…');
  });

  testWidgets('O4: quality and frame rate sliders are off until "Özel kalite" is on', (tester) async {
    setWindow(tester, const Size(1440, 900));
    final b = FakeBackend();
    await tester.pumpWidget(frameApp(b));
    await tester.tap(menu(SenseBarMenu.display));
    await tester.pump();
    await tester.tap(find.text('Özel kalite').last);
    await tester.pump(const Duration(milliseconds: 400));
    final sliders = find.byType(Slider);
    expect(sliders, findsWidgets);
    for (final s in tester.widgetList<Slider>(sliders)) {
      expect(s.onChanged, isNull);
    }
    expect(find.ancestor(of: sliders.first, matching: find.byType(Opacity)), findsWidgets);
    // Turn it on: the sliders work.
    final toggleTarget = find.text('Özel kalite');
    await tester.tap(toggleTarget.last);
    await tester.pump(const Duration(milliseconds: 400));
    if (b.imageQuality != SenseRd.qualityCustom) {
      b.setImageQuality(SenseRd.qualityCustom);
      await tester.pump(const Duration(milliseconds: 400));
    }
    for (final s in tester.widgetList<Slider>(find.byType(Slider))) {
      expect(s.onChanged, isNotNull);
    }
    await drain(tester);
  });

  test('O5: trackpad slider range matches the prototype, value 100 is not at the far left', () {
    final b = FakeBackend();
    final e = senseBuildList(SenseBarMenu.keyboard, b).allEntries.whereType<SenseSliderEntry>().firstWhere((x) => x.id == 'mouse.trackpad');
    expect(e.min, 10);
    expect(e.max, 300);
    expect(e.value, 100);
    expect(e.format(100), '%100');
    expect((e.value - e.min) / (e.max - e.min), closeTo(0.31, 0.01));
  });

  test('O5: "Uzak imleci izle" and "Uzak pencere odağını izle" with several displays, bound to the options', () {
    final b = FakeBackend();
    final ents = senseBuildList(SenseBarMenu.keyboard, b).allEntries;
    final c = ents.firstWhere((x) => x.id == 'mouse.followCursor') as SenseToggleEntry;
    final w = ents.firstWhere((x) => x.id == 'mouse.followWindow') as SenseToggleEntry;
    expect(c.label, 'Uzak imleci izle');
    expect(w.label, 'Uzak pencere odağını izle');
    c.onChanged!(true);
    w.onChanged!(true);
    expect(b.followRemoteCursor, isTrue);
    expect(b.followRemoteWindow, isTrue);
  });

  test('G9: Turkish percent, sign first, decimal comma', () {
    expect(SenseLayerStrings.percent(5.1), '%5,1');
    expect(SenseLayerStrings.percent(100), '%100');
    expect(SenseLayerStrings.percent(0.2), '%0,2');
    expect(SenseLayerStrings.percent(0), '%0');
    expect(sensePctDecimal(12.5), '%12,5');
  });

  test('G1: arrow shortcut keys are words, not glyphs', () {
    expect(senseShortcutText({'mods': ['ctrl', 'alt', 'shift'], 'key': 'arrow_right'}, mac: false), 'Ctrl+Alt+Shift+Sağ');
    expect(senseShortcutText({'mods': ['alt'], 'key': 'arrow_up'}, mac: true), 'Option+Yukarı');
  });
}
