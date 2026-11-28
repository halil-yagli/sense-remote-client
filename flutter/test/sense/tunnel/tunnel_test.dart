// Sense Remote (Sürüm 12, ST 7): the Sense TCP tunnel window — saved rules, the add check
// (prototype `tunAdd`), the listen error turned into Turkish, the connecting-card host — and
// goldens compared with the prototype `auxTun` (prototype screenshot "S12 — TCP tünel":
// rules, "Dinleniyor", "Dinlenemiyor" with its reason, empty list, add form). Images are made
// on CI (sense-golden.yml); until one exists its test is skipped.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/session/layers/connect_cards.dart';
import 'package:flutter_hbb/sense/screens/shared/aux_window/aux_window_frame.dart';
import 'package:flutter_hbb/sense/screens/tunnel/tunnel_connect.dart';
import 'package:flutter_hbb/sense/screens/tunnel/tunnel_rules.dart';
import 'package:flutter_hbb/sense/screens/tunnel/tunnel_view.dart';
import 'package:flutter_hbb/sense/strings/tunnel.dart';

const String _dir = 'test/goldens/tunnel';
String _file(String name) => '../../goldens/tunnel/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_dir/$name.png').existsSync();

const _pc = 'Giriş Salonu PC-2';

const _rules = [
  SenseTunnelRule(localPort: 8080, host: 'localhost', remotePort: 80),
  SenseTunnelRule(localPort: 3389, host: 'localhost', remotePort: 3389),
  SenseTunnelRule(localPort: 9000, host: 'localhost', remotePort: 9000),
];

/// The text RustDesk's `start_one_port_forward` sends on Windows when the port is taken.
const _inUseText = 'Failed to listen on 3389: Only one usage of each socket address '
    '(protocol/network address/port) is normally permitted. (os error 10048)';

Widget _app(Widget child, {Size size = const Size(1000, 560)}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: true),
        child: ColoredBox(color: SenseColors.bg, child: child),
      ),
    );

class _FakeHost implements SenseConnectHost {
  int retries = 0, closes = 0;
  @override
  String get peerName => _pc;
  @override
  bool connected = false;
  @override
  bool get layerOwnsScreen => false;
  @override
  int get step => 0;
  @override
  bool get trustAvailable => false;
  @override
  Future<bool> remembered() async => false;
  @override
  void login(String password, bool remember) {}
  @override
  void send2fa(String code, bool trust) {}
  @override
  void retry() => retries++;
  @override
  Future<SensePanelInfo?> panelInfo() async => null;
  @override
  void close() => closes++;
}

