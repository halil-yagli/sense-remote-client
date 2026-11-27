// Sense Remote: Sürüm 10 (Paket L10) list fixes.
//  #111 Ekranlar: tiles wrap into rows of 4; "Tümü birlikte" is always the last tile and
//       visible (a 4-screen computer showed only 4 tiles before). 1–8 screens.
//  #116 "Tüm ekranlarımı kullan": applies at once where it can; otherwise the row and a
//       toast say "yeni bağlantıda geçerli". The separate windows default (#97) stays.
// K20: the new behaviour does not change any other entry of the lists.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/toggle.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/backend.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_model.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_specs.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/screens/session/lists/session_list.dart' show kSenseTilesPerRow;

import 'fake_backend.dart';
import 'harness.dart';

Finder _menu(SenseBarMenu m) => find.byKey(ValueKey('sense-bar-menu-${m.name}'));
Finder _tile(int v) => find.byKey(ValueKey('sense-tile-$v'));

FakeBackend _withScreens(int n) {
  final b = FakeBackend(
      facts: SensePeerFacts(
          displaysCount: n, localMultiScreens: true, rustDeskIdd: true, resolutionsCount: 3, codecFormat: 'VP9'));
  b.displays = [for (var i = 0; i < n; i++) SenseDisplayRef(i, primary: i == 0, width: 1920, height: 1080)];
  return b;
}

Map<String, SenseListEntry> _entries(SenseSessionBackend b) => {
      for (final m in SenseBarMenu.values)
        for (final e in senseBuildList(m, b).allEntries) e.id: e,
    };

/// Visible state of every entry except [skip].
Map<String, String> _state(SenseSessionBackend b, {Set<String> skip = const {}}) => {
      for (final e in _entries(b).entries)
        if (!skip.contains(e.key))
          e.key: switch (e.value) {
            SenseToggleEntry t => 'toggle ${t.value} ${t.onChanged != null} ${t.noRights} ${t.hint}',
            SenseActionEntry a => 'action ${a.onTap != null} ${a.noRights} ${a.label}',
            SenseChoiceEntry c => 'choice ${c.value} ${c.onChanged != null} ${c.noRights} ${c.options.length}',
            SenseSliderEntry s => 'slider ${s.value} ${s.onChanged != null}',
            SenseInfoEntry i => 'info ${i.detail}',
            SenseTilesEntry t => 'tiles ${t.tiles.length} ${t.value}',
            SenseSizeInputEntry z => 'size ${z.width} ${z.height}',
          },
    };

