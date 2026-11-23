// Sense Remote (C3): the chat popup — bubbles, wipe note, writing row, Ara /
// Aramayı bitir, Mikrofon list, file bubbles (YH O10, O11 sesli, O12).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_bubbles.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_controller.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_entry.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_popup.dart';
import 'package:flutter_hbb/sense/strings/chat.dart';
import 'package:flutter_hbb/sense/components/glyph.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'support.dart';

Widget popup(SenseChatController c,
        {VoidCallback? onMin,
        Future<List<String>> Function()? pick,
        SenseChatLabels labels = SenseChatLabels.controller}) =>
    app(
      Align(
        alignment: Alignment.topRight,
        child: SizedBox(
          width: 440,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 700),
            child: SenseChatPopup(
              controller: c,
              labels: labels,
              onMinimize: onMin ?? () {},
              pickFiles: pick,
              animateIn: false,
            ),
          ),
        ),
      ),
      still: true,
    );

void main() {
  testWidgets('header, online row, wipe note, bubbles (O10)', (tester) async {
    setWindow(tester, const Size(1280, 800));
    var minimized = 0;
    final c = c08Controller();
    await tester.pumpWidget(popup(c, onMin: () => minimized++));
    expect(find.text('Sohbet'), findsOneWidget);
    expect(find.text('Sahadaki kişiyle'), findsOneWidget);
    expect(find.text('Sahadaki kişi çevrimiçi'), findsOneWidget);
    expect(find.text(SenseChatStrings.wipeNote), findsOneWidget);
    expect(find.text('Ara'), findsOneWidget);
    expect(find.byKey(const Key('sense-popup-close')), findsNothing, reason: 'no close (O10)');

    // Own bubble white with black text, the other side dark.
    Container bubbleOf(String text) => tester.widget<Container>(find
        .ancestor(of: find.text(text), matching: find.byKey(const Key('sense-bubble')))
        .first);
    final mine = bubbleOf('Bakıyorum, birkaç dakika sürer.');
    final theirs = bubbleOf("Merhaba, ekran 2'de video takılıyor.");
    expect((mine.decoration as BoxDecoration).color, SenseColors.text);
    expect((theirs.decoration as BoxDecoration).color, SenseColors.raised);
    expect(find.text('Sen · 17:11'), findsOneWidget);
    expect(find.text('Sahadaki kişi · 17:10'), findsOneWidget);

    // Wipe note is at the top: above the first message.
    final note = tester.getTopLeft(find.text(SenseChatStrings.wipeNote)).dy;
    final first = tester.getTopLeft(find.text("Merhaba, ekran 2'de video takılıyor.")).dy;
    expect(note, lessThan(first));

    await tester.tap(find.byKey(const Key('sense-chat-minimize')));
    expect(minimized, 1);
  });

  testWidgets('no camera anywhere (#67)', (tester) async {
    final c = makeController();
    await tester.pumpWidget(popup(c));
    await tester.tap(find.text('Ara'));
    c.setPhase(SenseCallPhase.active);
    await tester.pump();
    expect(find.textContaining('Kamera'), findsNothing);
    expect(find.text('Mikrofon'), findsOneWidget);
  });

  testWidgets('Enter and Gönder send; Shift+Enter does not', (tester) async {
    final out = <String>[];
    final c = makeController(sentTexts: out);
    await tester.pumpWidget(popup(c));
    await tester.tap(find.byKey(const Key('sense-chat-input')));
    await tester.enterText(find.byKey(const Key('sense-chat-input')), 'Merhaba');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(out, ['Merhaba']);
    expect(find.text('Merhaba'), findsOneWidget, reason: 'the bubble, the field is empty');

    await tester.enterText(find.byKey(const Key('sense-chat-input')), 'İkinci');
    await tester.tap(find.byKey(const Key('sense-chat-send')));
    await tester.pump();
    expect(out, ['Merhaba', 'İkinci']);

    await tester.enterText(find.byKey(const Key('sense-chat-input')), 'üç');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(out, hasLength(2));

    // Empty text is not sent.
    await tester.enterText(find.byKey(const Key('sense-chat-input')), '   ');
    await tester.tap(find.byKey(const Key('sense-chat-send')));
    await tester.pump();
    expect(out, hasLength(2));
  });

  testWidgets('ataç sends the chosen files as bubbles (O12)', (tester) async {
    final f = FakeFiles();
    final c = makeController(files: f);
    await tester.pumpWidget(popup(c, pick: () async => [r'C:\x\olcum.pdf']));
    await tester.tap(find.byKey(const Key('sense-chat-attach')));
    await tester.pump();
    await tester.pump();
    expect(f.sent.single, [r'C:\x\olcum.pdf']);
    expect(find.text('olcum.pdf'), findsOneWidget);
    expect(find.textContaining('Gönderiliyor'), findsOneWidget);
  });

  testWidgets('no ataç without a file side', (tester) async {
    await tester.pumpWidget(popup(makeController()));
    expect(find.byKey(const Key('sense-chat-attach')), findsNothing);
  });

  testWidgets('file bubble: arrow up / down, done ✓, Klasörde göster', (tester) async {
    final f = FakeFiles();
    final c = makeController(files: f);
    c.applyJobs([
      job('o', 'gonder.png', SenseFileDir.out, done: 1, total: 4),
      job('i', 'al.mp4', SenseFileDir.incoming, done: 2, total: 4),
    ]);
    await tester.pumpWidget(popup(c));
    SenseFileRingPainter painterOf(String id) => tester
        .widget<CustomPaint>(find.descendant(
            of: find.byKey(Key('sense-file-ring-$id')), matching: find.byType(CustomPaint)))
        .painter! as SenseFileRingPainter;
    expect(painterOf('o').up, isTrue);
    expect(painterOf('i').up, isFalse);
    expect(find.text(SenseChatStrings.showInFolder), findsNothing);

    c.applyJobs([
      job('o', 'gonder.png', SenseFileDir.out, done: 4, total: 4, state: SenseFileState.ok),
      job('i', 'al.mp4', SenseFileDir.incoming,
          done: 4, total: 4, state: SenseFileState.ok, path: r'C:\u\Downloads\al.mp4'),
    ]);
    await tester.pump(const Duration(milliseconds: 300));
    expect(painterOf('o').done, isTrue);
    expect(painterOf('o').doneColor, senseFileDoneOnWhite());
    expect(painterOf('i').doneColor, SenseColors.ok);
    expect(find.textContaining('İndirilenler’e kaydedildi'), findsNWidgets(2));
    // Only the receiving side gets the link; the file is not opened by itself.
    expect(find.text(SenseChatStrings.showInFolder), findsOneWidget);
    await tester.tap(find.text(SenseChatStrings.showInFolder));
    expect(f.revealed, [r'C:\u\Downloads\al.mp4']);
  });

  testWidgets('Ara → Görüşmede · 01:35 + Aramayı bitir (O11)', (tester) async {
    final call = FakeCall();
    var t = at(17, 0);
    final c = makeController(call: call, now: () => t);
    await tester.pumpWidget(popup(c));
    await tester.tap(find.byKey(const Key('sense-call-start')));
    await tester.pump();
    expect(call.starts, 1);
    expect(find.text(SenseChatStrings.calling), findsOneWidget);
    expect(find.byKey(const Key('sense-call-end')), findsOneWidget);

    c.setPhase(SenseCallPhase.active);
    t = t.add(const Duration(minutes: 1, seconds: 35));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Görüşmede · 01:35'), findsOneWidget);
    // Messages go on during the call.
    expect(find.byKey(const Key('sense-chat-input')), findsOneWidget);

    await tester.tap(find.byKey(const Key('sense-call-end')));
    await tester.pump();
    expect(call.ends, 1);
    expect(find.text('Ara'), findsOneWidget);
  });

  testWidgets('Mikrofon list: devices, level, output, choose, mute (O11)', (tester) async {
    setWindow(tester, const Size(1280, 900));
    final call = FakeCall(levelValue: 0.46);
    final c = makeController(call: call);
    c.setPhase(SenseCallPhase.active);
    await tester.pumpWidget(popup(c));
    await tester.pump();
    expect(find.text('Kulaklık mikrofonu'), findsOneWidget, reason: 'button shows the chosen one');

    await tester.tap(find.byKey(const Key('sense-mic-button')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('sense-mic-menu')), findsOneWidget);
    expect(find.text('MİKROFONLAR · BU BİLGİSAYARA BAĞLI'), findsOneWidget);
    expect(find.text('SES ÇIKIŞI'), findsOneWidget);
    expect(find.text('Kamera mikrofonu'), findsOneWidget);
    expect(find.text('Monitör hoparlörü'), findsOneWidget);
    expect(find.text(SenseChatStrings.level), findsOneWidget);
    final bar = tester.widget<FractionallySizedBox>(find.descendant(
        of: find.byKey(const Key('sense-mic-level')), matching: find.byType(FractionallySizedBox)));
    expect(bar.widthFactor, closeTo(0.46, 1e-9));
    // "Mikrofonu kapat" is the last row.
    final rows = [
      tester.getTopLeft(find.text('Monitör hoparlörü')).dy,
      tester.getTopLeft(find.text(SenseChatStrings.muteMic)).dy,
    ];
    expect(rows[1], greaterThan(rows[0]));

    await tester.tap(find.text('Dahili mikrofon'));
    await tester.pump();
    await tester.pump();
    expect(call.inputs, ['Dahili mikrofon']);
    expect(find.byKey(const Key('sense-mic-menu')), findsNothing);

    await tester.tap(find.byKey(const Key('sense-mic-button')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Hoparlör'));
    await tester.pump();
    expect(call.outputs, ['Hoparlör']);

    // Mute not available on the bridge: says so, does not pretend.
    await tester.tap(find.byKey(const Key('sense-mic-button')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('sense-mic-mute')));
    await tester.pump();
    expect(call.mutes, [true]);
    expect(find.byKey(const Key('sense-mic-mute-failed')), findsOneWidget);
    expect(find.text(SenseChatStrings.micOff), findsNothing);
  });

  testWidgets('mute that works turns the button red "kapalı"', (tester) async {
    setWindow(tester, const Size(1280, 900));
    final call = FakeCall(canMute: true);
    final c = makeController(call: call);
    c.setPhase(SenseCallPhase.active);
    await tester.pumpWidget(popup(c));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sense-mic-button')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('sense-mic-mute')));
    await tester.pump();
    expect(find.text(SenseChatStrings.micOff), findsOneWidget);
    final t = tester.widget<Text>(find.byKey(const Key('sense-mic-current')));
    expect(t.style!.color, SenseColors.dangerTextSoft);
  });

  testWidgets('Host labels (C5 uses the same chat)', (tester) async {
    final c = makeController();
    c.receiveText('Selam');
    await tester.pumpWidget(popup(c, labels: SenseChatLabels.host));
    expect(find.text('Sense Department ile'), findsOneWidget);
    expect(find.text('Sense Department · 17:14'), findsOneWidget);
  });

  group('#73: the Host calls the Controller', () {
    testWidgets('green "Sahadaki kişi sesli arıyor" box; Kabul et answers', (tester) async {
      final call = FakeCall();
      var t = at(17, 0);
      final c = makeController(call: call, now: () => t);
      await tester.pumpWidget(popup(c));
      expect(find.byKey(const Key('sense-chat-incoming')), findsNothing);

      c.setPhase(SenseCallPhase.incoming);
      await tester.pump();
      expect(find.byKey(const Key('sense-chat-incoming')), findsOneWidget);
      expect(find.text('Sahadaki kişi sesli arıyor'), findsOneWidget);
      expect(find.textContaining('görüntülü'), findsNothing, reason: '#67 voice only');
      expect(find.text(SenseChatStrings.reject), findsOneWidget);
      expect(find.text(SenseChatStrings.accept), findsOneWidget);
      // No Mikrofon list before the call is answered.
      expect(find.byKey(const Key('sense-mic-button')), findsNothing);
      // Kabul et sits right of Reddet.
      expect(tester.getCenter(find.byKey(const Key('sense-chat-call-accept'))).dx,
          greaterThan(tester.getCenter(find.byKey(const Key('sense-chat-call-reject'))).dx));

      await tester.tap(find.byKey(const Key('sense-chat-call-accept')));
      await tester.pump();
      expect(call.starts, 1, reason: 'answering is session_request_voice_call (D3d2)');
      expect(call.ends, 0);
      expect(find.byKey(const Key('sense-chat-incoming')), findsNothing);

      c.setPhase(SenseCallPhase.active);
      t = t.add(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Görüşmede · 00:05'), findsOneWidget);
      expect(find.byKey(const Key('sense-mic-button')), findsOneWidget);
    });

    testWidgets('Reddet refuses: back to "Ara", nothing started', (tester) async {
      final call = FakeCall();
      final c = makeController(call: call);
      c.setPhase(SenseCallPhase.incoming);
      await tester.pumpWidget(popup(c));
      await tester.tap(find.byKey(const Key('sense-chat-call-reject')));
      await tester.pump();
      expect(call.ends, 1);
      expect(call.starts, 0);
      expect(c.phase, SenseCallPhase.idle);
      expect(find.byKey(const Key('sense-chat-incoming')), findsNothing);
      expect(find.byKey(const Key('sense-call-start')), findsOneWidget);
    });

    testWidgets('the Host hangs up while ringing: the box goes', (tester) async {
      final c = makeController();
      c.setPhase(SenseCallPhase.incoming);
      await tester.pumpWidget(popup(c));
      expect(find.byKey(const Key('sense-chat-incoming')), findsOneWidget);
      c.setPhase(SenseCallPhase.idle);
      await tester.pump();
      expect(find.byKey(const Key('sense-chat-incoming')), findsNothing);
    });

    testWidgets('both call at once (#83): one call, no ringing box', (tester) async {
      // The Controller rings first; the Host's Ara answers it (core: D3d2
      // fix), so here only "started" arrives.
      final call = FakeCall();
      final c = makeController(call: call);
      await tester.pumpWidget(popup(c));
      await tester.tap(find.byKey(const Key('sense-call-start')));
      await tester.pump();
      expect(find.text(SenseChatStrings.calling), findsOneWidget);
      c.setPhase(SenseCallPhase.active);
      await tester.pump();
      expect(call.starts, 1);
      expect(find.byKey(const Key('sense-chat-incoming')), findsNothing);
      expect(find.byKey(const Key('sense-call-end')), findsOneWidget);
    });

    testWidgets('mic caret is drawn, not a ▾ character (G1)', (tester) async {
      final c = makeController();
      c.setPhase(SenseCallPhase.active);
      await tester.pumpWidget(popup(c));
      await tester.pump();
      expect(find.text('▾'), findsNothing);
      expect(
          find.descendant(
              of: find.byKey(const Key('sense-mic-button')), matching: find.byType(SenseGlyph)),
          findsOneWidget);
    });
  });
}
