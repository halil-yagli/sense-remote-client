// Sense Remote (Sürüm 12, #164): fake session for the connecting card tests (no device).
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/session/layers/connect_cards.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeConnectHost implements SenseConnectHost {
  @override
  String peerName = 'Galeri kioskı';
  @override
  bool connected = false;
  @override
  bool layerOwnsScreen = false;
  @override
  int step = 0;
  @override
  bool trustAvailable = true;
  bool rememberedValue = false;

  final calls = <String>[];

  @override
  Future<bool> remembered() async => rememberedValue;

  @override
  void login(String password, bool remember) => calls.add('login:${password.length}:$remember');

  @override
  void send2fa(String code, bool trust) => calls.add('2fa:$code:$trust');

  @override
  void retry() => calls.add('retry');

  SensePanelInfo? panel;

  @override
  Future<SensePanelInfo?> panelInfo() async {
    panelAsked++;
    return panel;
  }

  int panelAsked = 0;

  @override
  void close() => calls.add('close');
}

/// The connection window size the cards are drawn on (T9 smallest target).
Future<void> pumpCard(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: senseTheme(),
    darkTheme: senseTheme(),
    themeMode: kSenseThemeMode,
    builder: (context, w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: w!,
    ),
    home: Scaffold(
      body: RepaintBoundary(
        key: const Key('golden'),
        child: Stack(children: [
          const Positioned.fill(child: SenseGlowScene(style: SenseGlowStyle.scene)),
          Positioned.fill(child: child),
        ]),
      ),
    ),
  ));
  await tester.pump();
}
