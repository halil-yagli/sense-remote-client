// Sense Remote (Sürüm 12, FO-A5, #157): the session's terminal popup — the admin terminal's
// second step in the locked popup layout (prototype `termHTML` st 'ask': "Henüz açılmadı",
// "Yönetici yetkisiyle açılacak", Bilgisayar · Yetki · Denetim kaydı, "Dikkat", Vazgeç /
// Yönetici olarak aç). Golden made on CI (sense-golden.yml); skipped until it exists.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/session/popups/terminal/terminal_popup.dart';
import 'package:flutter_hbb/sense/strings/terminal.dart';

const String _dir = 'test/goldens/terminal';
String _file(String name) => '../../goldens/terminal/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_dir/$name.png').existsSync();

const _pc = 'Giriş Salonu PC-2';

Widget _app(Widget child, {Size size = const Size(560, 640)}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: true),
        child: ColoredBox(color: SenseColors.bg, child: child),
      ),
    );

void main() {
  testWidgets('normal terminal: no popup, the window opens at once', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_app(Builder(
      builder: (context) => GestureDetector(
        key: const Key('open'),
        onTap: () => senseShowTerminalPopup(context, admin: false, computer: _pc, onOpen: () => opened++),
        child: const SizedBox.expand(),
      ),
    )));
    await tester.tap(find.byKey(const Key('open')));
    expect(opened, 1);
  });

  testWidgets('admin: the popup asks first; Yönetici olarak aç opens and closes it', (tester) async {
    final controller = SensePopupController();
    var opened = 0;
    await tester.pumpWidget(_app(SensePopupHost(
      controller: controller,
      child: Builder(
        builder: (context) => GestureDetector(
          key: const Key('open'),
          onTap: () => senseShowTerminalPopup(context,
              admin: true, computer: _pc, peerId: null, onOpen: () => opened++),
          child: const SizedBox.expand(),
        ),
      ),
    )));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(controller.isOpenWith(SenseTerminalStrings.popupId), isTrue);
    expect(opened, 0);
    expect(find.text(SenseTerminalStrings.adminWillOpen), findsOneWidget);
    expect(find.text(_pc), findsOneWidget);
    expect(find.text(SenseTerminalStrings.attentionNote), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-term-popup-go')));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(controller.isOpen, isFalse);
  });

  testWidgets('admin: Vazgeç closes without opening', (tester) async {
    var opened = 0, closed = 0;
    await tester.pumpWidget(_app(SenseTerminalPopup(
      computer: _pc,
      onClose: () => closed++,
      onOpenAdmin: () => opened++,
    )));
    await tester.tap(find.byKey(const Key('sense-term-popup-cancel')));
    expect([opened, closed], [0, 1]);
  });

  const name = 'terminal_popup_admin';
  testWidgets('golden: admin terminal second step', (tester) async {
    tester.view.physicalSize = const Size(560, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(RepaintBoundary(
      key: const Key('golden'),
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            width: SenseSizes.popupWidth,
            child: SenseTerminalPopup(computer: _pc, onClose: () {}, onOpenAdmin: () {}),
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file(name)));
  }, skip: _skip(name), tags: const ['golden']);
}
