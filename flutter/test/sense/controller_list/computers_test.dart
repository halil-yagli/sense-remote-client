// Sense Remote: "Bilgisayarlar" behaviour (plan B3; YH C2 and its acceptance
// tests): header, number tiles, location filter, one open group, tiles and
// their buttons (Bağlan / Yine de dene / Meşgul / Yetkin yok / Bağlanıyor…),
// LED box, Kimlikle bağlan in place, the four states, personal order.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/computer_tile.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/computers_view.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/project_group.dart';
import 'package:flutter_hbb/sense/screens/controller/data/peers.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Future<List<String>> _pumpList(
  WidgetTester tester, {
  List<SenseProject>? projects,
  SenseListState state = SenseListState.ready,
  SenseHealthCache? health,
  bool canConnect = true,
  bool grantsMissing = false,
  String? connecting,
  void Function(SenseProject, List<String>)? onTileOrder,
  void Function(List<String>)? onGroupOrder,
  VoidCallback? onRetry,
  String? ledOpenId,
}) async {
  final connected = <String>[];
  setWindow(tester, const Size(1180, 1400));
  await tester.pumpWidget(app(page(SenseComputersView(
    projects: projects ?? exampleProjects(),
    state: state,
    now: kNow,
    health: health,
    canConnect: canConnect,
    grantsMissing: grantsMissing,
    connectingId: connecting,
    onConnect: connected.add,
    onRetry: onRetry,
    ledOpenId: ledOpenId,
    onTileOrder: onTileOrder,
    onGroupOrder: onGroupOrder,
  ))));
  await tester.pump();
  return connected;
}

Finder _tile(String id) => find.byKey(ValueKey('sense-tile-prj_muze-$id'));