void main() {
  group('saved rules', () {
    test('port_forwards of the peer options; bad entries skipped, empty host = localhost', () {
      final json = jsonEncode({
        'port_forwards': [
          [8080, 'localhost', 80],
          [3389, '', 3389],
          ['x', 'h', 1],
          [1],
        ]
      });
      expect(senseTunnelRulesFrom(json), const [
        SenseTunnelRule(localPort: 8080, host: 'localhost', remotePort: 80),
        SenseTunnelRule(localPort: 3389, host: 'localhost', remotePort: 3389),
      ]);
      expect(senseTunnelRulesFrom('{}'), isEmpty);
      expect(senseTunnelRulesFrom('not json'), isEmpty);
    });
  });

  group('add check', () {
    test('port 1–65535, "ad:port", no duplicate local port', () {
      expect(senseTunnelValidate('', 'localhost:80', const []).error, SenseTunnelStrings.errPort);
      expect(senseTunnelValidate('0', 'localhost:80', const []).error, SenseTunnelStrings.errPort);
      expect(senseTunnelValidate('65536', 'localhost:80', const []).error, SenseTunnelStrings.errPort);
      expect(senseTunnelValidate('80a', 'localhost:80', const []).error, SenseTunnelStrings.errPort);
      expect(senseTunnelValidate('8080', 'localhost', const []).error, SenseTunnelStrings.errRemote);
      expect(senseTunnelValidate('8080', 'local host:80', const []).error, SenseTunnelStrings.errRemote);
      expect(senseTunnelValidate('8080', 'localhost:0', const []).error, SenseTunnelStrings.errRemote);
      expect(senseTunnelValidate('8080', 'localhost:80', _rules).error, SenseTunnelStrings.errDuplicate(8080));
      final ok = senseTunnelValidate(' 8081 ', ' 192.168.10.42:8080 ', _rules);
      expect(ok.error, isNull);
      expect(ok.rule, const SenseTunnelRule(localPort: 8081, host: '192.168.10.42', remotePort: 8080));
    });
  });

  group('listen error', () {
    test('port taken (Windows 10048, Unix "in use") → its sentence', () {
      expect(senseTunnelListenError(_inUseText), (port: 3389, reason: SenseTunnelStrings.inUse(3389)));
      expect(senseTunnelListenError('Failed to listen on 80: Address already in use (os error 98)')?.reason,
          SenseTunnelStrings.inUse(80));
    });

    test('access denied (10013) and anything else', () {
      expect(
          senseTunnelListenError('Failed to listen on 445: An attempt was made to access a socket in a way '
                  'forbidden by its access permissions. (os error 10013)')
              ?.reason,
          SenseTunnelStrings.denied(445));
      expect(senseTunnelListenError('Failed to listen on 5000: boom')?.reason, SenseTunnelStrings.failed(5000));
    });

    test('other messages are not listen errors', () {
      expect(senseTunnelListenError('Connection reset by peer'), isNull);
      expect(senseTunnelListenError(''), isNull);
    });
  });

  group('connecting cards', () {
    test('no "Bağlanılıyor" card at start (RustDesk connects on first use); the rest passes through', () {
      final inner = _FakeHost();
      final host = SenseTunnelConnectHost(inner);
      expect(host.layerOwnsScreen, isTrue);
      expect(host.peerName, _pc);
      host.retry();
      host.close();
      expect([inner.retries, inner.closes], [1, 1]);
      final c = SenseConnectController(host: host, kind: SenseConnectKind.tunnel, autoStart: false)..showConnecting();
      expect(c.card, isNull);
      // A password asked when a program uses the tunnel still gets its card.
      expect(c.onMessage('input-password', '', '', false), isTrue);
      expect(c.card, SenseConnectCard.password);
      c.dispose();
    });
  });

  group('view', () {
    testWidgets('rules with status; Kapat removes; count of listening rules', (tester) async {
      final removed = <int>[];
      await tester.pumpWidget(_app(SenseTunnelView(
        computer: _pc,
        rules: _rules,
        errors: {3389: SenseTunnelStrings.inUse(3389)},
        onAdd: (_) {},
        onRemove: removed.add,
      )));
      expect(find.text('127.0.0.1:8080'), findsOneWidget);
      expect(find.text(SenseTunnelStrings.remote(_pc, 'localhost:80')), findsOneWidget);
      expect(find.text(SenseTunnelStrings.listening), findsNWidgets(2));
      expect(find.text(SenseTunnelStrings.notListening), findsOneWidget);
      expect(find.text(SenseTunnelStrings.inUse(3389)), findsOneWidget);
      expect(find.text(SenseTunnelStrings.listeningCount(2)), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-tunnel-close-3389')));
      expect(removed, [3389]);
    });

    testWidgets('empty list says what to do', (tester) async {
      await tester.pumpWidget(_app(SenseTunnelView(computer: _pc, rules: const [], onAdd: (_) {}, onRemove: (_) {})));
      expect(find.text(SenseTunnelStrings.emptyTitle), findsOneWidget);
      expect(find.text(SenseTunnelStrings.emptyBody(_pc)), findsOneWidget);
      expect(find.text(SenseTunnelStrings.listeningCount(0)), findsOneWidget);
    });

    testWidgets('Tünel ekle checks first; a good rule is added and the form clears', (tester) async {
      final added = <SenseTunnelRule>[];
      await tester.pumpWidget(_app(SenseTunnelView(computer: _pc, rules: _rules, onAdd: added.add, onRemove: (_) {})));
      await tester.enterText(find.byKey(const Key('sense-tunnel-local')), '8080');
      await tester.enterText(find.byKey(const Key('sense-tunnel-remote')), 'localhost:80');
      await tester.tap(find.byKey(const Key('sense-tunnel-add')));
      await tester.pump();
      expect(find.text(SenseTunnelStrings.errDuplicate(8080)), findsOneWidget);
      expect(added, isEmpty);

      await tester.enterText(find.byKey(const Key('sense-tunnel-local')), '8081');
      await tester.enterText(find.byKey(const Key('sense-tunnel-remote')), 'localhost:81');
      await tester.testTextInput.receiveAction(TextInputAction.done); // Enter adds
      await tester.pump();
      expect(added, const [SenseTunnelRule(localPort: 8081, host: 'localhost', remotePort: 81)]);
      expect(find.byKey(const Key('sense-tunnel-error')), findsNothing);
    });
  });

  group('goldens', () {
    Future<void> shoot(WidgetTester tester, String name, Widget body, {Future<void> Function()? act}) async {
      const size = Size(1000, 560);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
          RepaintBoundary(
            key: const Key('golden'),
            child: SenseAuxWindowFrame(
              title: SenseTunnelStrings.title,
              subject: _pc,
              live: const SenseAuxLive('Doğrudan · ekran açılmadı', SenseLevel.ok),
              actions: SenseAuxWindowActions(onMinimize: () {}, onToggleMaximize: () {}, onClose: () {}),
              child: body,
            ),
          ),
          size: size));
      await tester.pump();
      if (act != null) {
        await act();
        await tester.pump();
      }
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file(name)));
    }

    const n1 = 'tunnel_rules';
    testWidgets('golden: rules, all listening', (tester) async {
      await shoot(
          tester, n1, SenseTunnelView(computer: _pc, rules: _rules, onAdd: (_) {}, onRemove: (_) {}));
    }, skip: _skip(n1), tags: const ['golden']);

    const n2 = 'tunnel_listen_error';
    testWidgets('golden: one rule not listening (port taken)', (tester) async {
      await shoot(
          tester,
          n2,
          SenseTunnelView(
            computer: _pc,
            rules: _rules,
            errors: {3389: senseTunnelListenError(_inUseText)!.reason},
            onAdd: (_) {},
            onRemove: (_) {},
          ));
    }, skip: _skip(n2), tags: const ['golden']);

    const n3 = 'tunnel_empty';
    testWidgets('golden: no tunnel yet', (tester) async {
      await shoot(tester, n3, SenseTunnelView(computer: _pc, rules: const [], onAdd: (_) {}, onRemove: (_) {}));
    }, skip: _skip(n3), tags: const ['golden']);

    const n4 = 'tunnel_add_error';
    testWidgets('golden: add check message', (tester) async {
      await shoot(tester, n4, SenseTunnelView(computer: _pc, rules: _rules, onAdd: (_) {}, onRemove: (_) {}),
          act: () async {
        await tester.enterText(find.byKey(const Key('sense-tunnel-local')), '70000');
        await tester.tap(find.byKey(const Key('sense-tunnel-add')));
      });
    }, skip: _skip(n4), tags: const ['golden']);
  });
}
