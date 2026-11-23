// Sense Remote (C3): the Sense icon and the chat on the Controller window
// (YH O10, #14, #62): icon bottom right, drag, opens next to the icon, "–"
// back to the icon, one popup at a time, notification card when unfocused.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/components_b.dart';
import 'package:flutter_hbb/sense/screens/session/chat_icon/chat_layer.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_controller.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_entry.dart';
import 'package:flutter_hbb/sense/strings/chat.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'support.dart';

const area = Size(1200, 700);

Widget layer(SenseChatController c,
        {SensePopupController? popups, ValueNotifier<bool>? focused, VoidCallback? front}) =>
    app(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: area,
          child: SenseChatLayer(
            controller: c,
            computerName: 'Giriş Salonu PC-2',
            popups: popups,
            windowFocused: focused,
            onBringToFront: front,
            animate: false,
          ),
        ),
      ),
      still: true,
    );

SenseChatLayerState stateOf(WidgetTester t) => t.state(find.byType(SenseChatLayer));

void main() {
  testWidgets('icon starts 20 px from the bottom-right corner, chat closed', (tester) async {
    setWindow(tester, const Size(1280, 760));
    final c = makeController();
    await tester.pumpWidget(layer(c));
    expect(find.byKey(const Key('sense-chat-icon')), findsOneWidget);
    expect(find.byKey(const Key('sense-chat-popup')), findsNothing);
    final r = tester.getRect(find.byKey(const Key('sense-chat-icon')));
    expect(r.size, const Size(SenseSizes.chatIcon, SenseSizes.chatIcon));
    expect(r.right, area.width - 20);
    expect(r.bottom, area.height - 20);
  });

  testWidgets('press opens the chat next to the icon; – returns; no ×', (tester) async {
    setWindow(tester, const Size(1280, 760));
    final c = makeController();
    await tester.pumpWidget(layer(c));
    await tester.tap(find.byKey(const Key('sense-chat-icon')));
    await tester.pump();
    expect(c.isOpen, isTrue);
    expect(find.byKey(const Key('sense-chat-icon')), findsNothing);
    final p = tester.getRect(find.byKey(const Key('sense-chat-popup')));
    // Bottom-right icon: right and bottom edges line up with the icon's (#14).
    expect(p.right, area.width - 20);
    expect(p.bottom, area.height - 20);
    expect(p.width, SenseSizes.popupWidthNarrow, reason: '1280 px window (T3)');
    expect(find.byKey(const Key('sense-popup-close')), findsNothing);

    await tester.tap(find.byKey(const Key('sense-chat-minimize')));
    await tester.pump();
    expect(c.isOpen, isFalse);
    expect(find.byKey(const Key('sense-chat-icon')), findsOneWidget);
  });

  testWidgets('drag moves the icon; the chat then opens beside it', (tester) async {
    setWindow(tester, const Size(1280, 760));
    final c = makeController();
    await tester.pumpWidget(layer(c));
    final start = tester.getTopLeft(find.byKey(const Key('sense-chat-icon')));
    await tester.drag(find.byKey(const Key('sense-chat-icon')), const Offset(-900, -500));
    await tester.pump();
    final moved = tester.getTopLeft(find.byKey(const Key('sense-chat-icon')));
    expect(moved.dx, lessThan(start.dx - 800));
    expect(moved.dy, lessThan(start.dy - 400));
    expect(c.isOpen, isFalse, reason: 'a drag is not a press');

    // Top-left quarter: the chat opens from the icon's top-left, growing down.
    await tester.tap(find.byKey(const Key('sense-chat-icon')));
    await tester.pump();
    final p = tester.getRect(find.byKey(const Key('sense-chat-popup')));
    expect(p.left, moved.dx);
    expect(p.top, moved.dy);
  });

  testWidgets('icon cannot leave the area', (tester) async {
    setWindow(tester, const Size(1280, 760));
    final c = makeController();
    await tester.pumpWidget(layer(c));
    await tester.drag(find.byKey(const Key('sense-chat-icon')), const Offset(500, 500));
    await tester.pump();
    final r = tester.getRect(find.byKey(const Key('sense-chat-icon')));
    expect(r.right, area.width - 8);
    expect(r.bottom, area.height - 8);
  });

  testWidgets('one popup: chat closes the open popup, a popup minimizes the chat (T7)',
      (tester) async {
    setWindow(tester, const Size(1280, 760));
    final popups = SensePopupController();
    final c = makeController();
    await tester.pumpWidget(layer(c, popups: popups));
    popups.open('status', (_) => const SizedBox());
    c.open();
    await tester.pump();
    expect(popups.isOpen, isFalse);
    popups.open('display', (_) => const SizedBox());
    await tester.pump();
    expect(c.isOpen, isFalse);
    expect(find.byKey(const Key('sense-chat-icon')), findsOneWidget);
  });

  testWidgets('unread badge, call ring, transfer dot on the icon', (tester) async {
    setWindow(tester, const Size(1280, 760));
    final c = makeController();
    await tester.pumpWidget(layer(c));
    expect(find.byKey(const Key('sense-chat-icon-badge')), findsNothing);
    c.receiveText('bir');
    c.receiveText('iki');
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('sense-chat-icon-badge')), matching: find.text('2')),
        findsOneWidget);
    expect(find.byKey(const Key('sense-chat-icon-live')), findsOneWidget);
    c.applyJobs([job('a', 'x.zip', SenseFileDir.incoming, done: 1, total: 9)]);
    c.setPhase(SenseCallPhase.active);
    await tester.pump();
    expect(find.byKey(const Key('sense-chat-icon-busy')), findsOneWidget);
    expect(find.byKey(const Key('sense-chat-icon-ring')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-chat-icon')));
    await tester.pump();
    expect(c.unread, 0);
  });

  testWidgets('card only when the window is not in focus; 6 s; press opens chat (#62)',
      (tester) async {
    setWindow(tester, const Size(1280, 760));
    final focused = ValueNotifier(true);
    var front = 0;
    final c = makeController();
    await tester.pumpWidget(layer(c, focused: focused, front: () => front++));

    c.receiveText('görülmez');
    await tester.pump();
    expect(find.byKey(const Key('sense-chat-notice')), findsNothing);

    focused.value = false;
    c.receiveText("Ekran 2'de görüntü yine kaydı, bakabilir misiniz?");
    await tester.pump();
    await tester.pump();
    expect(stateOf(tester).noticeVisible, isTrue);
    expect(find.text('Giriş Salonu PC-2 · yeni mesaj'), findsOneWidget);
    expect(find.text(SenseChatStrings.noticeNow), findsOneWidget);
    expect(find.text("Sahadaki kişi: Ekran 2'de görüntü yine kaydı, bakabilir misiniz?"),
        findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(stateOf(tester).noticeVisible, isTrue);
    await tester.pump(const Duration(seconds: 1, milliseconds: 10));
    expect(stateOf(tester).noticeVisible, isFalse, reason: 'gone after 6 s');

    c.receiveText('tekrar');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('sense-chat-notice')));
    await tester.pump();
    expect(front, 1);
    expect(c.isOpen, isTrue);
    expect(stateOf(tester).noticeVisible, isFalse);
    await tester.pump(const Duration(seconds: 7));
  });
}
