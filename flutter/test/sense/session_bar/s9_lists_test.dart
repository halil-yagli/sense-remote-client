// Sense Remote: Sürüm 9 list items (Paket L): Kamerayı görüntüle (Y1, O6), Terminal aç
// (yönetici) (R2), hep aktarmayla bağlan (R3), çizim ayarları (R4), özel çözünürlük (R5),
// "%N ölçekte" (Y6, O1). K20: every new item is checked against the visibility rules of the
// same lists (ghost mode, view only, keyboard, displays, OS, permissions) so that it does
// not change any existing item (#97 lesson).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/data/grants.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/backend.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_model.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_specs.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/screens/session/lists/session_list.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'fake_backend.dart';

const kNewIds = {
  'actions.camera',
  'actions.terminalAdmin',
  'actions.forceRelay',
  'display.textureRender',
  'display.d3dRender',
  'display.scaleNote',
  'screens.customResolution',
};

Map<String, SenseListEntry> entriesOf(SenseSessionBackend b) => {
      for (final m in SenseBarMenu.values)
        for (final e in senseBuildList(m, b).allEntries) e.id: e,
    };

/// The visible state of the entries that existed before Sürüm 9: id, value, enabled, locked.
Map<String, String> oldState(SenseSessionBackend b) => {
      for (final e in entriesOf(b).entries)
        if (!kNewIds.contains(e.key))
          e.key: switch (e.value) {
            SenseToggleEntry t => 'toggle ${t.value} ${t.onChanged != null} ${t.noRights}',
            SenseActionEntry a => 'action ${a.onTap != null} ${a.noRights} ${a.label}',
            SenseChoiceEntry c => 'choice ${c.value} ${c.onChanged != null} ${c.noRights} ${c.options.length}',
            SenseSliderEntry s => 'slider ${s.value} ${s.onChanged != null}',
            SenseInfoEntry i => 'info ${i.detail}',
            SenseTilesEntry t => 'tiles ${t.tiles.length} ${t.value}',
            SenseSizeInputEntry z => 'size ${z.width} ${z.height}',
          },
    };

Map<String, String?> summaries(SenseSessionBackend b) => {
      for (final m in SenseBarMenu.values)
        for (final s in senseBuildList(m, b).sections)
          if (s.id != 'render' && s.id != 'advanced' && s.id != 'scale') '${m.name}.${s.id}': s.summary,
    };

