// Sense Remote (C5): golden images of the Host-side Sense icon and card, to
// compare with Calisma/dokuman/img/h01.png (icon), h02.png (card: recording,
// who, incoming call, chat), h04.png (edge tab) and h05.png (card in a call;
// voice only, no video area — #67). The desktop is drawn as the glow scene.
// Images are made on CI (sense-golden.yml); until one exists its test is
// skipped, not failed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/host_live/data/overlay.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_geometry.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_page.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_controller.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_entry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support.dart' show FakeCall, app, c08Controller, job, setWindow;

const String kGoldenDir = 'test/goldens/host_live';

String goldenFile(String name) => '../../goldens/host_live/$name.png';

bool goldenSkip(String name) =>
    !autoUpdateGoldenFiles && !File('$kGoldenDir/$name.png').existsSync();

const stage = Size(1280, 800);

Client halil() {
  final c = Client(1, true, false, false, 'Halil Y.', '123456789', true, false, false)
    ..file = true;
  return c;
}

Widget desk(List<Widget> children) => app(
      RepaintBoundary(
        key: const Key('golden'),
        child: SizedBox.fromSize(
          size: stage,
          // Own Overlay: the Mikrofon list (overlay) is in the image too.
          child: Overlay(initialEntries: [
            OverlayEntry(
              builder: (_) => Stack(children: [
                const Positioned.fill(child: SenseGlowScene(style: SenseGlowStyle.scene)),
                ...children,
              ]),
            ),
          ]),
        ),
      ),
      still: true,
    );

/// Stands in for the system file chooser, so the card shows its ataç (h02).
Future<List<String>> _noFiles() async => const <String>[];

Widget card(Client c, SenseChatController chat,
        {Duration? recording, bool attach = true, String? connectionsLine}) =>
    Positioned(
      right: kSenseCmMargin,
      bottom: kSenseCmMargin,
      width: kSenseCmPanelSize.width,
      height: kSenseCmPanelSize.height,
      child: SenseHostCard(
        client: c,
        chat: chat,
        whoLine: senseHostWhoLine(c, const Duration(minutes: 14)),
        connectionsLine: connectionsLine,
        recording: recording,
        pickFiles: attach ? _noFiles : null,
        animateIn: false,
        actions: SenseHostCardActions(
          onMinimize: () {},
          onEnd: () {},
          onAccept: () {},
          onReject: () {},
          onCloseEnded: () {},
          onAnswerCall: (_) {},
        ),
      ),
    );

void main() {
  testWidgets('h01: the icon and its states', (tester) async {
    setWindow(tester, stage);
    Widget at(double right, Widget icon) =>
        Positioned(right: right, bottom: kSenseCmMargin, child: icon);
    await tester.pumpWidget(desk([
      at(kSenseCmMargin, SenseHostIcon(onTap: () {})),
      at(120, SenseHostIcon(onTap: () {}, unread: 2)),
      at(220, SenseHostIcon(onTap: () {}, inCall: true)),
      at(320, SenseHostIcon(onTap: () {}, transferring: true)),
      at(420, SenseHostIcon(onTap: () {}, recording: true)),
    ]));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('h01_icon')));
  }, skip: goldenSkip('h01_icon'), tags: const ['golden']);

  testWidgets('h02: card with recording, incoming call and chat', (tester) async {
    setWindow(tester, stage);
    final chat = c08Controller();
    chat.setPhase(SenseCallPhase.incoming);
    await tester.pumpWidget(desk([
      card(halil(), chat, recording: const Duration(minutes: 1, seconds: 15)),
    ]));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('h02_card')));
  }, skip: goldenSkip('h02_card'), tags: const ['golden']);

  testWidgets('h04: icon hidden at the right edge', (tester) async {
    setWindow(tester, stage);
    await tester.pumpWidget(desk([
      Positioned(
        right: 0,
        top: 360,
        child: SenseHostEdgeTab(edge: SenseCmEdge.right, onTap: () {}),
      ),
      Positioned(
        left: 0,
        top: 360,
        child: SenseHostEdgeTab(edge: SenseCmEdge.left, onTap: () {}),
      ),
    ]));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('h04_edge')));
  }, skip: goldenSkip('h04_edge'), tags: const ['golden']);

  testWidgets('h05: card in a voice call, Mikrofon list open, a file going out', (tester) async {
    setWindow(tester, stage);
    final chat = c08Controller(call: FakeCall(levelValue: 0.46));
    chat.applyJobs([
      job('u1', 'takilma_ekran2.mp4', SenseFileDir.out, done: 90500000, total: 184000000),
    ]);
    chat.setPhase(SenseCallPhase.active);
    await tester.pumpWidget(desk([card(halil(), chat)]));
    await tester.pump(const Duration(milliseconds: 400));
    // Mikrofon list open (golden report: devices, level, output, Mikrofonu kapat).
    await tester.tap(find.byKey(const Key('sense-mic-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('h05_call')));
  }, skip: goldenSkip('h05_call'), tags: const ['golden']);

  testWidgets('h06: same Controller on the screen and a terminal (O6)', (tester) async {
    setWindow(tester, stage);
    final screen = halil();
    final terminal = Client(2, true, false, false, 'Halil Y.', '123456789', false, false, false)
      ..isTerminal = true;
    await tester.pumpWidget(desk([
      card(screen, c08Controller(),
          connectionsLine: senseHostConnectionsLine(senseHostLive([screen, terminal]))),
    ]));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('h06_two')));
  }, skip: goldenSkip('h06_two'), tags: const ['golden']);
}
