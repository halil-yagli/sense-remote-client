// Sense Remote (C3): golden images of the chat, to compare with
// Calisma/dokuman/img/c08.png, c09.png (voice only: no video area, no camera —
// #67), s08.png and n09.png. The remote screen is drawn as the glow scene so
// the popup sits on the same background as in the prototype.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/components_b.dart';
import 'package:flutter_hbb/sense/screens/session/chat_icon/chat_layer.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_controller.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_entry.dart';

import 'support.dart';

const stage = Size(1600, 900);

/// Stands in for the system file chooser, so the composer shows its ataç (c08).
Future<List<String>> _noFiles() async => const <String>[];

Widget scene(SenseChatController c, {ValueNotifier<bool>? focused}) => app(
      RepaintBoundary(
        key: const Key('golden'),
        child: SizedBox.fromSize(
          size: stage,
          child: Stack(children: [
            const Positioned.fill(child: SenseGlowScene(style: SenseGlowStyle.scene)),
            Positioned.fill(
              child: SenseChatLayer(
                controller: c,
                computerName: 'Giriş Salonu PC-2',
                windowFocused: focused,
                pickFiles: _noFiles,
                animate: false,
              ),
            ),
          ]),
        ),
      ),
      still: true,
    );

void main() {
  testWidgets('c08: chat with messages and files', (tester) async {
    setWindow(tester, stage);
    final c = c08Controller();
    c.open();
    await tester.pumpWidget(scene(c));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('c08_chat')));
  }, skip: goldenSkip('c08_chat'), tags: const ['golden']);

  testWidgets('c09: voice call with the Mikrofon list open', (tester) async {
    setWindow(tester, stage);
    final c = c08Controller(call: FakeCall(levelValue: 0.46));
    c.open();
    await tester.pumpWidget(scene(c));
    c.setPhase(SenseCallPhase.active);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('sense-mic-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('c09_call')));
  }, skip: goldenSkip('c09_call'), tags: const ['golden']);

  testWidgets('s08: two files coming in', (tester) async {
    setWindow(tester, stage);
    final c = c08Controller();
    c.applyJobs([
      job('p1', 'kalibrasyon_ekran2.png', SenseFileDir.out,
          done: 2400000, total: 2400000, state: SenseFileState.ok),
      job('v1', 'takilma_ekran2.mp4', SenseFileDir.incoming, done: 111000000, total: 184000000),
      job('z1', 'sistem_log_2211.zip', SenseFileDir.incoming, done: 24100000, total: 46000000),
    ]);
    c.open();
    await tester.pumpWidget(scene(c));
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('s08_files')));
  }, skip: goldenSkip('s08_files'), tags: const ['golden']);

  testWidgets('n09: icon with unread count and the new-message card', (tester) async {
    setWindow(tester, stage);
    final focused = ValueNotifier(false);
    final c = makeController();
    await tester.pumpWidget(scene(c, focused: focused));
    c.receiveText('Az önce yeniden başlattım.');
    c.receiveText("Ekran 2'de görüntü yine kaydı, bakabilir misiniz?");
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('n09_notice')));
    await tester.pump(const Duration(seconds: 7));
  }, skip: goldenSkip('n09_notice'), tags: const ['golden']);

  testWidgets('chat at 1280 × 720 (T9): fits, no overflow', (tester) async {
    setWindow(tester, const Size(1280, 720));
    final c = c08Controller();
    c.setPhase(SenseCallPhase.active);
    c.open();
    await tester.pumpWidget(app(SizedBox.fromSize(
      size: const Size(1280, 720),
      child: SenseChatLayer(controller: c, computerName: 'PC', animate: false),
    ), still: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    final p = tester.getRect(find.byKey(const Key('sense-chat-popup')));
    expect(p.top, greaterThanOrEqualTo(0));
  });
}