void main() {
  group('header and tiles', () {
    testWidgets('title, panel line, search, Kimlikle bağlan; four number tiles', (tester) async {
      await _pumpList(tester, health: exampleHealth());
      expect(find.text('Bilgisayarlar'), findsOneWidget);
      expect(find.text('Panel bağlı · 6/8 çevrimiçi'), findsOneWidget);
      expect(find.byKey(const Key('sense-list-search')), findsOneWidget);
      expect(find.text('Kimlikle bağlan'), findsOneWidget);
      String value(String key) => (tester
              .widget<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)).last))
          .data!;
      expect(value('sense-count-online'), '6');
      expect(value('sense-count-offline'), '2');
      expect(value('sense-count-attention'), '2');
      expect(value('sense-count-projects'), '3');
    });

    testWidgets('first group open, the others closed; one open at a time', (tester) async {
      await _pumpList(tester);
      expect(_tile('482913207'), findsOneWidget);
      expect(find.byKey(const ValueKey('sense-tile-prj_fuar-482913212')), findsNothing);
      expect(find.text('4 çevrimiçi · 1 kapalı'), findsOneWidget);
      expect(find.text('1 çevrimiçi · 1 kapalı'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-group-head-prj_fuar')));
      await tester.pump();
      expect(find.byKey(const ValueKey('sense-tile-prj_fuar-482913212')), findsOneWidget);
      expect(_tile('482913207'), findsNothing, reason: 'tek açık');
      await tester.tap(find.byKey(const Key('sense-group-head-prj_fuar')));
      await tester.pump();
      expect(find.byKey(const ValueKey('sense-tile-prj_fuar-482913212')), findsNothing);
    });

    testWidgets('location filter: only that place, groups open; Tümü back', (tester) async {
      await _pumpList(tester);
      await tester.tap(find.byKey(const Key('sense-loc-Lobi')));
      await tester.pump();
      expect(_tile('482913207'), findsOneWidget);
      expect(_tile('482913211'), findsOneWidget);
      expect(_tile('482913208'), findsNothing);
      expect(find.text('1 çevrimiçi · 1 kapalı'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-loc-all')));
      await tester.pump();
      expect(_tile('482913208'), findsOneWidget);
    });

    testWidgets('search narrows; no result offers Aramayı temizle', (tester) async {
      await _pumpList(tester);
      await tester.enterText(find.descendant(of: find.byKey(const Key('sense-list-search')), matching: find.byType(TextField)), 'stand');
      await tester.pump();
      expect(find.byKey(const ValueKey('sense-tile-prj_fuar-482913214')), findsOneWidget, reason: 'groups open while searching');
      await tester.enterText(find.descendant(of: find.byKey(const Key('sense-list-search')), matching: find.byType(TextField)), 'zzz');
      await tester.pump();
      expect(find.text('“zzz” için bilgisayar yok'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-list-clear')));
      await tester.pump();
      expect(find.byKey(const Key('sense-list-nomatch')), findsNothing);
      expect(_tile('482913207'), findsOneWidget);
    });
  });

  group('tiles', () {
    testWidgets('online: white Bağlan connects; offline: Yine de dene still tries', (tester) async {
      final connected = await _pumpList(tester);
      await tester.tap(find.byKey(const Key('sense-tile-connect-482913207')));
      await tester.tap(find.byKey(const Key('sense-tile-connect-482913211')));
      expect(connected, ['482913207', '482913211']);
      expect(find.text('Yine de dene'), findsOneWidget);
      expect(find.text('Son görülme 3 gün önce'), findsOneWidget);
      expect(find.text('kapalı'), findsOneWidget);
      expect(find.text('Lobi · 3 ekran'), findsOneWidget);
    });

    testWidgets('kabul C2: a busy computer can not be connected to', (tester) async {
      final connected = await _pumpList(tester);
      expect(find.text('Meşgul · Mevlüt bağlı'), findsOneWidget);
      final busy = find.byKey(const Key('sense-tile-busy-482913210'));
      expect(busy, findsOneWidget);
      await tester.tap(busy, warnIfMissed: false);
      await tester.pump();
      expect(connected, isEmpty);
      expect(find.byKey(const Key('sense-tile-connect-482913210')), findsNothing);
    });

    testWidgets('kabul C2: no online dot; the LED is the only light', (tester) async {
      await _pumpList(tester, health: exampleHealth());
      expect(find.text('Çevrimiçi'), findsWidgets);
      // One LED per tile of the open group, nothing else round and lit.
      expect(find.byType(SenseLed), findsNWidgets(5));
      final led = tester.widget<SenseLed>(find.byKey(const Key('sense-led-482913207')));
      expect(led.level, SenseLevel.hot);
      final off = tester.widget<SenseLed>(find.byKey(const Key('sense-led-482913211')));
      expect(off.level, SenseLevel.unknown, reason: 'kapalı: içi boş halka');
    });

    testWidgets('Bağlanıyor… while the window opens', (tester) async {
      await _pumpList(tester, connecting: '482913207');
      expect(find.byKey(const Key('sense-tile-connecting-482913207')), findsOneWidget);
      expect(find.text('Bağlanıyor…'), findsOneWidget);
    });

    testWidgets('grants: without connect Bağlan is locked "Yetkin yok"', (tester) async {
      final connected = await _pumpList(tester, canConnect: false, grantsMissing: true);
      expect(find.text('Yetkiler panelden alınamadı'), findsOneWidget);
      expect(find.byKey(const Key('sense-tile-connect-482913207')), findsNothing);
      await tester.tap(find.byKey(const Key('sense-tile-noright-482913207')), warnIfMissed: false);
      expect(connected, isEmpty);
    });

    testWidgets('LED box opens on hover with the values and goes away', (tester) async {
      await _pumpList(tester, health: exampleHealth());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byKey(const Key('sense-led-482913207'))));
      await tester.pump();
      expect(find.byKey(const Key('sense-health-482913207')), findsOneWidget);
      expect(find.text('Dikkat gerekiyor'), findsOneWidget);
      expect(find.text('%96'), findsOneWidget);
      expect(find.text('Son veri 8 sn önce · panel'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(find.byKey(const Key('sense-health-482913207')), findsNothing);
    });

    test('tile action and status', () {
      final busy = pc('1', 'A', busy: 'Mevlüt');
      expect(senseTileAction(busy, connecting: false, canConnect: true), SenseTileAction.busy);
      expect(senseTileAction(pc('2', 'B'), connecting: true, canConnect: true), SenseTileAction.connecting);
      expect(senseTileAction(pc('2', 'B'), connecting: false, canConnect: false), SenseTileAction.noRight);
      expect(senseTileAction(pc('3', 'C', online: false), connecting: false, canConnect: true),
          SenseTileAction.tryAnyway);
      expect(senseTileStatus(pc('3', 'C', online: false), kNow), 'Kapalı');
      expect(senseTileSubtitle(pc('4', 'D')), '');
    });
  });

  group('Kimlikle bağlan, in place', () {
    testWidgets('opens under the header; a valid ID connects, a wrong one says so', (tester) async {
      final connected = await _pumpList(tester);
      await tester.tap(find.byKey(const Key('sense-list-id')));
      await tester.pump();
      expect(find.byKey(const Key('sense-id-box')), findsOneWidget);
      final field = find.descendant(of: find.byKey(const Key('sense-id-field')), matching: find.byType(TextField));
      await tester.enterText(field, '12');
      await tester.tap(find.byKey(const Key('sense-id-connect')));
      await tester.pump();
      expect(find.text('Kimlik 6–12 rakam olmalı.'), findsOneWidget);
      await tester.enterText(field, '482 913 207');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(connected, ['482913207']);
      await tester.tap(find.byKey(const Key('sense-list-id')));
      await tester.pump();
      expect(find.byKey(const Key('sense-id-box')), findsNothing);
    });
  });

  group('states', () {
    testWidgets('loading', (tester) async {
      await _pumpList(tester, projects: const [], state: SenseListState.loading);
      expect(find.text('Bilgisayarlar panelden alınıyor…'), findsOneWidget);
      expect(find.byKey(const Key('sense-list-live')), findsNothing);
    });

    testWidgets('error: Yeniden dene and Kimlikle bağlan', (tester) async {
      var retried = 0;
      await _pumpList(tester, projects: const [], state: SenseListState.error, onRetry: () => retried++);
      expect(find.text('Liste panelden alınamadı'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-list-retry')));
      expect(retried, 1);
      await tester.tap(find.byKey(const Key('sense-list-error-id')));
      await tester.pump();
      expect(find.byKey(const Key('sense-id-box')), findsOneWidget);
    });

    testWidgets('error: Yeniden dene is the primary (enabled) button', (tester) async {
      await _pumpList(tester, projects: const [], state: SenseListState.error, onRetry: () {});
      final retry = tester.widget<SenseButton>(find.byKey(const Key('sense-list-retry')));
      expect(retry.kind, SenseButtonKind.primary);
      expect(retry.onPressed, isNotNull);
    });

    testWidgets('a02: the LED box opens without a pointer (initial state of the golden)', (tester) async {
      await _pumpList(tester, health: exampleHealth(), ledOpenId: '482913207');
      await tester.pump();
      await tester.pump();
      expect(find.text('Dikkat gerekiyor'), findsOneWidget);
      expect(find.textContaining('Son veri'), findsWidgets);
    });

    testWidgets('empty', (tester) async {
      await _pumpList(tester, projects: const []);
      expect(find.text('Hesabına atanmış bilgisayar yok'), findsOneWidget);
    });
  });

  group('personal order', () {
    testWidgets('a tile dropped on another goes in front of it (same project)', (tester) async {
      final orders = <(String, List<String>)>[];
      await _pumpList(tester, onTileOrder: (p, ids) => orders.add((p.id, ids)));
      final from = tester.getCenter(find.descendant(
          of: _tile('482913209'), matching: find.byKey(const Key('sense-tile-status-482913209'))));
      final to = tester.getCenter(_tile('482913207'));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(orders.length, 1);
      expect(orders.single.$1, 'prj_muze');
      expect(orders.single.$2.take(2), ['482913209', '482913207']);
    });

    testWidgets('group order: grip drag reorders the projects', (tester) async {
      final orders = <List<String>>[];
      await _pumpList(tester, onGroupOrder: orders.add);
      final from = tester.getCenter(find.byKey(const Key('sense-group-grip-prj_ofis')));
      final to = tester.getCenter(find.byKey(const Key('sense-group-head-prj_muze')));
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 10)!);
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(orders.single, ['prj_ofis', 'prj_muze', 'prj_fuar']);
    });

    test('grid columns follow the width (auto-fill, 210 px)', () {
      expect(senseGridColumns(910, 210), 4);
      expect(senseGridColumns(100, 210), 1);
    });
  });
}
