// Sense Remote: Host-side Sense icon and card (YH H3, H4; sense_cm_*.dart,
// data/*). Geometry, edge tab, the icon's states, the card's boxes and the
// chat wiring. Golden images: host_live_golden_test.dart.

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/host_live/data/call.dart';
import 'package:flutter_hbb/sense/screens/host_live/data/chat.dart';
import 'package:flutter_hbb/sense/screens/host_live/data/end_summary.dart';
import 'package:flutter_hbb/sense/screens/host_live/data/files.dart';
import 'package:flutter_hbb/sense/screens/host_live/data/overlay.dart';
import 'package:flutter_hbb/sense/screens/host_live/data/peer_state.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_ended.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_geometry.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_page.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_region.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_window.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_call.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_composer.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_controller.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_entry.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/data/call.dart';
import 'package:flutter_hbb/sense/strings/host_live.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support.dart';

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
      // TS-18: Turkish upper case.
      expect(senseCmInitials('ismail ışık'), 'İI');
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

  group('edge tab geometry (H3 "Kenara saklı")', () {
    const icon = kSenseCmIconSize;

    test('the icon is 64 x 64 and the tab window 24 x 52 (tab 18 wide)', () {
      expect(icon, const Size(64, 64));
      expect(kSenseCmEdgeSize, const Size(24, 52));
      expect(kSenseCmEdgeTabWidth, 18);
    });

    test('the default place is bottom right, 14 above the task bar', () {
      expect(senseCmDefaultIconRect(work, icon, kSenseCmMargin),
          const Rect.fromLTWH(1842, 962, 64, 64));
    });

    test('dropped near the left or right edge it goes to that edge', () {
      expect(senseCmEdgeFor(const Rect.fromLTWH(4, 300, 64, 64), work, 12),
          SenseCmEdge.left);
      expect(senseCmEdgeFor(const Rect.fromLTWH(-30, 300, 64, 64), work, 12),
          SenseCmEdge.left);
      expect(senseCmEdgeFor(const Rect.fromLTWH(1850, 300, 64, 64), work, 12),
          SenseCmEdge.right);
      expect(senseCmEdgeFor(const Rect.fromLTWH(900, 300, 64, 64), work, 12),
          isNull);
      // The default corner (14 from the edge) is not an edge drop.
      expect(
          senseCmEdgeFor(
              senseCmDefaultIconRect(work, icon, kSenseCmMargin), work, 12),
          isNull);
    });

    test('the tab hugs the edge and the icon comes back beside it', () {
      const dropped = Rect.fromLTWH(1855, 400, 64, 64);
      final tab = senseCmEdgeRect(
          dropped, work, SenseCmEdge.right, kSenseCmEdgeSize, 6);
      expect(tab, const Rect.fromLTWH(1896, 406, 24, 52));
      final back = senseCmIconFromEdge(
          tab, work, SenseCmEdge.right, icon, kSenseCmEdgeInset, 6);
      expect(back, const Rect.fromLTWH(1838, 400, 64, 64));

      final left = senseCmEdgeRect(const Rect.fromLTWH(2, 1000, 64, 64), work,
          SenseCmEdge.left, kSenseCmEdgeSize, 6);
      // Kept inside the work area (above the task bar).
      expect(left, const Rect.fromLTWH(0, 988, 24, 52));
      expect(
          senseCmIconFromEdge(
              left, work, SenseCmEdge.left, icon, kSenseCmEdgeInset, 6),
          const Rect.fromLTWH(18, 976, 64, 64));
    });

    test('at 150 % the tab and the icon scale with the monitor', () {
      const scale = 1.5;
      const area = Rect.fromLTWH(0, 0, 2880, 1560);
      final rect =
          senseCmDefaultIconRect(area, icon * scale, kSenseCmMargin * scale);
      expect(rect.size, const Size(96, 96));
      final tab = senseCmEdgeRect(
          rect, area, SenseCmEdge.right, kSenseCmEdgeSize * scale, 6 * scale);
      expect(tab.size, const Size(36, 78));
      expect(tab.right, area.right);
    });
  });

  group('data', () {
    test('sense_recording is read from the clients JSON', () {
      expect(
          senseParseRecording(
              '[{"id":3,"sense_recording":true},{"id":4},{"id":"x"}]'),
          {3: true, 4: false});
      expect(senseParseRecording('nope'), isEmpty);
      expect(senseParseRecording('{}'), isEmpty);
    });

    test('the who line reads like the prototype', () {
      final c = client(1, 'Halil Y.', clipboard: false, audio: false)
        ..file = true;
      expect(senseHostPermissions(c), ['ekran', 'fare ve klavye', 'dosya']);
      expect(senseHostWhoLine(c, const Duration(minutes: 14)),
          'Halil Y. · 14 dk · ekran, fare ve klavye, dosya');
      expect(SenseHostLiveStrings.minutes(const Duration(seconds: 20)), '1 dk');
      // TS-10: same form as the Host home screen ("1 sa 5 dk", "2 sa").
      expect(SenseHostLiveStrings.minutes(const Duration(minutes: 65)),
          '1 sa 5 dk');
      expect(SenseHostLiveStrings.minutes(const Duration(minutes: 120)), '2 sa');
      expect(senseHostWhoLine(client(2, 'Ali', keyboard: false), null),
          'Ali · ekran, pano, ses');
    });

    test('the clock counts the connection and the recording', () {
      var now = DateTime(2026, 11, 23, 17, 0);
      final clock = SenseHostClock(now: () => now);
      final c = client(1, 'Halil');
      clock.update([c]);
      now = now.add(const Duration(minutes: 1, seconds: 15));
      expect(clock.connectedFor(1), const Duration(minutes: 1, seconds: 15));
      expect(clock.recordingFor(1), isNull);
      c.senseRecording = true;
      clock.update([c]);
      now = now.add(const Duration(minutes: 1, seconds: 15));
      clock.update([c]);
      expect(clock.recordingFor(1), const Duration(minutes: 1, seconds: 15));
      c.senseRecording = false;
      clock.update([c]);
      expect(clock.recordingFor(1), isNull);
      clock.update(const []);
      expect(clock.connectedFor(1), isNull);
    });

    test('the recording watch hands every connection over', () async {
      final seen = <String>[];
      final watch = SenseHostRecordingWatch(
        onRecording: (id, on) => seen.add('$id $on'),
        readState: () async => '[{"id":1,"sense_recording":true}]',
      );
      await watch.poll();
      expect(seen, ['1 true']);
      watch.stop();
    });

    test('the server model keeps the recording flag', () {
      final c = Client.fromJson({
        'id': 1,
        'authorized': true,
        'is_file_transfer': false,
        'is_view_camera': false,
        'port_forward': '',
        'name': 'Halil',
        'peer_id': '1',
        'keyboard': true,
        'clipboard': true,
        'audio': true,
        'file': true,
        'restart': false,
        'recording': false,
        'block_input': false,
        'disconnected': false,
        'from_switch': false,
        'in_voice_call': false,
        'incoming_voice_call': false,
        'sense_recording': true,
      });
      expect(c.senseRecording, isTrue);
      expect(c.toJson()['sense_recording'], isTrue);
    });

    test('Controller messages reach the card once, oldest first', () {
      final sent = <String>[];
      final chat = makeController(sentTexts: sent);
      final them = ChatUser(id: 'peer', firstName: 'Sense Department');
      final me = ChatUser(id: 'me');
      final list = [
        ChatMessage(text: 'ikinci', user: them, createdAt: DateTime(2026, 1, 1, 10, 2)),
        ChatMessage(text: 'benim', user: me, createdAt: DateTime(2026, 1, 1, 10, 1)),
        ChatMessage(text: 'ilk', user: them, createdAt: DateTime(2026, 1, 1, 10, 0)),
      ];
      var fed = senseHostFeedMessages(chat, list, 'me', 0);
      expect(fed, 2);
      expect([for (final e in chat.entries) (e as SenseChatText).text],
          ['ilk', 'ikinci']);
      expect(chat.entries.every((e) => !e.mine), isTrue);
      fed = senseHostFeedMessages(chat, list, 'me', fed);
      expect(chat.entries, hasLength(2));
      expect(chat.unread, 2);
    });

    test('call phase follows RustDesk flags', () {
      expect(
          senseHostCallPhase(
              inCall: true, incoming: false, current: SenseCallPhase.idle),
          SenseCallPhase.active);
      expect(
          senseHostCallPhase(
              inCall: false, incoming: true, current: SenseCallPhase.idle),
          SenseCallPhase.incoming);
      expect(
          senseHostCallPhase(
              inCall: false, incoming: false, current: SenseCallPhase.calling),
          SenseCallPhase.calling);
      expect(
          senseHostCallPhase(
              inCall: false, incoming: false, current: SenseCallPhase.active),
          SenseCallPhase.idle);
      // Both call at once (#83): the Controller's call reaches this side
      // while "Aranıyor…" — the ringing box shows, Kabul et answers it.
      expect(
          senseHostCallPhase(
              inCall: false, incoming: true, current: SenseCallPhase.calling),
          SenseCallPhase.incoming);
      expect(
          senseHostCallPhase(
              inCall: true, incoming: true, current: SenseCallPhase.incoming),
          SenseCallPhase.active);
    });

    test('Host calling and Host files are on the bridge (D3d2)', () async {
      expect(SenseHostChatCall.canStart, isTrue);
      expect(SenseHostChatFiles.available, isTrue);
      // Nothing to send starts nothing (no bridge call).
      expect(await SenseHostChatFiles(connId: 1).send(const []), isEmpty);
    });

    test('sound outputs and microphone level from the bridge (D3d2)', () {
      final o = senseParseSoundOutputs(
          '{"outputs":["Hoparlör","Kulaklık"],"output":"Kulaklık"}');
      expect(o.outputs, ['Hoparlör', 'Kulaklık']);
      expect(o.output, 'Kulaklık');
      // A chosen output that is gone shows as the system default.
      expect(senseParseSoundOutputs('{"outputs":["Hoparlör"],"output":"USB"}').output, '');
      expect(senseParseSoundOutputs('nope').outputs, isEmpty);
      expect(senseCallLevel(-1), isNull);
      expect(senseCallLevel(0.4), 0.4);
      expect(senseCallLevel(3), 1.0);
    });

    test('the card shows the live connection; a waiting one beside it (O6)', () {
      final ended = client(1, 'A')..disconnected = true;
      final live = client(2, 'B');
      final waiting = client(3, 'C', authorized: false);
      expect(senseCmPick([ended, live]).id, 2);
      // O6: a second login waiting (approve mode "click") no longer hides the
      // live connection and its "Bitir"; it gets its own box.
      expect(senseCmPick([live, waiting]).id, 2);
      expect(senseCmWaiting([live, waiting])?.id, 3);
      expect(senseCmWaiting([ended, live]), isNull);
      // Nothing live: the waiting one, then any.
      expect(senseCmPick([ended, waiting]).id, 3);
      expect(senseCmPick([ended]).id, 1);
      // An incoming voice call comes first.
      final calling = client(4, 'B')..incomingVoiceCall = true;
      expect(senseCmPick([live, calling]).id, 4);
    });

    test('O6: the screen connection is shown before a terminal or a tunnel', () {
      final terminal = client(1, 'Halil Y.')..isTerminal = true;
      final tunnel = client(2, 'Halil Y.')..portForward = '3389';
      final screen = client(3, 'Halil Y.');
      expect(senseCmPick([terminal, tunnel, screen]).id, 3);
      expect(senseCmPick([terminal, tunnel]).id, 1);
    });

    test('O6: kinds of the connections', () {
      final file = Client(1, true, true, false, 'H', '1', false, false, false);
      final camera = Client(2, true, false, true, 'H', '1', false, false, false);
      expect(senseCmKindText(client(3, 'H')), 'ekran');
      expect(senseCmKindText(client(4, 'H')..isTerminal = true), 'terminal');
      expect(senseCmKindText(client(5, 'H')..portForward = '22'), 'TCP tüneli');
      expect(senseCmKindText(file), 'dosya aktarımı');
      expect(senseCmKindText(camera), 'kamera');
    });

    test('O6: count and kinds when more than one connection is on', () {
      final screen = client(1, 'Halil Y.');
      final terminal = client(2, 'Halil Y.')..isTerminal = true;
      final tunnel = client(3, 'Halil Y.')..portForward = '3389';
      final ended = client(4, 'Halil Y.')..disconnected = true;
      final waiting = client(5, 'Halil Y.', authorized: false);
      final live = senseHostLive([terminal, screen, ended, waiting]);
      expect(live.map((c) => c.id), [2, 1]);
      // Screen first, whatever the order of the connections.
      expect(senseHostConnectionsLine(live), '2 bağlantı · ekran, terminal');
      expect(senseHostConnectionsLine([screen, terminal, tunnel]),
          '3 bağlantı · ekran, terminal, TCP tüneli');
      // Two terminals: one kind, two connections.
      expect(senseHostConnectionsLine([terminal, client(6, 'H')..isTerminal = true]),
          '2 bağlantı · terminal');
      // One connection: the who line says enough.
      expect(senseHostConnectionsLine([screen]), isNull);
      expect(senseHostConnectionsLine(const []), isNull);
    });

    test('O6: "Tümünü bitir" closes every live connection', () {
      final screen = client(1, 'Halil Y.');
      final terminal = client(2, 'Halil Y.')..isTerminal = true;
      final closed = <int>[];
      senseHostEndAll(senseHostLive([screen, terminal]), screen, (c) => closed.add(c.id));
      expect(closed, [1, 2]);
      // Nothing live any more: the shown one (as before).
      closed.clear();
      final ended = client(3, 'Halil Y.')..disconnected = true;
      senseHostEndAll(senseHostLive([ended]), ended, (c) => closed.add(c.id));
      expect(closed, [3]);
    });

    test('O8: "Mikrofonu kapat" is kept until the call ends', () {
      SenseHostChatCall.callEnded(7);
      expect(SenseHostChatCall.mutedFor(7), isFalse);
      SenseHostChatCall.noteMuted(7, true);
      // The list reads the devices again when it opens: still muted.
      expect(SenseHostChatCall.mutedFor(7), isTrue);
      expect(SenseHostChatCall.mutedFor(8), isFalse, reason: 'per connection');
      SenseHostChatCall.noteMuted(7, false);
      expect(SenseHostChatCall.mutedFor(7), isFalse);
      SenseHostChatCall.noteMuted(7, true);
      // The call ended (the core opens the microphone again).
      SenseHostChatCall.callEnded(7);
      expect(SenseHostChatCall.mutedFor(7), isFalse);
    });
  });

  group('icon (H3)', () {
    testWidgets('logo only: live dot, no badge, no ring, no record dot',
        (tester) async {
      var taps = 0;
      await pumpBox(tester, kSenseCmIconSize,
          SenseHostIcon(onTap: () => taps++));
      expect(tester.getSize(find.byKey(const Key('sense-host-icon'))),
          const Size(64, 64));
      expect(find.byKey(const Key('sense-host-icon-live')), findsOneWidget);
      expect(find.byKey(const Key('sense-host-icon-badge')), findsNothing);
      expect(find.byKey(const Key('sense-host-icon-ring')), findsNothing);
      expect(find.byKey(const Key('sense-host-icon-rec')), findsNothing);
      // No plate, no frame (#4): nothing paints a box behind the mark.
      final boxes = tester
          .widgetList<Container>(find.descendant(
              of: find.byKey(const Key('sense-host-icon')),
              matching: find.byType(Container)))
          .where((c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).shape == BoxShape.rectangle &&
              (c.decoration as BoxDecoration).borderRadius == null);
      expect(boxes, isEmpty);
      await tester.tap(find.byKey(const Key('sense-host-icon')));
      expect(taps, 1);
    });

    testWidgets('unread, call, transfer and recording', (tester) async {
      await pumpBox(
          tester,
          kSenseCmIconSize,
          SenseHostIcon(
            onTap: () {},
            unread: 3,
            inCall: true,
            transferring: true,
            recording: true,
          ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('3'), findsOneWidget);
      final badge = tester.getTopLeft(find.byKey(const Key('sense-host-icon-badge')));
      expect(badge.dx, lessThan(32), reason: 'badge is top left');
      final rec = tester.getTopLeft(find.byKey(const Key('sense-host-icon-rec')));
      expect(rec.dx, lessThan(32), reason: 'record dot is bottom left');
      expect(rec.dy, greaterThan(32));
      final live = tester.getTopLeft(find.byKey(const Key('sense-host-icon-busy')));
      expect(live.dx, greaterThan(32), reason: 'the dot is top right');
      expect(find.byKey(const Key('sense-host-icon-ring')), findsOneWidget);
    });

    testWidgets('a drag starts the window drag, not a tap', (tester) async {
      var taps = 0;
      var drags = 0;
      await pumpBox(
          tester,
          const Size(300, 300),
          Center(
            child: SenseHostIcon(onTap: () => taps++, onDragStart: () => drags++),
          ));
      await tester.drag(find.byKey(const Key('sense-host-icon')), const Offset(60, 0));
      expect(drags, 1);
      expect(taps, 0);
    });

    testWidgets('a 150 % screen keeps the icon logo sized', (tester) async {
      tester.view.physicalSize = const Size(96, 96);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(SenseHostIcon(onTap: () {}), still: true));
      expect(tester.getSize(find.byKey(const Key('sense-host-icon'))),
          const Size(64, 64));
      expect(tester.getSize(find.byType(SenseMark).last),
          const Size(SenseSizes.chatIconLogoWidth, SenseSizes.chatIconLogoHeight));
    });
  });

  group('edge tab (H3)', () {
    testWidgets('18 wide, 24 under the mouse; a press brings the icon back',
        (tester) async {
      var taps = 0;
      await pumpBox(tester, kSenseCmEdgeSize,
          SenseHostEdgeTab(edge: SenseCmEdge.right, onTap: () => taps++));
      final tab = find.byKey(const Key('sense-host-edge'));
      expect(tester.getSize(tab), const Size(18, 52));
      expect(tester.getTopRight(tab).dx, 24, reason: 'hugs the right edge');
      expect(find.byType(SenseStatusDot), findsOneWidget);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(tab));
      await tester.pumpAndSettle();
      expect(tester.getSize(tab), const Size(24, 52));
      await tester.tap(tab);
      expect(taps, 1);
    });

    testWidgets('on the left edge it hugs the left side', (tester) async {
      await pumpBox(tester, kSenseCmEdgeSize,
          SenseHostEdgeTab(edge: SenseCmEdge.left, onTap: () {}));
      expect(tester.getTopLeft(find.byKey(const Key('sense-host-edge'))).dx, 0);
    });
  });

  group('card (H4)', () {
    testWidgets('header, who box, end, minimize; no RustDesk name',
        (tester) async {
      final calls = <String>[];
      final chat = makeController();
      await pumpCard(tester, client(1, 'Halil Y.'), chat, calls);
      expect(find.text('Sense Remote'), findsOneWidget);
      expect(find.text('Sense Department ile'), findsOneWidget);
      expect(find.text('Sense Department bağlı'), findsOneWidget);
      expect(find.text('Halil Y. · 14 dk · ekran, fare ve klavye, pano, ses'),
          findsOneWidget);
      expect(find.text('Sense Department ile sohbet'), findsOneWidget);
      expect(find.byKey(const Key('sense-host-recording')), findsNothing);
      expect(find.byKey(const Key('sense-host-incoming')), findsNothing);
      expect(find.textContaining('RustDesk'), findsNothing);
      await tester.tap(find.byKey(const Key('sense-host-end')));
      await tester.tap(find.byKey(const Key('sense-host-minimize')));
      await tester.tap(find.byKey(const Key('sense-host-header')));
      expect(calls, ['end', 'minimize', 'minimize']);
    });

    testWidgets('recording strip shows the running time', (tester) async {
      await pumpCard(tester, client(1, 'Halil Y.'), makeController(), [],
          recording: const Duration(minutes: 1, seconds: 15));
      expect(find.text('Bu bağlantı kaydediliyor · 01:15'), findsOneWidget);
    });

    testWidgets('incoming voice call: Reddet / Kabul et', (tester) async {
      final calls = <String>[];
      final chat = makeController();
      chat.setPhase(SenseCallPhase.incoming);
      await pumpCard(tester, client(1, 'Halil Y.'), chat, calls);
      expect(find.text('Sense Department sesli arıyor'), findsOneWidget);
      expect(find.textContaining('görüntülü'), findsNothing, reason: '#67');
      await tester.tap(find.byKey(const Key('sense-host-call-reject')));
      await tester.tap(find.byKey(const Key('sense-host-call-accept')));
      expect(calls, ['call false', 'call true']);
    });

    testWidgets('in a call: Aramayı bitir and the Mikrofon button',
        (tester) async {
      final call = FakeCall();
      final chat = makeController(call: call);
      chat.setPhase(SenseCallPhase.active);
      await pumpCard(tester, client(1, 'Halil Y.'), chat, []);
      expect(find.byKey(const Key('sense-call-end')), findsOneWidget);
      expect(find.byType(SenseMicButton), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-call-end')));
      await tester.pump();
      expect(call.ends, 1);
    });

    testWidgets('Ara is faded until the Host can call (D3d2)', (tester) async {
      final call = FakeCall();
      final chat = makeController(call: call);
      await pumpCard(tester, client(1, 'Halil Y.'), chat, []);
      final ara = tester.widget<SenseButton>(find.byKey(const Key('sense-call-start')));
      expect(ara.onPressed, isNull);
      await pumpCard(tester, client(1, 'Halil Y.'), chat, [], canCall: true);
      await tester.tap(find.byKey(const Key('sense-call-start')));
      await tester.pump();
      expect(call.starts, 1);
    });

    testWidgets('chat: send, the other side, wipe note; no ataç yet',
        (tester) async {
      final sent = <String>[];
      final chat = makeController(sentTexts: sent);
      chat.receiveText('Merhaba, bağlandım.');
      await pumpCard(tester, client(1, 'Halil Y.'), chat, []);
      expect(find.text('Merhaba, bağlandım.'), findsOneWidget);
      expect(find.textContaining('Sense Department · '), findsOneWidget);
      expect(find.byKey(const Key('sense-chat-wipe-note')), findsOneWidget);
      expect(find.byKey(const Key('sense-chat-attach')), findsNothing);
      await tester.enterText(find.byKey(const Key('sense-chat-input')), 'Ekran 2 takılıyor');
      await tester.tap(find.byKey(const Key('sense-chat-send')));
      await tester.pump();
      expect(sent, ['Ekran 2 takılıyor']);
      expect(find.text('Ekran 2 takılıyor'), findsOneWidget);
    });

    testWidgets('a waiting peer can be accepted or rejected', (tester) async {
      final calls = <String>[];
      await pumpCard(tester, client(1, 'Halil Y.', authorized: false),
          makeController(), calls);
      expect(find.text('Halil Y. bağlanmak istiyor'), findsOneWidget);
      expect(find.byType(SenseChatComposer), findsNothing);
      await tester.tap(find.byKey(const Key('sense-host-accept')));
      await tester.tap(find.byKey(const Key('sense-host-reject')));
      expect(calls, ['accept', 'reject']);
    });

    testWidgets('O6: screen + terminal: count, kinds and "Tümünü bitir"',
        (tester) async {
      final calls = <String>[];
      final screen = client(1, 'Halil Y.');
      final terminal = client(2, 'Halil Y.')..isTerminal = true;
      await pumpCard(tester, screen, makeController(), calls,
          connectionsLine: senseHostConnectionsLine(senseHostLive([screen, terminal])));
      expect(find.text('Sense Department bağlı'), findsOneWidget);
      expect(find.text('2 bağlantı · ekran, terminal'), findsOneWidget);
      expect(find.text('Tümünü bitir'), findsOneWidget);
      expect(find.text('Bağlantıyı bitir'), findsNothing);
      await tester.tap(find.byKey(const Key('sense-host-end')));
      expect(calls, ['end']);
    });

    testWidgets('O6: one connection keeps "Bağlantıyı bitir" and no count',
        (tester) async {
      await pumpCard(tester, client(1, 'Halil Y.'), makeController(), []);
      expect(find.text('Bağlantıyı bitir'), findsOneWidget);
      expect(find.byKey(const Key('sense-host-connections')), findsNothing);
    });

    testWidgets('O6: a second login waits while the first is live: both boxes',
        (tester) async {
      final calls = <String>[];
      await pumpCard(tester, client(1, 'Halil Y.'), makeController(), calls,
          waiting: client(2, 'Halil Y.', authorized: false));
      expect(find.text('Halil Y. bağlanmak istiyor'), findsOneWidget);
      expect(find.text('Sense Department bağlı'), findsOneWidget);
      expect(find.byType(SenseChatComposer), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-host-accept')));
      await tester.tap(find.byKey(const Key('sense-host-end')));
      expect(calls, ['accept', 'end']);
    });

    testWidgets('password-only mode offers no "Kabul et"', (tester) async {
      await pumpCard(tester, client(1, 'Halil Y.', authorized: false),
          makeController(), [],
          canAccept: false);
      expect(find.byKey(const Key('sense-host-accept')), findsNothing);
      expect(find.byKey(const Key('sense-host-reject')), findsOneWidget);
    });

    testWidgets('an ended connection can be closed', (tester) async {
      final calls = <String>[];
      await pumpCard(tester, client(1, 'Halil Y.')..disconnected = true,
          makeController(), calls);
      expect(find.text('Bağlantı sona erdi'), findsOneWidget);
      expect(find.textContaining('sn sonra bu kart kapanır'), findsNothing);
      expect(find.byKey(const Key('sense-host-end')), findsNothing);
      await tester.tap(find.byKey(const Key('sense-host-close')));
      expect(calls, ['close']);
    });

    testWidgets('#101: after every connection ended the card counts down',
        (tester) async {
      final calls = <String>[];
      await pumpCard(tester, client(1, 'Halil Y.')..disconnected = true,
          makeController(), calls,
          endedClosingIn: 4);
      expect(find.text('Bağlantı sona erdi'), findsOneWidget);
      expect(find.text('4 sn sonra bu kart kapanır'), findsOneWidget);
      expect(find.byType(SenseChatComposer), findsNothing);
      await tester.tap(find.byKey(const Key('sense-host-close')));
      expect(calls, ['close']);
    });
  });

  group('Sürüm 12 (HB): bitiş kartı, sohbet görünür, yönetici terminali', () {
    test('peer state JSON: chat_visible and admin_terminals', () {
      final s = SenseHostPeerState.parse(
          '{"chat_visible":[3,5],"admin_terminals":[{"conn_id":4,"by":"ben@example.test"},{"conn_id":6,"by":"ben@example.test"}]}');
      expect(s.chatShown, isTrue);
      expect(s.chatVisible, {3, 5});
      expect(s.admins, hasLength(2));
      // The same account twice reads once.
      expect(s.adminLine, 'Yönetici terminali açık · ben@example.test');
      expect(SenseHostPeerState.parse('{"chat_visible":[],"admin_terminals":[]}'), SenseHostPeerState.none);
      expect(SenseHostPeerState.none.chatShown, isFalse);
      expect(SenseHostPeerState.none.adminLine, isNull);
      // Without an account: the sentence alone.
      expect(SenseHostPeerState.parse('{"admin_terminals":[{"conn_id":4}]}').adminLine,
          'Yönetici terminali açık');
    });

    test('peer state: broken input is "nothing asked", never an exception', () {
      for (final raw in ['', 'x', '[]', '{"chat_visible":"a","admin_terminals":[1,{"conn_id":"x"}]}']) {
        final s = SenseHostPeerState.parse(raw);
        expect(s.chatShown, isFalse, reason: raw);
        expect(s.adminLine, isNull, reason: raw);
      }
      expect(SenseHostPeerState.parse('{"chat_visible":[1]}') == SenseHostPeerState.parse('{"chat_visible":[1]}'), isTrue);
      expect(SenseHostPeerState.parse('{"chat_visible":[1]}') == SenseHostPeerState.none, isFalse);
    });

    test('the watch reads once and keeps going after a failure', () async {
      final seen = <SenseHostPeerState>[];
      var n = 0;
      final watch = SenseHostPeerWatch(
        onState: seen.add,
        read: () async {
          n++;
          if (n == 1) throw StateError('core closing');
          return '{"chat_visible":[1]}';
        },
      );
      await watch.poll();
      expect(seen, isEmpty);
      await watch.poll();
      expect(seen.single.chatShown, isTrue);
    });

    test('end figures: counts and time are kept from the live connection', () {
      final t = SenseHostEndTracker();
      final chat = <SenseChatEntry>[
        SenseChatText(text: 'a', mine: false, at: DateTime(2026, 11, 28, 10)),
        SenseChatText(text: 'b', mine: true, at: DateTime(2026, 11, 28, 10, 1)),
        SenseChatText(text: 'c', mine: false, at: DateTime(2026, 11, 28, 10, 2)),
      ];
      expect(senseHostChatCounts(chat), (messages: 3, files: 0));
      t.observe(1, live: true, connectedFor: const Duration(minutes: 41), chat: chat);
      // The connection ended: time is frozen from this reading, the chat is read a last time.
      t.observe(1, live: false, connectedFor: const Duration(minutes: 42), chat: chat);
      // Later readings (the card is still up, the chat is gone) change nothing.
      t.observe(1, live: false, connectedFor: const Duration(minutes: 50));
      final info = t.infoFor(1)!;
      expect(info.duration, const Duration(minutes: 42));
      expect(info.messages, 3);
      expect(info.files, 0);
      expect(info.byHost, isFalse);
      t.markEndedByHost(1);
      expect(t.infoFor(1)!.byHost, isTrue);
      expect(t.infoFor(2), isNull);
      t.forget({2});
      expect(t.infoFor(1), isNull);
    });

    testWidgets('FH-A3: the ended card says who ended it, time, messages and files', (tester) async {
      await pumpCard(tester, client(1, 'Halil Y.')..disconnected = true, makeController(), [],
          endedClosingIn: 5,
          endedInfo: const SenseHostEndInfo(duration: Duration(minutes: 42), messages: 3, files: 1));
      expect(find.text('Bağlantı sona erdi'), findsOneWidget);
      expect(find.text('Sense Department bağlantıyı bitirdi'), findsOneWidget);
      expect(find.text('42 dk'), findsOneWidget);
      expect(find.text('süre'), findsOneWidget);
      expect(find.text('3 mesaj · 1 dosya'), findsOneWidget);
      expect(find.text('sohbet silindi'), findsOneWidget);
      expect(find.text('5 sn sonra bu kart kapanır'), findsOneWidget);
      expect(find.byKey(const Key('sense-host-close')), findsOneWidget);
    });

    testWidgets('FH-A3: ended here says "Bağlantıyı sen bitirdin"; without figures no tiles',
        (tester) async {
      await pumpCard(tester, client(1, 'Halil Y.')..disconnected = true, makeController(), [],
          endedInfo: const SenseHostEndInfo(byHost: true));
      expect(find.text('Bağlantıyı sen bitirdin'), findsOneWidget);
      // No known time: a dash, never a made-up number.
      expect(
          find.descendant(
              of: find.byKey(const Key('sense-host-ended-time')), matching: find.text('–')),
          findsOneWidget);
      expect(find.text('0 mesaj · 0 dosya'), findsOneWidget);

      await pumpCard(tester, client(1, 'Halil Y.')..disconnected = true, makeController(), []);
      expect(find.text('Bağlantı sona erdi'), findsOneWidget);
      expect(find.byKey(const Key('sense-host-ended-time')), findsNothing);
      expect(find.byKey(const Key('sense-host-close')), findsOneWidget);
    });

    testWidgets('#151, #157: the card names what the Controller asked for', (tester) async {
      await pumpCard(tester, client(1, 'Halil Y.'), makeController(), []);
      expect(find.byKey(const Key('sense-host-chat-visible')), findsNothing);
      expect(find.byKey(const Key('sense-host-admin-terminal')), findsNothing);

      await pumpCard(tester, client(1, 'Halil Y.'), makeController(), [],
          chatVisible: true, adminLine: 'Yönetici terminali açık · ekip@example.test');
      expect(find.text('Yönetici terminali açık · ekip@example.test'), findsOneWidget);
      expect(find.text('Bu kart bu oturumda karşı tarafın görüntüsüne giriyor'), findsOneWidget);
      // The connected box keeps its button.
      expect(find.byKey(const Key('sense-host-end')), findsOneWidget);
    });
  });

  group('#101 ended connection closes the window', () {
    test('only when there are connections and all of them ended', () {
      expect(senseCmAllEnded(const []), isFalse);
      expect(senseCmAllEnded(const [false]), isFalse);
      expect(senseCmAllEnded(const [true, false]), isFalse);
      expect(senseCmAllEnded(const [true]), isTrue);
      expect(senseCmAllEnded(const [true, true]), isTrue);
    });

    test('the card counts 5, 4, 3, 2, 1 and then closes', () {
      final at = DateTime(2026, 11, 26, 10);
      expect(kSenseCmEndedLinger, const Duration(seconds: 5));
      expect(senseCmEndedSecondsLeft(at, at), 5);
      expect(senseCmEndedSecondsLeft(at, at.add(const Duration(milliseconds: 1))), 5);
      expect(senseCmEndedSecondsLeft(at, at.add(const Duration(milliseconds: 1001))), 4);
      expect(senseCmEndedSecondsLeft(at, at.add(const Duration(seconds: 4, milliseconds: 500))), 1);
      expect(senseCmEndedSecondsLeft(at, at.add(const Duration(seconds: 5))), 0);
      expect(senseCmEndedSecondsLeft(at, at.add(const Duration(minutes: 1))), 0);
    });

    test('nothing counts down before every connection ended', () {
      SenseCm.cancelEnded();
      expect(SenseCm.endedSecondsLeft(DateTime.now()), isNull);
    });
  });

  group('#107 the window closes 5 s after the end, whatever the card does', () {
    test('a live connection is one that has not ended', () {
      expect(senseCmHasLive(const []), isFalse);
      expect(senseCmHasLive(const [true]), isFalse);
      expect(senseCmHasLive(const [true, false]), isTrue);
    });

    testWidgets('the 0.5 s re-show of ended connections does not stop it',
        (tester) async {
      final closer = SenseCmEndedCloser();
      var closed = 0;
      expect(closer.start(() => closed++), isTrue);
      // Slayer v9: ServerModel shows the window every 0.5 s while the ended
      // connection is still in the list; card / icon clicks do not reach it.
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        expect(closer.onClients(const [true]), isFalse);
        expect(closer.start(() => closed++), isFalse); // not restarted
      }
      expect(closed, 0);
      await tester.pump(const Duration(milliseconds: 500));
      expect(closed, 1);
      expect(closer.pending, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(closed, 1);
    });

    testWidgets('only a new connection stops it', (tester) async {
      final closer = SenseCmEndedCloser();
      var closed = 0;
      closer.start(() => closed++);
      await tester.pump(const Duration(seconds: 3));
      expect(closer.onClients(const [true, false]), isTrue);
      expect(closer.pending, isFalse);
      await tester.pump(const Duration(seconds: 10));
      expect(closed, 0);
      // That one ends too: a fresh 5 s.
      expect(closer.start(() => closed++), isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(closed, 1);
    });

    test('Windows icon window is a popup (no 136 px minimum width)', () {
      const overlappedWindow = 0x00CF0000; // caption, sys menu, frame, min/max
      const visible = 0x10000000;
      const clipChildren = 0x02000000;
      final style = senseCmPopupStyle(overlappedWindow | visible | clipChildren);
      expect(style & kSenseWsPopup, kSenseWsPopup);
      expect(style & kSenseWsCaption, 0);
      expect(style & kSenseWsThickFrame, 0);
      expect(style & kSenseWsMaximizeBox, 0);
      expect(style & visible, visible);
      expect(style & clipChildren, clipChildren);
      // Already a popup: nothing changes (no frame change per resize).
      expect(senseCmPopupStyle(style), style);
      // A sign-extended value from GetWindowLongPtr reads the same.
      expect(senseCmPopupStyle(style | ~0xFFFFFFFF), style);
    });

    test('#109 capture exclusion asks for WDA_EXCLUDEFROMCAPTURE', () {
      expect(kSenseWdaExcludeFromCapture, 0x11);
    });

    test('#151/#172 the switch asks WDA_NONE to show, WDA_EXCLUDEFROMCAPTURE to hide', () {
      expect(senseCmCaptureAffinity(true), 0x11);
      expect(senseCmCaptureAffinity(false), 0x00);
    });
  });

  group('#151/#172: Host kartı görüntüye yalnız istenince girer', () {
    test('only when every live screen connection asked', () {
      // Core answer for one Controller that turned the switch on (conn 7).
      final asked = SenseHostPeerState.parse('{"chat_visible":[7],"admin_terminals":[]}').chatVisible;
      final screen = client(7, 'H');
      expect(senseCmCardInPicture(asked, senseCmLiveScreens([screen])), isTrue);
      // The switch off (core: chat_visible []): out of the picture.
      expect(senseCmCardInPicture(const {}, senseCmLiveScreens([screen])), isFalse);
      // The connection ended: out, whatever the last answer said.
      expect(senseCmCardInPicture(asked, senseCmLiveScreens([screen..disconnected = true])), isFalse);
      // No screen connection at all (terminal, files): out.
      final term = client(8, 'H')..isTerminal = true;
      final file = Client(9, true, true, false, 'H', '1', false, false, false);
      expect(senseCmCardInPicture({8, 9}, senseCmLiveScreens([term, file])), isFalse);
      // A terminal next to the asking screen does not see the screen: still in.
      expect(senseCmCardInPicture({10}, senseCmLiveScreens([client(10, 'H'), term])), isTrue);
      // A second screen connection that did not ask keeps it out (stricter than S8 needs).
      expect(senseCmCardInPicture({10}, senseCmLiveScreens([client(10, 'H'), client(11, 'H')])), isFalse);
      // Not yet accepted: it sees nothing, so it does not count.
      expect(
          senseCmCardInPicture({10}, senseCmLiveScreens([client(10, 'H'), client(12, 'H', authorized: false)])),
          isTrue);
    });

    test('the switch touches the window only on a change and records the real state', () async {
      final calls = <bool>[];
      var ok = true;
      final s = SenseCmCaptureSwitch((excluded) async {
        calls.add(excluded);
        return ok;
      });
      expect(s.wantExcluded, isTrue); // #109: out by default
      expect(await s.set(inPicture: false, why: 'not-asked'), isNull);
      expect(await s.set(inPicture: true, why: 'asked'), {'excluded': false, 'why': 'asked'});
      expect(await s.set(inPicture: true, why: 'asked'), isNull);
      // The connection ended: back out.
      expect(await s.set(inPicture: false, why: 'ended'), {'excluded': true, 'why': 'ended'});
      expect(calls, [false, true]);
      // A failed "put in" leaves the card out, and says so.
      ok = false;
      expect(await s.set(inPicture: true, why: 'asked'), {'excluded': true, 'why': 'asked', 'failed': true});
    });
  });
}

Future<void> pumpBox(WidgetTester tester, Size size, Widget child) async {
  setWindow(tester, size);
  await tester.pumpWidget(app(child, still: true));
  await tester.pump();
}

Future<void> pumpCard(
  WidgetTester tester,
  Client c,
  SenseChatController chat,
  List<String> calls, {
  Duration? recording,
  bool canAccept = true,
  bool canCall = false,
  int? endedClosingIn,
  String? connectionsLine,
  Client? waiting,
  SenseHostEndInfo? endedInfo,
  bool chatVisible = false,
  String? adminLine,
}) async {
  setWindow(tester, kSenseCmPanelSize);
  await tester.pumpWidget(app(
    SenseHostCard(
      client: c,
      chat: chat,
      whoLine: senseHostWhoLine(c, const Duration(minutes: 14)),
      recording: recording,
      canAccept: canAccept,
      canCall: canCall,
      animateIn: false,
      endedClosingIn: endedClosingIn,
      connectionsLine: connectionsLine,
      waiting: waiting,
      endedInfo: endedInfo,
      chatVisible: chatVisible,
      adminLine: adminLine,
      actions: SenseHostCardActions(
        onMinimize: () => calls.add('minimize'),
        onEnd: () => calls.add('end'),
        onAccept: () => calls.add('accept'),
        onReject: () => calls.add('reject'),
        onCloseEnded: () => calls.add('close'),
        onAnswerCall: (a) => calls.add('call $a'),
      ),
    ),
    still: true,
  ));
  await tester.pump();
}
