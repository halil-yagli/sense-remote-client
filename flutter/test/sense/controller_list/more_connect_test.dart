// Sense Remote (Paket C, R6): the "⋯" menu of a computer tile opens the computer
// for Dosya aktarımı / Terminal / TCP tünel without opening its screen; each
// entry follows the person's grants.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/computers_page.dart' show senseKindAllowed;
import 'package:flutter_hbb/sense/screens/controller/computers/computers_view.dart';
import 'package:flutter_hbb/sense/screens/controller/computers/tile_more.dart';
import 'package:flutter_hbb/sense/screens/controller/data/grants.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Future<List<String>> _pump(
  WidgetTester tester, {
  bool file = true,
  bool terminal = true,
  bool canConnect = true,
  bool withCallback = true,
}) async {
  final picked = <String>[];
  setWindow(tester, const Size(1180, 1400));
  await tester.pumpWidget(app(page(SenseComputersView(
    projects: exampleProjects(),
    now: kNow,
    canConnect: canConnect,
    canFileTransfer: file,
    canTerminalTunnel: terminal,
    onConnect: (_) {},
    onConnectKind: withCallback ? (id, k) => picked.add('$id:${k.name}') : null,
  ))));
  await tester.pump();
  return picked;
}

const _online = '482913207';
const _busy = '482913210';

void main() {
  test('entries follow the grants', () {
    expect(senseMoreKinds(fileTransfer: true, terminalTunnel: true),
        [SenseConnectKind.fileTransfer, SenseConnectKind.terminal, SenseConnectKind.tcpTunnel]);
    expect(senseMoreKinds(fileTransfer: true, terminalTunnel: false), [SenseConnectKind.fileTransfer]);
    expect(senseMoreKinds(fileTransfer: false, terminalTunnel: true),
        [SenseConnectKind.terminal, SenseConnectKind.tcpTunnel]);
    expect(senseMoreKinds(fileTransfer: false, terminalTunnel: false), isEmpty);
  });

  test('senseKindAllowed needs the grant and a valid envelope', () {
    const ok = SenseGrants(state: SenseGrantsState.ok, perms: {SensePerm.connect, SensePerm.fileTransfer});
    expect(senseKindAllowed(SenseConnectKind.fileTransfer, ok), isTrue);
    expect(senseKindAllowed(SenseConnectKind.terminal, ok), isFalse);
    expect(senseKindAllowed(SenseConnectKind.tcpTunnel, ok), isFalse);
    expect(senseKindAllowed(SenseConnectKind.fileTransfer, SenseGrants.missing), isFalse);
  });

  testWidgets('the menu lists the three ways and each opens its kind', (tester) async {
    final picked = await _pump(tester);
    expect(find.byKey(const Key('sense-tile-more-menu-$_online')), findsNothing);
    for (final kind in ['fileTransfer', 'terminal', 'tcpTunnel']) {
      await tester.tap(find.byKey(const Key('sense-tile-more-$_online')));
      await tester.pump();
      expect(find.text('Dosya aktarımı'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.text('TCP tünel'), findsOneWidget);
      await tester.tap(find.byKey(Key('sense-tile-more-$kind-$_online')));
      await tester.pump();
      expect(find.byKey(const Key('sense-tile-more-menu-$_online')), findsNothing, reason: 'menu closes');
    }
    expect(picked, ['$_online:fileTransfer', '$_online:terminal', '$_online:tcpTunnel']);
  });

  testWidgets('a tap outside closes the menu without opening anything', (tester) async {
    final picked = await _pump(tester);
    await tester.tap(find.byKey(const Key('sense-tile-more-$_online')));
    await tester.pump();
    expect(find.byKey(const Key('sense-tile-more-menu-$_online')), findsOneWidget);
    await tester.tapAt(const Offset(5, 1300));
    await tester.pump();
    expect(find.byKey(const Key('sense-tile-more-menu-$_online')), findsNothing);
    expect(picked, isEmpty);
  });

  testWidgets('only the allowed entries are shown', (tester) async {
    await _pump(tester, terminal: false);
    await tester.tap(find.byKey(const Key('sense-tile-more-$_online')));
    await tester.pump();
    expect(find.text('Dosya aktarımı'), findsOneWidget);
    expect(find.text('Terminal'), findsNothing);
    expect(find.text('TCP tünel'), findsNothing);
  });

  testWidgets('no grant, no menu; busy and locked computers have none', (tester) async {
    await _pump(tester, file: false, terminal: false);
    expect(find.byKey(const Key('sense-tile-more-$_online')), findsNothing);
    await _pump(tester, canConnect: false);
    expect(find.byKey(const Key('sense-tile-more-$_online')), findsNothing);
    await _pump(tester);
    expect(find.byKey(const Key('sense-tile-more-$_busy')), findsNothing, reason: 'Meşgul: tek kişi');
    await _pump(tester, withCallback: false);
    expect(find.byKey(const Key('sense-tile-more-$_online')), findsNothing);
  });
}
