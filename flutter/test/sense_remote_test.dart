// Sense Remote: connection window parts (sense_remote_*.dart,
// common/sense_peer_status.dart) — display map, display info, status box,
// chat panel, ghost toggle, panel peer-status parsing.

import 'dart:convert';

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/sense_peer_status.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart' show TToggleMenu;
import 'package:flutter_hbb/consts.dart' show kAllDisplayValue;
import 'package:flutter_hbb/desktop/widgets/sense_remote_chat.dart';
import 'package:flutter_hbb/desktop/widgets/sense_remote_display_info.dart';
import 'package:flutter_hbb/desktop/widgets/sense_remote_map.dart';
import 'package:flutter_hbb/desktop/widgets/sense_remote_status.dart';
import 'package:flutter_hbb/desktop/widgets/sense_remote_strings.dart';
import 'package:flutter_hbb/desktop/widgets/sense_remote_window.dart';
import 'package:flutter_test/flutter_test.dart';

// Prototype arrangement: 4K main, portrait LED input on the left, 4K above.
const protoDisplays = [
  SenseMapDisplay(index: 0, x: 0, y: 0, width: 3840, height: 2160, primary: true),
  SenseMapDisplay(index: 1, x: -1080, y: 240, width: 1080, height: 1920),
  SenseMapDisplay(index: 2, x: 0, y: -2160, width: 3840, height: 2160),
];

// Panel answer in the shape of packages/shared ClientPeerStatus (§3.3).
// Addresses are documentation ranges (RFC 5737 / 3849), not real devices.
Map<String, Object?> fullStatusJson() => {
      'online': true,
      'last_seen_at': 1000,
      'app_version': 2,
      'role': 'host',
      'health': {
        'at': 990,
        'cpu_pct': 34,
        'gpu_temp_c': 81,
        'mem_used_mb': 18432,
        'mem_total_mb': 32768,
        'disks': [
          {'mount': 'C:', 'used_pct': 72}
        ],
        'uptime_s': 6 * 86400 + 4 * 3600 + 120,
      },
      'displays': [
        {
          'index': 0,
          'name': 'LG 27UN880',
          'x': 0,
          'y': 0,
          'width': 3840,
          'height': 2160,
          'scale': 1.5,
          'refresh_hz': 59.94,
          'connection': 'displayport',
          'bit_depth': 10,
          'color_format': 'rgb',
          'hdr': true,
        },
        {
          'index': 1,
          'x': -1080,
          'y': 240,
          'width': 1080,
          'height': 1920,
          'refresh_hz': 50,
          'connection': 'hdmi',
          'bit_depth': 8,
          'color_format': 'ycbcr422',
          'hdr': false,
        },
        {'index': 2, 'x': 0, 'y': -2160, 'width': 3840, 'height': 2160, 'connection': 'displayport'},
      ],
      // Deliberately out of order: Wi-Fi first; ethernet must come first.
      'network': [
        {'name': 'Wi-Fi', 'kind': 'wifi', 'ipv4': ['192.0.2.30']},
        {'name': 'Ethernet', 'kind': 'ethernet', 'ipv4': ['192.0.2.10']},
        {'name': 'Ethernet 2', 'kind': 'ethernet', 'ipv4': ['198.51.100.7', '198.51.100.8']},
        {'name': 'vEthernet', 'kind': 'other', 'ipv4': [], 'ipv6': ['2001:db8::1']},
      ],
      'envelope': {'state': 'none'},
    };

SensePeerStatus fullStatus() => SensePeerStatus.fromJson(fullStatusJson())!;

