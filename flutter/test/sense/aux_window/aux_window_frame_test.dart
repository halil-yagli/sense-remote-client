// Sense Remote (S12 UD-a, ST 15, 16): the shared Sense frame of the secondary windows.
// Behaviour + goldens (compared with the prototype `.fmt` / `.axtabs`, "Uzak dosyalar"
// and "S12 — terminal ve TCP tünel" sections). Images are made on CI (sense-golden.yml);
// until one exists its test is skipped.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/shared/aux_window/aux_label.dart';
import 'package:flutter_hbb/sense/screens/shared/aux_window/aux_menu.dart';
import 'package:flutter_hbb/sense/screens/shared/aux_window/aux_window_frame.dart';
import 'package:flutter_hbb/sense/strings/files.dart';

const String _dir = 'test/goldens/aux_window';
String _file(String name) => '../../goldens/aux_window/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_dir/$name.png').existsSync();

Widget _app(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: const MediaQueryData(size: Size(900, 300), disableAnimations: true),
        child: ColoredBox(color: SenseColors.bg, child: child),
      ),
    );

void main() {
  group('names without the ID (ST 16)', () {
    test('alias first, then host name, then "Uzak bilgisayar"', () {
      final peer = jsonEncode({
        'info': {'hostname': 'GIRIS-PC2', 'username': 'x'}
      });
      expect(senseAuxLabelFrom(alias: 'Giriş Salonu PC-2', peerJson: peer), 'Giriş Salonu PC-2');
      expect(senseAuxLabelFrom(alias: '  ', peerJson: peer), 'GIRIS-PC2');
      expect(senseAuxLabelFrom(alias: '', peerJson: '{}'), SenseAuxStrings.unnamedComputer);
      expect(senseAuxLabelFrom(alias: '', peerJson: 'not json'), SenseAuxStrings.unnamedComputer);
    });

    test('window title is Turkish and has no ID', () {
      expect(SenseAuxStrings.windowTitle(SenseFilesStrings.title, 'Giriş Salonu PC-2', 'Sense Remote'),
          'Uzak dosyalar · Giriş Salonu PC-2 — Sense Remote');
    });
  });

  group('frame', () {
    testWidgets('title, subject and live line; window buttons call back', (tester) async {
      var min = 0, max = 0, close = 0, drag = 0;
      await tester.pumpWidget(_app(SenseAuxWindowFrame(
        title: SenseFilesStrings.title,
        subject: 'Giriş Salonu PC-2',
        live: const SenseAuxLive('Doğrudan · ekran açılmadı', SenseLevel.ok),
        actions: SenseAuxWindowActions(
          onMinimize: () => min++,
          onToggleMaximize: () => max++,
          onClose: () => close++,
          onDragStart: () => drag++,
        ),
        child: const SizedBox.expand(),
      )));
      expect(find.text('Uzak dosyalar · Giriş Salonu PC-2', findRichText: true), findsOneWidget);
      expect(find.text('Doğrudan · ekran açılmadı'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-aux-minimize')));
      await tester.tap(find.byKey(const Key('sense-aux-maximize')));
      await tester.tap(find.byKey(const Key('sense-aux-close')));
      await tester.drag(find.byKey(const Key('sense-aux-drag')), const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 500)); // double-tap timer
      expect([min, max, close], [1, 1, 1]);
      expect(drag, 1);
    });

    testWidgets('no tab row with one tab; with two, select and close work', (tester) async {
      var selected = -1, closed = -1;
      Widget frame(List<SenseAuxTab> tabs) => _app(SenseAuxWindowFrame(
            title: SenseFilesStrings.title,
            tabs: tabs,
            onSelectTab: (i) => selected = i,
            onCloseTab: (i) => closed = i,
            child: const SizedBox.expand(),
          ));
      await tester.pumpWidget(frame(const [SenseAuxTab(key: 'a', label: 'Giriş PC')]));
      expect(find.byKey(const Key('sense-aux-tab-a')), findsNothing);

      await tester.pumpWidget(frame(const [
        SenseAuxTab(key: 'a', label: 'Giriş PC'),
        SenseAuxTab(key: 'b', label: 'Kubbe PC'),
      ]));
      await tester.tap(find.byKey(const Key('sense-aux-tab-b')));
      await tester.tap(find.byKey(const Key('sense-aux-tab-close-a')));
      expect(selected, 1);
      expect(closed, 0);
    });

    testWidgets('tab menu opens on right click and runs the item', (tester) async {
      var closedOthers = false;
      await tester.pumpWidget(_app(SenseAuxWindowFrame(
        title: 'Terminal',
        tabs: const [SenseAuxTab(key: 'a', label: 'Terminal 1'), SenseAuxTab(key: 'b', label: 'Terminal 2')],
        tabMenu: (i) => [
          SenseAuxMenuItem(label: SenseAuxStrings.closeOtherTabs, onTap: () => closedOthers = true),
        ],
        child: const SizedBox.expand(),
      )));
      await tester.tap(find.byKey(const Key('sense-aux-tab-a')), buttons: kSecondaryButton);
      await tester.pump();
      expect(find.text(SenseAuxStrings.closeOtherTabs), findsOneWidget);
      await tester.tap(find.text(SenseAuxStrings.closeOtherTabs));
      await tester.pump();
      expect(closedOthers, isTrue);
      expect(find.text(SenseAuxStrings.closeOtherTabs), findsNothing);
    });
  });

  group('goldens', () {
    Future<void> shoot(WidgetTester tester, String name, Widget frame) async {
      tester.view.physicalSize = const Size(900, 200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(RepaintBoundary(key: const Key('golden'), child: frame)));
      await tester.pump();
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file(name)));
    }

    const name1 = 'aux_frame_files';
    testWidgets('golden: files frame, one tab', (tester) async {
      await shoot(
          tester,
          name1,
          SenseAuxWindowFrame(
            title: SenseFilesStrings.title,
            subject: 'Giriş Salonu PC-2',
            live: const SenseAuxLive('Doğrudan · ekran açılmadı', SenseLevel.ok),
            actions: SenseAuxWindowActions(onMinimize: () {}, onToggleMaximize: () {}, onClose: () {}),
            child: const SizedBox.expand(),
          ));
    }, skip: _skip(name1), tags: const ['golden']);

    const name2 = 'aux_frame_tabs';
    testWidgets('golden: terminal frame, two tabs and +', (tester) async {
      await shoot(
          tester,
          name2,
          SenseAuxWindowFrame(
            title: 'Terminal',
            subject: 'Giriş Salonu PC-2',
            live: const SenseAuxLive(SenseAuxStrings.connecting, SenseLevel.unknown),
            tabs: const [SenseAuxTab(key: 'a', label: 'Terminal 1'), SenseAuxTab(key: 'b', label: 'Terminal 2')],
            selectedTab: 1,
            onSelectTab: (_) {},
            onCloseTab: (_) {},
            onNewTab: () {},
            actions: SenseAuxWindowActions(onMinimize: () {}, onToggleMaximize: () {}, onClose: () {}),
            child: const SizedBox.expand(),
          ));
    }, skip: _skip(name2), tags: const ['golden']);
  });
}
