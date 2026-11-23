// Sense Remote: the real chain tab controller -> SenseSessionTabFrame -> RemotePage with a
// fake bridge (no device). Guards the Mac "grey remote screen" bug: the frame laid the pages
// out differently in its first frame (no session yet) and later frames, so RemotePage was
// rebuilt, the first instance's dispose deleted the shared state and the second one failed
// with `"RxString" not found`. Also guards B2 (loose Stack in SensePopupHost).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show MyTheme, SessionID;
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart' show RemotePage;
import 'package:flutter_hbb/desktop/widgets/remote_toolbar.dart' show ToolbarState;
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/model.dart' show FFI;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/sense/components/popup_host.dart';
import 'package:flutter_hbb/sense/screens/session/bar/sense_session_host.dart';
import 'package:flutter_hbb/sense/screens/session/bar/session_popups.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'bind_defaults.g.dart';

class _FakeBind extends Fake implements RustdeskImpl {
  @override
  String translate({required String name, required String locale, dynamic hint}) => name;

  @override
  Stream<EventToUI> sessionStart({required SessionID sessionId, required String id, dynamic hint}) =>
      const Stream<EventToUI>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString().split('"')[1];
    final make = kBindDefaults[name];
    if (make == null) throw UnimplementedError('fake bridge: $name');
    return make();
  }
}

class _Pages extends StatelessWidget {
  const _Pages(this.controller);
  final DesktopTabController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() => PageView(
          controller: controller.state.value.pageController,
          physics: const NeverScrollableScrollPhysics(),
          children: [for (final t in controller.state.value.tabs) t.page],
        ));
  }
}

TabInfo _tab(DesktopTabController c, String id) => TabInfo(
      key: id,
      label: id,
      page: RemotePage(
        key: ValueKey(id),
        id: id,
        toolbarState: ToolbarState(),
        tabController: c,
      ),
    );

int _disposed(List<String> logs) => logs.where((l) => l.contains('REMOTE PAGE dispose')).length;

void main() {
  testWidgets('RemotePage is built once and keeps its shared state; a tab switch rebuilds nothing',
      (tester) async {
    platformFFI.setBindingForTesting(_FakeBind());
    final logs = <String>[];
    final oldPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) logs.add(m);
    };
    addTearDown(() => debugPrint = oldPrint);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = DesktopTabController(tabType: DesktopTabType.remoteScreen);
    controller.add(_tab(controller, 'peerA'));
    await tester.pumpWidget(MaterialApp(
      theme: MyTheme.darkTheme,
      home: Scaffold(
        body: SenseSessionTabFrame(controller: controller, child: _Pages(controller)),
      ),
    ));

    final first = tester.state(find.byType(RemotePage));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(identical(tester.state(find.byType(RemotePage)), first), isTrue,
        reason: 'the first two frames must keep one RemotePage state');
    expect(_disposed(logs), 0, reason: 'no RemotePage dispose while the tab is open');
    expect(Get.isRegistered<FFI>(tag: 'peerA'), isTrue);
    expect(() => FingerprintState.find('peerA'), returnsNormally);
    expect(() => CurrentDisplayState.find('peerA'), returnsNormally);
    expect(find.byKey(const ValueKey('sense-bar-slot')), findsOneWidget,
        reason: 'the Sense frame is reached');

    // A second tab, then back and forth: sessions are not rebuilt. (The controller moves the
    // page 100 ms after a jump, so the test lets that time pass.)
    Future<void> settle() => tester.pump(const Duration(milliseconds: 150));
    String why(String step) => '$step: ' + logs.where((l) => l.contains('REMOTE PAGE dispose')).join(' | ');
    controller.add(_tab(controller, 'peerB'));
    await tester.pump(const Duration(milliseconds: 50));
    await settle();
    expect(_disposed(logs), 0, reason: why('after adding the second tab'));
    controller.jumpTo(1);
    await settle();
    await settle();
    expect(_disposed(logs), 0, reason: why('after switching to the second tab'));
    controller.jumpTo(0);
    await settle();
    await settle();
    expect(_disposed(logs), 0, reason: why('after switching back'));
    expect(identical(tester.state(find.byType(RemotePage).first), first), isTrue);
    expect(Get.isRegistered<FFI>(tag: 'peerA'), isTrue);
    expect(Get.isRegistered<FFI>(tag: 'peerB'), isTrue);
    expect(tester.takeException(), isNull);

    // Teardown: close the tabs the way the window does.
    controller.clear();
    await tester.pump(const Duration(milliseconds: 50));
    SenseSessionPopups.remove('peerA');
    SenseSessionPopups.remove('peerB');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('SensePopupHost in a loose Stack still gives its child the full area (B2)', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 400,
          height: 300,
          child: Stack(children: [
            SensePopupHost(controller: SensePopupController(), child: SizedBox.expand(key: key)),
          ]),
        ),
      ),
    ));
    expect(tester.getSize(find.byKey(key)), const Size(400, 300));
  });
}
