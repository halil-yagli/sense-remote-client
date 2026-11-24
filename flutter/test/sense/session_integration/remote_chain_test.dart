// Sense Remote: the real chain tab controller -> SenseSessionTabFrame -> RemotePage with a
// fake bridge (no device). Guards the Mac "grey remote screen" bug: the frame laid the pages
// out differently in its first frame (no session yet) and later frames, so RemotePage was
// rebuilt, the first instance's dispose deleted the shared state and the second one failed
// with `"RxString" not found`. Also guards B2 (loose Stack in SensePopupHost).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' as common show isTest;
import 'package:flutter_hbb/common.dart' show MyTheme, SessionID;
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart' show RemotePage, senseOrphanGrace;
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

final List<String> _closedSessions = [];

class _FakeBind extends Fake implements RustdeskImpl {
  @override
  Future<void> sessionClose({required SessionID sessionId, dynamic hint}) async {
    _closedSessions.add(sessionId.toString());
  }

  @override
  String translate({required String name, required String locale, dynamic hint}) => name;

  @override
  Stream<EventToUI> sessionStart({required SessionID sessionId, required String id, dynamic hint}) =>
      const Stream<EventToUI>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString().split('"')[1];
    // Answers the models parse as JSON.
    if (name == 'mainGetConnectStatus') return Future<String>.value('{"status_num":0}');
    final make = kBindDefaults[name];
    if (make == null) throw UnimplementedError('fake bridge: $name');
    return make();
  }
}

/// The page view of DesktopTab (tabbar_widget.dart _buildPageView), same list handling: on an
/// added tab the previous list object is reused, so the existing pages are not rebuilt.
class _Pages extends StatefulWidget {
  const _Pages(this.controller);
  final DesktopTabController controller;

  @override
  State<_Pages> createState() => _PagesState();
}

class _PagesState extends State<_Pages> {
  List<Widget> _tabWidgets = [];

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return Obx(() => PageView(
          controller: state.value.pageController,
          physics: const NeverScrollableScrollPhysics(),
          children: () {
            final tabLen = state.value.tabs.length;
            if (tabLen == _tabWidgets.length) {
              return _tabWidgets;
            } else if (_tabWidgets.isNotEmpty && tabLen == _tabWidgets.length + 1) {
              _tabWidgets.add(state.value.tabs.last.page);
              return _tabWidgets;
            } else {
              _tabWidgets = state.value.tabs.map((v) => v.page).toList();
              return _tabWidgets;
            }
          }(),
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
    // ServerModel starts no 500 ms polling timer in test mode.
    common.isTest = true;
    addTearDown(() => common.isTest = false);
    final logs = <String>[];
    final oldPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m == null) return;
      final trace = StackTrace.current.toString().split('\n').take(16).join('\n');
      logs.add(m.contains('REMOTE PAGE dispose') ? '$m\n$trace' : m);
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
    expect(find.byKey(const ValueKey('sense-bar-empty')), findsNothing,
        reason: 'the session bar replaced the empty placeholder');

    // A second tab, then back and forth: sessions are not rebuilt. (The controller moves the
    // page 100 ms after a jump, so the test lets that time pass.)
    // A page built after the window exists asks for its "connecting" dialog before the fake
    // window has an overlay for it; that known message is not what is tested here.
    final stray = <Object>[];
    Future<void> pumpFor(int ms) async {
      await runZonedGuarded(() => tester.pump(Duration(milliseconds: ms)), (e, st) {
        if (!e.toString().contains('_overlayState is null')) stray.add(e);
      });
    }

    Future<void> settle() => pumpFor(150);
    String why(String step) =>
        '$step: ' + logs.where((l) => l.contains('REMOTE PAGE dispose')).join('\n---\n');
    controller.add(_tab(controller, 'peerB'));
    await pumpFor(50);
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
    expect(stray, isEmpty);

    // The test binding checks foundation variables before tear-down callbacks run.
    debugPrint = oldPrint;

    // Teardown: close the tabs the way the window does.
    controller.clear();
    await tester.pump(const Duration(milliseconds: 50));
    SenseSessionPopups.remove('peerA');
    SenseSessionPopups.remove('peerB');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  Future<DesktopTabController> mountOne(WidgetTester tester, String id) async {
    platformFFI.setBindingForTesting(_FakeBind());
    common.isTest = true;
    addTearDown(() => common.isTest = false);
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _closedSessions.clear();
    final controller = DesktopTabController(tabType: DesktopTabType.remoteScreen);
    controller.add(_tab(controller, id));
    await tester.pumpWidget(MaterialApp(
      theme: MyTheme.darkTheme,
      home: Scaffold(
        body: SenseSessionTabFrame(controller: controller, child: _Pages(controller)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return controller;
  }

  testWidgets('closing the tab closes the session (K12)', (tester) async {
    final controller = await mountOne(tester, 'peerC');
    expect(_closedSessions, isEmpty);
    controller.remove(0);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(_closedSessions, isNotEmpty, reason: 'the session must be closed with its tab');
    expect(Get.isRegistered<FFI>(tag: 'peerC'), isFalse);
    SenseSessionPopups.remove('peerC');
  });

  testWidgets('a page torn down while its tab stays: kept at first, closed after the grace (K12)',
      (tester) async {
    final oldGrace = senseOrphanGrace;
    senseOrphanGrace = const Duration(seconds: 10);
    addTearDown(() => senseOrphanGrace = oldGrace);
    await mountOne(tester, 'peerD');
    // The tree drops the page but the controller still has the tab.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    expect(_closedSessions, isEmpty, reason: 'kept during the grace');
    expect(Get.isRegistered<FFI>(tag: 'peerD'), isTrue);
    await tester.pump(const Duration(seconds: 6));
    expect(_closedSessions, isNotEmpty, reason: 'orphan session closed after the grace');
    expect(Get.isRegistered<FFI>(tag: 'peerD'), isFalse);
    SenseSessionPopups.remove('peerD');
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