void main() {
  group('K20: the new items never change the existing ones', () {
    final cases = <String, SensePeerFacts Function({required bool extra})>{};
    for (final ghost in [false, true]) {
      for (final viewOnly in [false, true]) {
        for (final keyboard in [true, false]) {
          for (final os in [SensePeerOs.windows, SensePeerOs.mac]) {
            for (final displays in [1, 3]) {
              for (final all in displays > 1 ? [false, true] : [false]) {
                for (final denied in [<String>{}, {'camera', 'terminal', 'restart'}]) {
                  final name = 'ghost=$ghost viewOnly=$viewOnly keyboard=$keyboard ${os.name} '
                      'displays=$displays all=$all denied=${denied.join(',')}';
                  cases[name] = ({required bool extra}) => SensePeerFacts(
                        os: os,
                        sasEnabled: os == SensePeerOs.windows,
                        privacyOn: ghost,
                        viewOnly: viewOnly,
                        keyboard: keyboard,
                        displaysCount: displays,
                        currentDisplay: all ? SenseRd.allDisplays : 0,
                        deniedPerms: denied,
                        resolutionsCount: 3,
                        rustDeskIdd: true,
                        codecFormat: 'VP9',
                        elevationOffered: true,
                        localMultiScreens: true,
                        // The facts the new items read:
                        viewCameraSupported: extra,
                        localWindows: extra,
                        virtualResolution: extra,
                      );
                }
              }
            }
          }
        }
      }
    }

    test('${cases.length} combinations: same existing entries, values and summaries', () {
      final failures = <String>[];
      for (final c in cases.entries) {
        // virtualResolution also opens the resolution list on a one-resolution peer; keep
        // three resolutions so the existing resolution choice is there in both runs.
        final before = FakeBackend(facts: c.value(extra: false));
        final after = FakeBackend(facts: c.value(extra: true));
        final a = oldState(before), b = oldState(after);
        if (a.toString() != b.toString()) failures.add('${c.key}\n  before $a\n  after  $b');
        if (summaries(before).toString() != summaries(after).toString()) failures.add('${c.key}: summaries');
      }
      expect(failures, isEmpty, reason: failures.take(3).join('\n'));
    });

    test('ghost mode: separate windows switch (#97), camera and custom resolution all stay', () {
      for (final ghost in [false, true]) {
        final b = FakeBackend(
            facts: SensePeerFacts(
                displaysCount: 3, privacyOn: ghost, viewCameraSupported: true, resolutionsCount: 3, virtualResolution: true));
        final e = entriesOf(b);
        expect(e, contains('screens.individual'), reason: 'ghost=$ghost');
        expect(e, contains('actions.camera'), reason: 'ghost=$ghost');
        expect(e, contains('screens.customResolution'), reason: 'ghost=$ghost');
      }
    });

    test('the new switches change only their own value', () {
      final b = FakeBackend();
      final before = oldState(b);
      final e = entriesOf(b);
      (e['actions.forceRelay'] as SenseToggleEntry).onChanged!(true);
      (e['display.textureRender'] as SenseToggleEntry).onChanged!(true);
      (e['display.d3dRender'] as SenseToggleEntry).onChanged!(true);
      expect(oldState(b), before);
      expect(b.forceRelay && b.textureRender && b.d3dRender, isTrue);
    });
  });

  group('Y1 Kamerayı görüntüle (O6)', () {
    test('in Eylemler › Gelişmiş, after TCP tüneli, opens the camera connection', () {
      final b = FakeBackend();
      final adv = senseActionsList(b).sections.firstWhere((s) => s.id == 'advanced');
      final ids = adv.entries.map((e) => e.id).toList();
      expect(ids.indexOf('actions.camera'), greaterThan(ids.indexOf('actions.tunnel')));
      expect(ids.last, 'actions.fingerprint');
      final cam = adv.entries.firstWhere((e) => e.id == 'actions.camera') as SenseActionEntry;
      expect(cam.label, 'Kamerayı görüntüle');
      cam.onTap!();
      expect(b.calls, contains('camera'));
    });

    test('hidden: Mac peer (no camera support), camera permission off, not a remote session', () {
      expect(entriesOf(FakeBackend(facts: const SensePeerFacts(os: SensePeerOs.mac, viewCameraSupported: false))),
          isNot(contains('actions.camera')));
      expect(entriesOf(FakeBackend(facts: const SensePeerFacts(viewCameraSupported: true, deniedPerms: {'camera'}))),
          isNot(contains('actions.camera')));
      expect(entriesOf(FakeBackend(facts: const SensePeerFacts(viewCameraSupported: true, defaultConn: false))),
          isNot(contains('actions.camera')));
      expect(entriesOf(FakeBackend(facts: const SensePeerFacts(viewCameraSupported: true))), contains('actions.camera'));
    });
  });

  group('R2 Terminal aç (yönetici)', () {
    test('Windows peer only, next to Terminal aç, same right (terminal_tunnel)', () {
      final win = senseActionsList(FakeBackend()).sections.firstWhere((s) => s.id == 'advanced').entries;
      final ids = win.map((e) => e.id).toList();
      expect(ids.indexOf('actions.terminalAdmin'), ids.indexOf('actions.terminal') + 1);
      expect(entriesOf(FakeBackend(facts: const SensePeerFacts(os: SensePeerOs.mac))), isNot(contains('actions.terminalAdmin')));
      final locked = FakeBackend(grants: const SenseSessionGrants(SenseGrantsState.ok, {SenseGrant.connect}));
      expect(entriesOf(locked)['actions.terminalAdmin']!.noRights, isTrue);
      final ok = FakeBackend(grants: const SenseSessionGrants(SenseGrantsState.ok, {SenseGrant.terminalTunnel}));
      final e = entriesOf(ok)['actions.terminalAdmin'] as SenseActionEntry;
      expect(e.noRights, isFalse);
      e.onTap!();
      expect(ok.calls, contains('terminalAdmin'));
    });
  });

  group('R3 hep aktarmayla bağlan', () {
    test('switch writes the peer option; panel-wide relay shows on and locked', () {
      final b = FakeBackend();
      final e = entriesOf(b)['actions.forceRelay'] as SenseToggleEntry;
      expect(e.value, isFalse);
      expect(e.hint, 'sonraki bağlantıda');
      e.onChanged!(true);
      expect(b.forceRelay, isTrue);
      final everywhere = FakeBackend()..forceRelayEverywhere = true;
      final l = entriesOf(everywhere)['actions.forceRelay'] as SenseToggleEntry;
      expect(l.value, isTrue);
      expect(l.onChanged, isNull);
      expect(l.hint, 'panelden açık');
    });
  });

  group('R4 çizim ayarları', () {
    test('Görüntü › Gelişmiş, D3D only on a Windows Controller, summary names what is on', () {
      final b = FakeBackend();
      final render = senseDisplayList(b).sections.firstWhere((s) => s.id == 'render');
      expect(render.title, 'Gelişmiş');
      expect(render.entries.map((e) => e.id), ['display.textureRender', 'display.d3dRender', 'display.renderInfo']);
      expect(render.summary, 'varsayılan');
      b.textureRender = true;
      b.d3dRender = true;
      expect(senseDisplayList(b).sections.firstWhere((s) => s.id == 'render').summary, 'doku · D3D');
      final mac = FakeBackend(facts: const SensePeerFacts(localWindows: false));
      expect(entriesOf(mac), isNot(contains('display.d3dRender')));
      expect(entriesOf(mac), contains('display.textureRender'));
    });

    test('the existing Görüntü sections keep their order; Gelişmiş is last', () {
      final ids = senseDisplayList(FakeBackend()).sections.map((s) => s.id).toList();
      expect(ids, ['scale', 'quality', 'codec', 'audio', 'render']);
    });
  });

  group('R5 özel çözünürlük', () {
    test('only on a virtual display resolution, applies width × height', () {
      expect(entriesOf(FakeBackend()), isNot(contains('screens.customResolution')));
      final b = FakeBackend(facts: const SensePeerFacts(displaysCount: 3, resolutionsCount: 3, virtualResolution: true));
      final e = entriesOf(b)['screens.customResolution'] as SenseSizeInputEntry;
      expect(e.width, 3840);
      expect(e.height, 2160);
      e.onApply!(2560, 1440);
      expect(b.calls, contains('resolution:2560x1440'));
      final all = FakeBackend(
          facts: const SensePeerFacts(
              displaysCount: 3, resolutionsCount: 3, virtualResolution: true, currentDisplay: SenseRd.allDisplays));
      expect(entriesOf(all), isNot(contains('screens.customResolution')));
    });

    test('limits', () {
      expect(senseCustomSizeValid('1920', '1080'), isTrue);
      expect(senseCustomSizeValid('320', '7680'), isTrue);
      expect(senseCustomSizeValid('319', '1080'), isFalse);
      expect(senseCustomSizeValid('1920', '9000'), isFalse);
      expect(senseCustomSizeValid('', '1080'), isFalse);
      expect(senseCustomSizeValid('19a0', '1080'), isFalse);
    });

    testWidgets('row: a wrong size is said in place, a right one is applied', (tester) async {
      final applied = <String>[];
      final notes = <String>[];
      final b = FakeBackend(facts: const SensePeerFacts(displaysCount: 3, resolutionsCount: 3, virtualResolution: true));
      final spec = senseScreensList(b);
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final entry = spec.sections.firstWhere((s) => s.id == 'resolution').entries.whereType<SenseSizeInputEntry>().single;
      final row = SenseSizeInputEntry(
        id: entry.id,
        label: entry.label,
        hint: entry.hint,
        rustdesk: entry.rustdesk,
        width: entry.width,
        height: entry.height,
        onApply: (w, h) => applied.add('${w}x$h'),
      );
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: SenseColors.bg,
          body: SizedBox(width: 360, child: SenseListEntryView(entry: row, notify: notes.add)),
        ),
      ));
      final w = find.byKey(const ValueKey('sense-size-screens.customResolution-Genişlik'));
      final h = find.byKey(const ValueKey('sense-size-screens.customResolution-Yükseklik'));
      expect(w, findsOneWidget);
      await tester.enterText(w, '100');
      await tester.tap(find.byKey(const ValueKey('sense-size-apply-screens.customResolution')));
      await tester.pump();
      expect(applied, isEmpty);
      expect(find.text('Genişlik ve yükseklik 320–7680 arası olmalı'), findsOneWidget);
      await tester.enterText(w, '2560');
      await tester.enterText(h, '1440');
      await tester.pump();
      expect(find.text('Genişlik ve yükseklik 320–7680 arası olmalı'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sense-size-apply-screens.customResolution')));
      await tester.pump();
      expect(applied, ['2560x1440']);
      expect(notes.single, 'Özel çözünürlük · 2560×1440');
    });
  });

  group('Y6 "%N ölçekte" (O1)', () {
    test('first row of Ölçek ve kaydırma, and in its closed summary', () {
      final b = FakeBackend();
      final scale = senseDisplayList(b).sections.firstWhere((s) => s.id == 'scale');
      final note = scale.entries.first as SenseInfoEntry;
      expect(note.id, 'display.scaleNote');
      expect(note.label, 'Uzak ekran');
      expect(note.detail, '3840×2160 · %38 ölçekte');
      expect(scale.summary, 'Pencereye sığdır · %38');
    });

    test('not known yet: no row, plain summary', () {
      final b = FakeBackend()..viewScalePercent = null;
      final scale = senseDisplayList(b).sections.firstWhere((s) => s.id == 'scale');
      expect(scale.entries.map((e) => e.id), isNot(contains('display.scaleNote')));
      expect(scale.summary, 'Pencereye sığdır');
    });
  });

  test('still no "Taraf değiştir" (#68-2)', () {
    for (final e in entriesOf(FakeBackend()).values) {
      expect(e.label, isNot(contains('Taraf')));
      expect(e.rustdesk, isNot(contains('Switch Sides')));
    }
  });
}