void main() {
  group('peer-status parsing', () {
    test('full answer', () {
      final s = fullStatus();
      expect(s.online, isTrue);
      expect(s.appVersion, 2);
      expect(s.health!.cpuPct, 34);
      expect(s.health!.disks.single.mount, 'C:');
      expect(s.displays.length, 3);
      expect(s.display(0)!.refreshHz, 59.94);
      expect(s.display(1)!.colorFormat, 'ycbcr422');
      expect(s.display(7), isNull);
    });

    test('network: ethernet first, order inside a kind kept', () {
      final names = fullStatus().network.map((n) => n.name).toList();
      expect(names, ['Ethernet', 'Ethernet 2', 'Wi-Fi', 'vEthernet']);
    });

    test('missing optional parts stay missing (nothing invented)', () {
      final s = SensePeerStatus.fromJson({
        'online': false,
        'last_seen_at': null,
        'app_version': null,
        'role': null,
        'health': null,
        'displays': [],
        'network': [],
        'envelope': {'state': 'none'},
      })!;
      expect(s.health, isNull);
      expect(s.appVersion, isNull);
      expect(s.displays, isEmpty);
      expect(s.network, isEmpty);
    });

    test('unexpected field types are dropped, not guessed', () {
      final s = SensePeerStatus.fromJson({
        'online': true,
        'app_version': 'iki',
        'displays': [
          {'index': 'x'},
          {'index': 0, 'refresh_hz': '60'},
        ],
      })!;
      expect(s.appVersion, isNull);
      expect(s.displays.single.index, 0);
      expect(s.displays.single.refreshHz, isNull);
      expect(SensePeerStatus.fromJson({'displays': []}), isNull);
    });

    test('HTTP answers', () {
      expect(senseParsePeerStatusResponse(200, jsonEncode(fullStatusJson())).status,
          isNotNull);
      final nf = senseParsePeerStatusResponse(404, '{"error":"not_found"}');
      expect(nf.error, SensePeerStatusError.notFound);
      expect(nf.noPanelInfo, isTrue);
      expect(senseParsePeerStatusResponse(401, '').error,
          SensePeerStatusError.unauthorized);
      final f = senseParsePeerStatusResponse(500, '');
      expect(f.error, SensePeerStatusError.failed);
      expect(f.noPanelInfo, isFalse);
      expect(senseParsePeerStatusResponse(429, '').error,
          SensePeerStatusError.failed);
      expect(senseParsePeerStatusResponse(200, 'not json').error,
          SensePeerStatusError.failed);
    });

    test('client: no key → no request', () async {
      var calls = 0;
      final c = SensePeerStatusClient(
        apiServer: () async => 'https://panel.example.test',
        accessToken: () => '',
        get: (url, headers) async {
          calls++;
          return (statusCode: 200, body: '{}');
        },
      );
      expect((await c.fetch('123456789')).error, SensePeerStatusError.noKey);
      expect(calls, 0);
    });

    test('client: URL, bare id and Bearer header', () async {
      Uri? seen;
      Map<String, String>? seenHeaders;
      final c = SensePeerStatusClient(
        apiServer: () async => 'https://panel.example.test/',
        accessToken: () => 'test-key',
        get: (url, headers) async {
          seen = url;
          seenHeaders = headers;
          return (statusCode: 200, body: jsonEncode(fullStatusJson()));
        },
      );
      final r = await c.fetch('123456789@relay.example.test');
      expect(r.status, isNotNull);
      expect(seen.toString(),
          'https://panel.example.test/api/sense/peer-status?id=123456789');
      expect(seenHeaders, {'Authorization': 'Bearer test-key'});
    });

    test('client: transport error → failed', () async {
      final c = SensePeerStatusClient(
        apiServer: () async => 'https://panel.example.test',
        accessToken: () => 'test-key',
        get: (url, headers) async => throw Exception('offline'),
      );
      expect((await c.fetch('1')).error, SensePeerStatusError.failed);
    });
  });

  group('formatting', () {
    test('numbers and units', () {
      expect(senseFormatHz(59.94), '59,94 Hz');
      expect(senseFormatHz(60), '60 Hz');
      expect(senseFormatHz(143.856), '143,86 Hz');
      expect(senseFormatPct(33.6), '%34');
      expect(senseFormatMemory(18432, 32768), '18/32 GB');
      expect(senseFormatMemory(18842, 32768), '18,4/32 GB');
      expect(senseFormatUptime(6 * 86400 + 4 * 3600 + 120), '6 gün 4 sa');
      expect(senseFormatUptime(3 * 3600 + 12 * 60), '3 sa 12 dk');
      expect(senseFormatUptime(30), "1 dk'dan az");
      expect(senseFormatAgo(12), '12 sn önce');
      expect(senseFormatAgo(3 * 86400), '3 gün önce');
    });
  });

  group('display map', () {
    test('layout keeps the real arrangement and fits the box', () {
      const box = Size(110, 28);
      final r = senseMapLayout(protoDisplays, box);
      for (final rect in r) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(box.width));
        expect(rect.bottom, lessThanOrEqualTo(box.height));
      }
      // Display 2 (portrait) is left of display 1, display 3 above it.
      expect(r[1].right, lessThanOrEqualTo(r[0].left + 0.01));
      expect(r[2].bottom, lessThanOrEqualTo(r[0].top + 0.01));
      expect(r[1].height, greaterThan(r[1].width));
      expect((r[0].width - r[2].width).abs(), lessThan(0.01));
    });

    testWidgets('click a display, then Tümü', (tester) async {
      final picks = <int>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SenseRemoteMapBar(
                displays: protoDisplays, current: 0, onPick: picks.add),
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('sense-remote-map-1')));
      await tester.tap(find.byKey(const ValueKey('sense-remote-all')));
      expect(picks, [1, kAllDisplayValue]);
      expect(find.text('Tümü'), findsOneWidget);
    });

    testWidgets('no Tümü for one display or without multi-display support',
        (tester) async {
      Future<void> pump(List<SenseMapDisplay> d, bool allowAll) =>
          tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: SenseRemoteMapBar(
                  displays: d, current: 0, onPick: (_) {}, allowAll: allowAll),
            ),
          ));
      await pump(protoDisplays.take(1).toList(), true);
      expect(find.text('Tümü'), findsNothing);
      await pump(protoDisplays, false);
      expect(find.text('Tümü'), findsNothing);
    });

    test('titles', () {
      expect(senseDisplayTitle(protoDisplays[0]), 'Ekran 1 · ana');
      expect(senseDisplayTitle(protoDisplays[1]), 'Ekran 2');
    });
  });

  group('display info', () {
    test('rows from the panel: connection, resolution, Hz, colour, HDR', () {
      final rows = senseDisplayInfoRows(protoDisplays[0], fullStatus().display(0))
          .map((r) => r.toString())
          .toList();
      expect(rows, [
        'Bağlantı: DisplayPort',
        'Çözünürlük: 3840 × 2160',
        'Yenileme: 59,94 Hz',
        'Renk: 10 bit · RGB 4:4:4',
        'HDR: HDR açık',
        'Ölçek: %150',
        'Konum: x 0, y 0',
      ]);
    });

    test('without panel data only what RustDesk knows is shown', () {
      final rows = senseDisplayInfoRows(protoDisplays[1], null)
          .map((r) => r.toString())
          .toList();
      expect(rows, ['Çözünürlük: 1080 × 1920', 'Konum: x -1080, y 240']);
    });

    test('YCbCr 4:2:2 gets a note, RGB does not', () {
      final s = fullStatus();
      expect(senseDisplayWarning(s.display(1)), startsWith('YCbCr 4:2:2 — '));
      expect(senseDisplayWarning(s.display(0)), isNull);
    });

    testWidgets('card for one display and for all', (tester) async {
      Future<void> pump(int current, SensePeerStatusResult? r) =>
          tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: SenseDisplayInfoPanel(
                displays: protoDisplays,
                current: current,
                result: r,
                loading: false,
                onRetry: () {},
              ),
            ),
          ));
      final ok = SensePeerStatusResult.ok(fullStatus());
      await pump(1, ok);
      expect(find.text('Ekran 2'), findsOneWidget);
      expect(find.text('HDMI'), findsOneWidget);
      expect(find.text('50 Hz'), findsOneWidget);
      expect(find.textContaining('YCbCr 4:2:2 —'), findsOneWidget);
      expect(find.text('Ekran 1 · ana'), findsNothing);

      await pump(kAllDisplayValue, ok);
      expect(find.text('Ekran 1 · ana'), findsOneWidget);
      expect(find.text('Ekran 2'), findsOneWidget);
      expect(find.text('Ekran 3'), findsOneWidget);

      await pump(0, const SensePeerStatusResult.error(SensePeerStatusError.notFound));
      expect(find.text('Panel bilgisi yok'), findsOneWidget);
      expect(find.text('3840 × 2160'), findsOneWidget);
      expect(find.text('Yeniden dene'), findsNothing);
    });
  });

  group('status box', () {
    test('meters and rows', () {
      final v = senseStatusView(fullStatus(), 1012);
      expect(v.subtitle, 'çevrimiçi · son yoklama 12 sn önce');
      expect(v.meters.map((m) => m.toString()).toList(), [
        'İşlemci: %34',
        'Ekran kartı: 81°C (!)',
        'Bellek: 18/32 GB',
        'Disk C:: %72',
      ]);
      expect(v.rows.map((r) => r.toString()).toList(), [
        'Açık kalma: 6 gün 4 sa',
        'Ekranlar: 3 · DP, HDMI, DP',
        'Sürüm: Sürüm 2',
      ]);
    });

    test('network addresses: ethernet first, several in order', () {
      final rows = senseStatusView(fullStatus(), 1012)
          .network
          .map((r) => r.toString())
          .toList();
      expect(rows, [
        'Ethernet 1: 192.0.2.10',
        'Ethernet 2: 198.51.100.7\n198.51.100.8',
        'Wi-Fi: 192.0.2.30',
        'Diğer: 2001:db8::1',
      ]);
    });

    test('nothing reported → "Bildirilmedi", no invented value', () {
      final v = senseStatusView(
          const SensePeerStatus(online: false, lastSeenAt: 0), 7200);
      expect(v.meters, isEmpty);
      expect(v.subtitle, 'çevrimdışı · son yoklama 2 sa önce');
      expect(v.rows.map((r) => r.toString()).toList(), [
        'Sağlık: Bildirilmedi',
        'Ekranlar: Bildirilmedi',
        'Sürüm: Bildirilmedi',
      ]);
      expect(v.network.map((r) => r.toString()).toList(), ['Ağ: Bildirilmedi']);
    });

    testWidgets('popup shows data; no frame rate or latency', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SenseStatusPopup(
              result: SensePeerStatusResult.ok(fullStatus()),
              loading: false,
              nowS: 1012,
              onRetry: () {},
            ),
          ),
        ),
      ));
      expect(find.textContaining('Bilgisayar durumu'), findsOneWidget);
      expect(find.text('İşlemci'), findsOneWidget);
      expect(find.text('81°C'), findsOneWidget);
      final eth1 = tester.getTopLeft(
          find.byKey(const ValueKey('sense-remote-net-Ethernet 1')));
      final eth2 = tester.getTopLeft(
          find.byKey(const ValueKey('sense-remote-net-Ethernet 2')));
      final wifi =
          tester.getTopLeft(find.byKey(const ValueKey('sense-remote-net-Wi-Fi')));
      expect(eth1.dy, lessThan(eth2.dy));
      expect(eth2.dy, lessThan(wifi.dy));
      expect(find.textContaining('fps'), findsNothing);
      expect(find.textContaining(' ms'), findsNothing);
    });

    testWidgets('panel unreachable → retry; no key → plain note',
        (tester) async {
      var retries = 0;
      Future<void> pump(SensePeerStatusResult r) =>
          tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: SenseStatusPopup(
                  result: r, loading: false, nowS: 0, onRetry: () => retries++),
            ),
          ));
      await pump(const SensePeerStatusResult.error(SensePeerStatusError.failed));
      expect(find.text('Panel bilgisine ulaşılamadı'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sense-remote-retry')));
      expect(retries, 1);
      await pump(const SensePeerStatusResult.error(SensePeerStatusError.noKey));
      expect(find.text('Panel bilgisi yok'), findsOneWidget);
      expect(find.byKey(const ValueKey('sense-remote-retry')), findsNothing);
    });
  });

  group('chat panel', () {
    testWidgets('both directions, send and close', (tester) async {
      final me = ChatUser(id: 'me');
      final them = ChatUser(id: 'peer', firstName: 'Galeri kioskı');
      final sent = <String>[];
      var closed = 0;
      final controller = TextEditingController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            const Spacer(),
            SenseRemoteChatPanel(
              peerName: 'Galeri kioskı',
              messages: [
                ChatMessage(
                    text: 'Tamam.', user: them, createdAt: DateTime(2026, 11, 17, 17, 11)),
                ChatMessage(
                    text: 'Merhaba', user: me, createdAt: DateTime(2026, 11, 17, 17, 10)),
              ],
              myUserId: 'me',
              controller: controller,
              onSend: sent.add,
              onClose: () => closed++,
            ),
          ]),
        ),
      ));
      expect(find.text('Galeri kioskı · sahadaki kişi'), findsOneWidget);
      expect(find.text('Merhaba'), findsOneWidget);
      expect(find.text('Tamam.'), findsOneWidget);
      expect(find.text('17:10'), findsOneWidget);
      // Newest message is at the bottom.
      expect(tester.getTopLeft(find.text('Merhaba')).dy,
          lessThan(tester.getTopLeft(find.text('Tamam.')).dy));
      // Own message on the right.
      expect(tester.getTopLeft(find.text('Merhaba')).dx,
          greaterThan(tester.getTopLeft(find.text('Tamam.')).dx));

      await tester.enterText(
          find.byKey(const ValueKey('sense-remote-chat-input')), '  Ekran 2  ');
      await tester.tap(find.byKey(const ValueKey('sense-remote-chat-send')));
      expect(sent, ['Ekran 2']);

      controller.clear();
      await tester.tap(find.byKey(const ValueKey('sense-remote-chat-send')));
      expect(sent, ['Ekran 2']); // empty text is not sent

      await tester.tap(find.byKey(const ValueKey('sense-remote-chat-close')));
      expect(closed, 1);
      expect(find.byKey(const ValueKey('sense-remote-chat-voice')), findsNothing);
    });
  });

  group('ghost mode toggle', () {
    TToggleMenu menu(bool value, List<bool?> log, {bool enabled = true}) =>
        TToggleMenu(
            child: const Text('x'),
            value: value,
            onChanged: enabled ? log.add : null);

    test('no privacy mode offered → disabled', () {
      expect(senseGhostToggle([], false), isNull);
      expect(senseGhostToggle([menu(false, [], enabled: false)], false), isNull);
    });

    test('off → turns the first available one on', () {
      final a = <bool?>[];
      final b = <bool?>[];
      senseGhostToggle([menu(false, a, enabled: false), menu(false, b)], false)!();
      expect(a, isEmpty);
      expect(b, [true]);
    });

    test('on → turns the active one off', () {
      final a = <bool?>[];
      final b = <bool?>[];
      senseGhostToggle([menu(false, a), menu(true, b)], true)!();
      expect(a, isEmpty);
      expect(b, [false]);
    });

    testWidgets('strip text', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SenseGhostBar()));
      expect(find.textContaining('Hayalet mod açık'), findsOneWidget);
    });
  });

  group('session', () {
    test('opening a box reads the panel once; closing stops the timer',
        () async {
      var calls = 0;
      final s = SenseRemoteSession(
        peerId: '123456789',
        client: SensePeerStatusClient(
          apiServer: () async => 'https://panel.example.test',
          accessToken: () => 'test-key',
          get: (url, headers) async {
            calls++;
            return (statusCode: 200, body: jsonEncode(fullStatusJson()));
          },
        ),
      );
      s.toggleStatus();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(s.result?.status?.appVersion, 2);
      s.toggleInfo(); // fresh data: no second read
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      s.toggleStatus();
      s.toggleInfo();
      s.dispose();
    });

    test('chat open state', () {
      final s = SenseRemoteSession(peerId: '1');
      expect(s.chatOpen, isFalse);
      s.setChatOpen(true);
      expect(s.chatOpen, isTrue);
      s.dispose();
    });
  });

  test('every text key is Turkish and present', () {
    for (final k in ['all', 'info', 'status', 'chat', 'ghost', 'not_reported']) {
      expect(senseRemoteText(k), isNot(k));
    }
    expect(kSenseRemoteText.values.join(' ').toLowerCase(), isNot(contains('rustdesk')));
  });
}
