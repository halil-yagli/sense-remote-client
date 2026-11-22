// Sense Remote: Host-side connection icon and card (sense_cm_*.dart).


import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_page.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_geometry.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_window.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

// 1920x1080 monitor with a 40 px task bar at the bottom.
const work = Rect.fromLTWH(0, 0, 1920, 1040);

Client client(int id, String name,
    {bool authorized = true,
    bool keyboard = true,
    bool clipboard = true,
    bool audio = true}) {
  return Client(
      id, authorized, false, false, name, '12345$id', keyboard, clipboard, audio);
}

class Calls {
  final List<String> log = [];
  SenseCmActions actions() => SenseCmActions(
        onHide: () => log.add('hide'),
        onSelect: (c) => log.add('select ${c.id}'),
        onEnd: (c) => log.add('end ${c.id}'),
        onAccept: (c) => log.add('accept ${c.id}'),
        onReject: (c) => log.add('reject ${c.id}'),
        onCloseEnded: (c) => log.add('close ${c.id}'),
        onVoice: (c, a) => log.add('voice ${c.id} $a'),
        onVoiceEnd: (c) => log.add('voice-end ${c.id}'),
        onSend: (c, t) => log.add('send ${c.id} $t'),
      );
}

Future<void> pumpPanel(
  WidgetTester tester, {
  required List<Client> clients,
  Client? selected,
  required Calls calls,
  List<ChatMessage> messages = const [],
  bool canAccept = true,
  TextEditingController? controller,
}) async {
  tester.view.physicalSize = kSenseCmPanelSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SenseCmPanel(
        clients: clients,
        selected: selected ?? clients.first,
        connectedFor: (_) => const Duration(minutes: 3, seconds: 42),
        messages: messages,
        myUserId: 'me',
        canAccept: canAccept,
        chatController: controller ?? TextEditingController(),
        chatFocus: FocusNode(),
        actions: calls.actions(),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('geometry', () {
    const icon = Size(52, 52);

    test('the icon starts at the bottom right of the work area', () {
      expect(senseCmDefaultIconRect(work, icon, 16),
          const Rect.fromLTWH(1852, 972, 52, 52));
    });

    test('the card opens out of the icon and closes back into it', () {
      final start = senseCmDefaultIconRect(work, icon, 16);
      final anchor = senseCmAnchorFor(start, work);
      expect(anchor, SenseCmAnchor.bottomRight);
      final panel = senseCmPanelRect(start, kSenseCmPanelSize, work, anchor);
      expect(panel.right, start.right);
      expect(panel.bottom, start.bottom);
      expect(panel.size, kSenseCmPanelSize);
      expect(senseCmIconRectFromPanel(panel, icon, work, anchor), start);
    });

    test('near the top left the card grows down and right', () {
      const start = Rect.fromLTWH(20, 30, 52, 52);
      final anchor = senseCmAnchorFor(start, work);
      expect(anchor, const SenseCmAnchor(right: false, bottom: false));
      final panel = senseCmPanelRect(start, kSenseCmPanelSize, work, anchor);
      expect(panel.topLeft, start.topLeft);
      expect(senseCmIconRectFromPanel(panel, icon, work, anchor), start);
    });

    test('the card never leaves the work area', () {
      // Icon in the middle-left, card taller than the space above it.
      const start = Rect.fromLTWH(0, 600, 52, 52);
      final anchor = senseCmAnchorFor(start, const Rect.fromLTWH(0, 0, 400, 700));
      final panel = senseCmPanelRect(start, kSenseCmPanelSize,
          const Rect.fromLTWH(0, 0, 400, 700), anchor);
      expect(const Rect.fromLTWH(0, 0, 400, 700).contains(panel.topLeft), isTrue);
      expect(panel.bottom, lessThanOrEqualTo(700));
      expect(panel.right, lessThanOrEqualTo(400));
    });

    test('a second monitor with negative coordinates is handled', () {
      const left = Rect.fromLTWH(-1920, 0, 1920, 1040);
      final start = senseCmDefaultIconRect(left, icon, 16);
      expect(start, const Rect.fromLTWH(-68, 972, 52, 52));
      expect(senseCmWorkAreaFor(start.topLeft, [work, left]), left);
    });

    test('a remembered place on a monitor that is gone is ignored', () {
      expect(senseCmWorkAreaFor(const Offset(5000, 10), [work]), isNull);
      expect(senseCmWorkAreaFor(null, [work]), isNull);
      expect(senseCmWorkAreaFor(const Offset(100, 100), [work]), work);
    });

    test('position is stored as "x,y" and bad values are rejected', () {
      expect(formatSenseCmPosition(const Offset(1852.4, 972.6)), '1852,973');
      expect(parseSenseCmPosition('1852,973'), const Offset(1852, 973));
      expect(parseSenseCmPosition(' -68 , 972 '), const Offset(-68, 972));
      for (final bad in [null, '', '1', '1,2,3', 'a,b', 'NaN,1']) {
        expect(parseSenseCmPosition(bad), isNull, reason: '$bad');
      }
    });

    test('durations read like the prototype', () {
      expect(formatSenseCmDuration(const Duration(minutes: 3, seconds: 42)),
          '03:42');
      expect(
          formatSenseCmDuration(
              const Duration(hours: 1, minutes: 3, seconds: 42)),
          '1:03:42');
      expect(formatSenseCmDuration(const Duration(seconds: -5)), '00:00');
    });
  });

  // Sense Remote (plan 2026-11-21, M6): the icon on macOS. `window_size`
  // reports points there, flipped against the highest screen edge.
  group('macOS geometry', () {
    const icon = Size(52, 52);

    test('icon mode is on for macOS and Windows, not for Win7 or Linux', () {
      expect(
          senseCmEnabledOn(windows: false, macOS: true, compatibleUi: false),
          isTrue);
      expect(
          senseCmEnabledOn(windows: true, macOS: false, compatibleUi: false),
          isTrue);
      expect(
          senseCmEnabledOn(windows: true, macOS: false, compatibleUi: true),
          isFalse);
      expect(
          senseCmEnabledOn(windows: false, macOS: false, compatibleUi: false),
          isFalse);
    });

    test('a Retina screen does not double the 52 pt icon', () {
      expect(senseCmUnitScale(pointUnits: true, scaleFactor: 2), 1);
      expect(senseCmUnitScale(pointUnits: false, scaleFactor: 1.5), 1.5);
      // 14" MacBook: 1512x982 pt at scale 2, menu bar 38 pt, Dock 70 pt.
      final areas = senseCmWorkAreas(const [
        (
          Rect.fromLTWH(0, 0, 1512, 982),
          Rect.fromLTWH(0, 38, 1512, 874),
          2.0
        ),
      ], macOS: true);
      expect(areas, [(const Rect.fromLTWH(0, 38, 1512, 874), 1.0)]);
      final (work, scale) = areas.first;
      final rect = senseCmDefaultIconRect(work, icon * scale, 16 * scale);
      // 16 pt above the Dock, 16 pt from the right edge, still 52 pt.
      expect(rect, const Rect.fromLTWH(1444, 844, 52, 52));
    });

    test('with the Dock on the left the icon is still bottom right', () {
      // 1440x900, menu bar 25 pt, Dock 64 pt on the left.
      const visible = Rect.fromLTWH(64, 25, 1376, 875);
      final (work, _) = senseCmWorkAreas(const [
        (Rect.fromLTWH(0, 0, 1440, 900), visible, 2.0),
      ], macOS: true)
          .first;
      expect(senseCmDefaultIconRect(work, icon, 16),
          const Rect.fromLTWH(1372, 832, 52, 52));
      // A remembered place under the Dock or the menu bar is pulled back in.
      expect(clampSenseCmRect(const Rect.fromLTWH(0, 0, 52, 52), work),
          const Rect.fromLTWH(64, 25, 52, 52));
    });

    test('with the Dock on the right the icon stays clear of it', () {
      const visible = Rect.fromLTWH(0, 25, 1376, 875);
      final (work, _) = senseCmWorkAreas(const [
        (Rect.fromLTWH(0, 0, 1440, 900), visible, 2.0),
      ], macOS: true)
          .first;
      expect(senseCmDefaultIconRect(work, icon, 16).right, 1376 - 16);
    });

    test('a screen above the primary one shifts y to window coordinates', () {
      // Primary 1440x900 (menu bar 25, Dock 70 at the bottom), an external
      // 1920x1080 arranged above it. window_size puts y = 0 at the top of
      // the external screen, so the primary screen starts at y = 1080.
      const primary = (
        Rect.fromLTWH(0, 1080, 1440, 900),
        Rect.fromLTWH(0, 1105, 1440, 805),
        2.0
      );
      const external = (
        Rect.fromLTWH(-240, 0, 1920, 1080),
        Rect.fromLTWH(-240, 25, 1920, 1055),
        1.0
      );
      expect(senseCmMacTopOffset([primary.$1, external.$1]), 1080);
      final areas = senseCmWorkAreas(const [primary, external], macOS: true);
      // window_manager measures from the top of the primary screen.
      expect(areas, [
        (const Rect.fromLTWH(0, 25, 1440, 805), 1.0),
        (const Rect.fromLTWH(-240, -1055, 1920, 1055), 1.0),
      ]);
      // First start: bottom right of the primary screen, above the Dock.
      final start = senseCmDefaultIconRect(areas.first.$1, icon, 16);
      expect(start, const Rect.fromLTWH(1372, 762, 52, 52));
      // An icon left on the external screen is found there again.
      expect(
          senseCmWorkAreaFor(
              const Offset(1500, -200), areas.map((a) => a.$1).toList()),
          areas[1].$1);
      // The window frame goes through the same shift.
      expect(senseCmMacRect(const Rect.fromLTWH(1372, 1842, 52, 52), 1080),
          start);
    });

    test('one screen, or a screen beside the primary one, needs no shift', () {
      expect(senseCmMacTopOffset(const []), 0);
      expect(
          senseCmMacTopOffset(const [
            Rect.fromLTWH(0, 0, 1440, 900),
            Rect.fromLTWH(1440, 0, 1920, 900),
          ]),
          0);
    });

    test('Windows keeps physical pixels, the scale and its own primary rule',
        () {
      const second = (
        Rect.fromLTWH(-2880, 0, 2880, 1620),
        Rect.fromLTWH(-2880, 0, 2880, 1560),
        1.5
      );
      const first = (
        Rect.fromLTWH(0, 0, 1920, 1080),
        Rect.fromLTWH(0, 0, 1920, 1040),
        1.0
      );
      expect(senseCmWorkAreas(const [second, first], macOS: false), [
        (first.$2, 1.0),
        (second.$2, 1.5),
      ]);
    });
  });

  group('content', () {
    test('only the permissions that are on are listed', () {
      final c = client(1, 'Halil', clipboard: false)..privacyMode = true;
      expect(senseCmPermissions(c), ['klavye · fare', 'ses', 'hayalet mod']);
    });

    test('a waiting peer or an incoming voice call opens the card', () {
      expect(senseCmNeedsAttention(client(1, 'A', authorized: false)), isTrue);
      expect(senseCmNeedsAttention(client(2, 'B')), isFalse);
      expect(senseCmNeedsAttention(client(3, 'C')..incomingVoiceCall = true),
          isTrue);
      expect(
          senseCmNeedsAttention(client(4, 'D', authorized: false)
            ..disconnected = true),
          isFalse);
    });

    test('initials', () {
      expect(senseCmInitials('Halil Yağlı'), 'HY');
      expect(senseCmInitials('ali'), 'A');
      expect(senseCmInitials('  '), '?');
    });

    test('icon mode is off unless the platform enables it', () {
      SenseCm.enabledForTest = false;
      expect(SenseCm.enabled, isFalse);
      SenseCm.enabledForTest = true;
      expect(SenseCm.enabled, isTrue);
      SenseCm.open.value = true;
      SenseCm.selected.value = 7;
      expect(SenseCm.isShowingChat(7), isTrue);
      expect(SenseCm.isShowingChat(8), isFalse);
      SenseCm.open.value = false;
      expect(SenseCm.isShowingChat(7), isFalse);
      SenseCm.enabledForTest = null;
      SenseCm.selected.value = -1;
    });
  });

  group('icon', () {
    testWidgets('shows the live dot, the unread badge and opens on tap',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SenseCmIcon(live: true, unread: 2, onTap: () => taps++),
        ),
      ));
      expect(find.byKey(const ValueKey('sense-cm-live')), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('sense-cm-icon'))),
          kSenseCmIconSize);
      await tester.tap(find.byKey(const ValueKey('sense-cm-icon')));
      expect(taps, 1);
    });

    testWidgets('no badge without unread messages', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(child: SenseCmIcon(live: false, unread: 0, onTap: () {})),
      ));
      expect(find.byKey(const ValueKey('sense-cm-unread')), findsNothing);
    });
  });

  group('card', () {
    testWidgets('who, time, permissions, chat, end and hide', (tester) async {
      final calls = Calls();
      final controller = TextEditingController();
      await pumpPanel(tester,
          clients: [client(1, 'Halil')],
          calls: calls,
          controller: controller,
          messages: [
            ChatMessage(
                text: 'Merhaba',
                user: ChatUser(id: '123451'),
                createdAt: DateTime(2026)),
          ]);
      expect(find.text('Halil'), findsOneWidget);
      expect(find.text('bağlı · 03:42'), findsOneWidget);
      expect(find.text('klavye · fare'), findsOneWidget);
      expect(find.text('pano'), findsOneWidget);
      expect(find.text('ses'), findsOneWidget);
      expect(find.text('Merhaba'), findsOneWidget);
      expect(find.text('Kabul et'), findsNothing);
      // One connection: no list.
      expect(find.byKey(const ValueKey('sense-cm-row-1')), findsNothing);

      await tester.enterText(
          find.byKey(const ValueKey('sense-cm-input')), 'Tamam');
      await tester.tap(find.byKey(const ValueKey('sense-cm-send')));
      await tester.tap(find.byKey(const ValueKey('sense-cm-end')));
      await tester.tap(find.byKey(const ValueKey('sense-cm-hide')));
      expect(calls.log, ['send 1 Tamam', 'end 1', 'hide']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty message is not sent', (tester) async {
      final calls = Calls();
      await pumpPanel(tester, clients: [client(1, 'Halil')], calls: calls);
      await tester.enterText(find.byKey(const ValueKey('sense-cm-input')), '  ');
      await tester.tap(find.byKey(const ValueKey('sense-cm-send')));
      expect(calls.log, isEmpty);
    });

    testWidgets('a waiting peer can be accepted or rejected', (tester) async {
      final calls = Calls();
      await pumpPanel(tester,
          clients: [client(5, 'Ekip', authorized: false)], calls: calls);
      expect(find.text('Bu bilgisayara bağlanmak istiyor.'), findsOneWidget);
      expect(find.byKey(const ValueKey('sense-cm-input')), findsNothing);
      expect(find.byKey(const ValueKey('sense-cm-end')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sense-cm-accept')));
      await tester.tap(find.byKey(const ValueKey('sense-cm-reject')));
      expect(calls.log, ['accept 5', 'reject 5']);
    });

    testWidgets('password-only mode offers no "Kabul et"', (tester) async {
      await pumpPanel(tester,
          clients: [client(5, 'Ekip', authorized: false)],
          calls: Calls(),
          canAccept: false);
      expect(find.byKey(const ValueKey('sense-cm-accept')), findsNothing);
      expect(find.byKey(const ValueKey('sense-cm-reject')), findsOneWidget);
    });

    testWidgets('several connections are listed and selectable',
        (tester) async {
      final calls = Calls();
      final a = client(1, 'Halil');
      final b = client(2, 'Ayşe')..unreadChatMessageCount.value = 3;
      await pumpPanel(tester, clients: [a, b], selected: a, calls: calls);
      expect(find.byKey(const ValueKey('sense-cm-row-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('sense-cm-row-2')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sense-cm-row-2')));
      expect(calls.log, ['select 2']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an ended connection can be closed', (tester) async {
      final calls = Calls();
      await pumpPanel(tester,
          clients: [client(9, 'Halil')..disconnected = true], calls: calls);
      expect(find.text('Bağlantı bitti.'), findsOneWidget);
      expect(find.byKey(const ValueKey('sense-cm-end')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sense-cm-close')));
      expect(calls.log, ['close 9']);
    });

    testWidgets('incoming voice call', (tester) async {
      final calls = Calls();
      await pumpPanel(tester,
          clients: [client(4, 'Halil')..incomingVoiceCall = true],
          calls: calls);
      expect(find.text('Sesli görüşme isteği'), findsOneWidget);
      await tester.tap(find.text('Kabul et'));
      expect(calls.log, ['voice 4 true']);
    });

    testWidgets('the brand reads Sense Remote, never RustDesk',
        (tester) async {
      await pumpPanel(tester, clients: [client(1, 'Halil')], calls: Calls());
      final texts = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((t) => t.text.toPlainText())
          .join('\n');
      expect(texts, contains('Sense Remote'));
      expect(texts.toLowerCase(), isNot(contains('rustdesk')));
    });
  });
}