void main() {
  group('#111 Ekranlar tiles: rows of 4, "Tümü birlikte" always last and visible', () {
    test('spec: one tile per screen, then Tümü (more than one screen)', () {
      for (var n = 1; n <= 8; n++) {
        final tiles = (senseScreensList(_withScreens(n)).frequent.first as SenseTilesEntry).tiles;
        expect(tiles.length, n == 1 ? 1 : n + 1, reason: '$n screens');
        if (n > 1) expect(tiles.last.value, SenseRd.allDisplays, reason: '$n screens');
      }
    });

    for (var n = 1; n <= 8; n++) {
      testWidgets('$n screen(s): every tile drawn, tappable, in rows of $kSenseTilesPerRow', (tester) async {
        setWindow(tester, const Size(1440, 900));
        final b = _withScreens(n);
        await tester.pumpWidget(frameApp(b));
        await tester.tap(_menu(SenseBarMenu.screens));
        await tester.pump();
        final values = [for (var i = 0; i < n; i++) i, if (n > 1) SenseRd.allDisplays];
        final rects = <Rect>[];
        for (final v in values) {
          expect(_tile(v).hitTestable(), findsOneWidget, reason: 'tile $v of $n');
          rects.add(tester.getRect(_tile(v)));
        }
        final rows = rects.map((r) => r.top).toSet().length;
        expect(rows, (values.length / kSenseTilesPerRow).ceil(), reason: '$n screens');
        // Reading order: left to right, then the next row; Tümü is the last one.
        for (var i = 1; i < rects.length; i++) {
          final a = rects[i - 1], c = rects[i];
          expect(c.top > a.top || (c.top == a.top && c.left > a.left), isTrue, reason: 'tile $i of $n');
        }
        // All tiles the same width (a row with fewer tiles keeps the 4-column grid).
        expect(rects.map((r) => r.width.round()).toSet().length, 1, reason: '$n screens');
        if (n > 1) {
          await tester.tap(_tile(SenseRd.allDisplays));
          await tester.pump();
          expect(b.calls, contains('openDisplay:${SenseRd.allDisplays}'));
        }
        await drain(tester);
      });
    }
  });

  group('#116 Tüm ekranlarımı kullan', () {
    SenseToggleEntry allMine(SenseSessionBackend b) => _entries(b)['screens.allMine'] as SenseToggleEntry;

    test('on: applied at once (spread), no "yeni bağlantıda geçerli"', () {
      final b = FakeBackend();
      allMine(b).onChanged!(true);
      expect(b.useAllMyDisplays, isTrue);
      expect(b.calls, contains('spreadDisplays'));
      expect(b.useAllMyDisplaysPending, isFalse);
      expect(allMine(b).hint, isNull);
      expect(allMine(b).toastAfterChange!(), isNull, reason: 'the default "· Açık" toast');
    });

    test('off after spreading: waits for the next connection and says so; on again clears it', () {
      final b = FakeBackend();
      allMine(b).onChanged!(true);
      allMine(b).onChanged!(false);
      expect(b.useAllMyDisplays, isFalse);
      expect(b.useAllMyDisplaysPending, isTrue);
      expect(allMine(b).hint, 'yeni bağlantıda geçerli');
      expect(allMine(b).toastAfterChange!(), 'Tüm ekranlarımı kullan · yeni bağlantıda geçerli');
      allMine(b).onChanged!(true);
      expect(b.useAllMyDisplaysPending, isFalse);
      expect(b.calls.where((c) => c == 'spreadDisplays').length, 1, reason: 'already spread');
    });

    test('cannot spread now: the row says "yeni bağlantıda geçerli"', () {
      final b = FakeBackend()..canSpread = false;
      allMine(b).onChanged!(true);
      expect(b.calls, isNot(contains('spreadDisplays')));
      expect(b.useAllMyDisplaysPending, isTrue);
      expect(allMine(b).hint, 'yeni bağlantıda geçerli');
      allMine(b).onChanged!(false);
      expect(b.useAllMyDisplaysPending, isFalse, reason: 'back to what this session has');
    });

    test('K20: the switch changes only its own row; separate windows (#97) stay off', () {
      for (final ghost in [false, true]) {
        for (final displays in [2, 3, 4]) {
          final b = FakeBackend(
              facts: SensePeerFacts(
                  displaysCount: displays,
                  privacyOn: ghost,
                  localMultiScreens: true,
                  rustDeskIdd: true,
                  resolutionsCount: 3,
                  codecFormat: 'VP9'));
          final before = _state(b, skip: {'screens.allMine'});
          allMine(b).onChanged!(true);
          allMine(b).onChanged!(false);
          expect(_state(b, skip: {'screens.allMine'}), before, reason: 'ghost=$ghost displays=$displays');
          expect(b.individualWindows, isFalse, reason: '#97 default untouched');
        }
      }
    });

    testWidgets('on screen: hint in the row and the toast', (tester) async {
      setWindow(tester, const Size(1440, 900));
      final b = FakeBackend()..canSpread = false;
      await tester.pumpWidget(frameApp(b));
      await tester.tap(_menu(SenseBarMenu.screens));
      await tester.pump();
      await tester.tap(find.text('Çok monitör'));
      await tester.pump(const Duration(milliseconds: 400));
      final toggle = find.byWidgetPredicate((w) => w is SenseToggle && w.semanticLabel == 'Tüm ekranlarımı kullan');
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();
      expect(find.textContaining('yeni bağlantıda geçerli'), findsWidgets);
      expect(find.text('Tüm ekranlarımı kullan · yeni bağlantıda geçerli'), findsOneWidget, reason: 'toast');
      await drain(tester);
    });
  });
}
