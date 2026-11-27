// Sense Remote (Sürüm 12, #164, U164): connecting cards — which core message gives which card
// (texts copied from the core: client.rs handle_login_error / LOGIN_ERROR_MAP, connection.rs
// send_login_error, io_loop.rs, S8 sense_busy), the controller, the record events, the hub
// order and a golden image per card.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/diag_log.dart';
import 'package:flutter_hbb/sense/screens/session/layers/connect_cards.dart';
import 'package:flutter_hbb/sense/screens/session/layers/data/session_hub.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_controller.dart' show SenseReconnectState;
import 'package:flutter_hbb/sense/screens/session/layers/layer_views.dart';
import 'package:flutter_hbb/sense/screens/session/layers/link_machine.dart';
import 'package:flutter_hbb/sense/screens/session/layers/session_end.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const String _goldenDir = 'test/goldens/connect_cards';
String _golden(String name) => '../../goldens/connect_cards/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_goldenDir/$name.png').existsSync();

SenseConnectController _controller(FakeConnectHost host, [SenseConnectKind kind = SenseConnectKind.screen]) =>
    SenseConnectController(host: host, kind: kind, autoStart: false);

void main() {
  late List<(String, String, Map<String, Object?>)> events;

  setUp(() {
    events = [];
    senseDiagEventTestSink = (c, k, f) => events.add((c, k, f));
  });
  tearDown(() => senseDiagEventTestSink = null);

  group('core message → card', () {
    const cases = <(String, String, String, SenseConnectCard?)>[
      ('input-password', 'Password Required', '', SenseConnectCard.password),
      ('re-input-password', 'Wrong Password', 'Do you want to enter again?', SenseConnectCard.passwordWrong),
      ('input-2fa', '2FA Required', '', SenseConnectCard.otp),
      ('input-2fa', 'Wrong 2FA Code', '', SenseConnectCard.otpWrong),
      ('wait-remote-accept-nook', 'Prompt', 'Please wait for the remote side to accept your session request...',
          SenseConnectCard.waitingAccept),
      ('error', 'Login Error', 'sense_busy', SenseConnectCard.busy),
      ('error', 'Connection Error', 'Remote desktop is offline', SenseConnectCard.offline),
      ('error', 'Login Error', 'Offline', SenseConnectCard.offline),
      ('error', 'Connection Error', 'ID does not exist', SenseConnectCard.notFound),
      ('error', 'Login Error', 'Connection not allowed', SenseConnectCard.denied),
      ('error', 'Login Error', 'Your ID is blocked by the peer', SenseConnectCard.denied),
      ('error', 'Login Error', 'No permission of file transfer', SenseConnectCard.noPermission),
      ('error', 'Login Error', 'No permission of terminal', SenseConnectCard.noPermission),
      ('error', 'Connection Error', 'Incoming only mode', SenseConnectCard.noPermission),
      ('error', 'Connection Error', 'Timeout', SenseConnectCard.timeout),
      ('error', 'Connection Error', 'deadline has elapsed', SenseConnectCard.timeout),
      ('error', 'Connection Error', 'Failed to connect to rendezvous server', SenseConnectCard.network),
      ('error', 'Connection Error', 'Failed to connect via relay server: x', SenseConnectCard.network),
      ('error', 'Connection Error', 'Reset by the peer', SenseConnectCard.failed),
      // A security warning keeps the stock box word for word.
      ('error', 'Connection Error', 'Key mismatch', null),
      ('custom-nook-nocancel-hasclose', 'Take screenshot', 'x', null),
      ('info', 'Prompt', 'Something else', null),
    ];
    for (final (type, title, text, card) in cases) {
      test('$type · $title · $text → $card', () {
        expect(senseConnectCardOf(type, title, text), card);
      });
    }
  });

  group('controller', () {
    test('a known message is taken and recorded as ui/card', () {
      final host = FakeConnectHost();
      final c = _controller(host);
      expect(c.onMessage('error', 'Login Error', 'sense_busy', false), isTrue);
      expect(c.card, SenseConnectCard.busy);
      expect(events.last, ('ui', 'card', {'kind': 'busy'}));
    });

    test('an unknown message is left to the stock box', () {
      final c = _controller(FakeConnectHost());
      expect(c.onMessage('error', 'Connection Error', 'Key mismatch', false), isFalse);
      expect(c.card, isNull);
    });

    test('once connected only the login cards are taken (a reconnect may ask again)', () {
      final host = FakeConnectHost()..connected = true;
      final c = _controller(host);
      expect(c.onMessage('error', 'Login Error', 'sense_busy', false), isFalse,
          reason: 'the session layers show busy / ended');
      expect(c.onMessage('input-password', 'Password Required', '', false), isTrue);
      expect(c.card, SenseConnectCard.password);
    });

    test('password: login with the remember choice, then Bağlanılıyor at step 1', () {
      final host = FakeConnectHost();
      final c = _controller(host);
      c.onMessage('input-password', 'Password Required', '', false);
      c.submitPassword('   ');
      expect(host.calls, isEmpty, reason: 'empty password is not sent');
      c.setRemember(true);
      c.submitPassword('gizli123');
      expect(host.calls, ['login:8:true']);
      expect(c.card, SenseConnectCard.connecting);
      expect(c.step, 1);
    });

    test('2-step code: spaces dropped, trust choice sent', () {
      final host = FakeConnectHost();
      final c = _controller(host);
      c.onMessage('input-2fa', '2FA Required', '', false);
      c.setTrust(true);
      c.submitCode('123 456');
      expect(host.calls, ['2fa:123456:true']);
    });

    test('Bağlanılıyor steps aside when the session is up', () {
      final host = FakeConnectHost();
      final c = _controller(host)..showConnecting();
      host.step = 1;
      c.tick();
      expect(c.card, SenseConnectCard.connecting);
      expect(c.step, 1);
      host
        ..step = 2
        ..connected = true;
      c.tick();
      expect(c.card, isNull);
    });

    test('no Bağlanılıyor over the ended / lost card of the session layers', () {
      final host = FakeConnectHost()..layerOwnsScreen = true;
      final c = _controller(host)..showConnecting();
      expect(c.card, isNull);
    });

    test('RustDesk retry flag: the card counts down, retries, and doubles the wait', () {
      final host = FakeConnectHost();
      final c = _controller(host);
      c.onMessage('error', 'Connection Error', 'Timeout', true);
      expect(c.card, SenseConnectCard.timeout);
      expect(c.retryIn, 1);
      c.tick();
      expect(host.calls, ['retry']);
      expect(c.card, SenseConnectCard.connecting);
      c.onMessage('error', 'Connection Error', 'Timeout', true);
      expect(c.retryIn, 2);
      c.retryNow();
      c.onMessage('error', 'Connection Error', 'Timeout', true);
      expect(c.retryIn, 1, reason: 'a pressed "Yeniden dene" starts the wait over');
    });

    test('Kapat closes the window', () {
      final host = FakeConnectHost();
      final c = _controller(host)..onMessage('error', 'Connection Error', 'Remote desktop is offline', false);
      c.close();
      expect(host.calls, ['close']);
    });
  });

  group('stock fallback', () {
    test('counted and recorded as ui/dialog', () {
      final before = SenseConnectCards.stockDialogs;
      SenseConnectCards.noteStockDialog('custom-nook-nocancel-hasclose');
      SenseConnectCards.noteStockDialog('', title: 'Connection Error');
      expect(SenseConnectCards.stockDialogs, before + 2);
      expect(events.map((e) => (e.$1, e.$2, e.$3['kind'])).toList(), [
        ('ui', 'dialog', 'custom-nook-nocancel-hasclose'),
        ('ui', 'dialog', 'Connection_Error'),
      ]);
    });

    test('a known card does not count as a stock box', () {
      final before = SenseConnectCards.stockDialogs;
      _controller(FakeConnectHost()).onMessage('input-password', 'Password Required', '', false);
      expect(SenseConnectCards.stockDialogs, before);
    });
  });

  group('hub', () {
    test('the connecting cards are asked before the session layers', () {
      final seen = <String>[];
      bool layer(String type, String title, String text) {
        seen.add('layer');
        return true;
      }

      bool connect(String type, String title, String text, bool retry) {
        seen.add('connect:$retry');
        return type == 'input-password';
      }

      SenseSessionHub.register('h1', layer);
      SenseSessionHub.registerConnect('h1', connect);
      expect(SenseSessionHub.onMessage('h1', 'input-password', '', '', hasRetry: true), isTrue);
      expect(seen, ['connect:true']);
      expect(SenseSessionHub.onMessage('h1', 'error', 'Connection Error', 'x'), isTrue);
      expect(seen, ['connect:true', 'connect:false', 'layer']);
      SenseSessionHub.unregisterConnect('h1', connect);
      SenseSessionHub.unregister('h1', layer);
      expect(SenseSessionHub.onMessage('h1', 'input-password', '', ''), isFalse);
    });

    test('onConnecting reaches the card only while one is registered', () {
      var shown = 0;
      bool connect(String a, String b, String c, bool d) => false;
      expect(SenseSessionHub.onConnecting('h2'), isFalse);
      SenseSessionHub.registerConnect('h2', connect, onConnecting: () => shown++);
      expect(SenseSessionHub.onConnecting('h2'), isTrue);
      expect(shown, 1);
      SenseSessionHub.unregisterConnect('h2', connect);
      expect(SenseSessionHub.onConnecting('h2'), isFalse);
    });

    test('FO-A12: reconnect attempts reach a listener; forget clears them', () {
      final n = SenseSessionHub.reconnect('h3');
      final values = <SenseReconnectInfo?>[];
      n.addListener(() => values.add(n.value));
      SenseSessionHub.setReconnect('h3', const SenseReconnectInfo(attempt: 2, closeIn: 18));
      SenseSessionHub.setReconnect('h3', const SenseReconnectInfo(attempt: 2, closeIn: 18));
      SenseSessionHub.forget('h3');
      expect(values, [const SenseReconnectInfo(attempt: 2, closeIn: 18), null]);
    });
  });

  group('layer widget', () {
    testWidgets('takes messages through the hub and draws the card; Bağlan logs in', (tester) async {
      final host = FakeConnectHost();
      final c = _controller(host);
      await pumpCard(tester, SenseConnectLayer(id: 'w1', controller: c));
      expect(find.byType(SenseConnectCardView), findsNothing);
      expect(SenseSessionHub.onMessage('w1', 'input-password', 'Password Required', ''), isTrue);
      await tester.pump();
      expect(find.text('Parola gerekiyor'), findsOneWidget);
      expect(find.text('Galeri kioskı bağlantı için parola istiyor.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('sense-connect-field')), 'abc');
      await tester.tap(find.byKey(const Key('sense-connect-connect')));
      await tester.pump();
      expect(host.calls, ['login:3:false']);
      expect(find.text('Bağlanılıyor'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(SenseSessionHub.onMessage('w1', 'input-password', '', ''), isFalse,
          reason: 'unregistered when the page goes');
    });

    testWidgets('no card = no clicks taken', (tester) async {
      final c = _controller(FakeConnectHost());
      await pumpCard(tester, SenseConnectLayer(id: 'w2', controller: c));
      expect(find.byType(SenseConnectCardView), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('Çevrimdışı: Kapat closes, Yeniden dene retries', (tester) async {
      final host = FakeConnectHost();
      final c = _controller(host)..onMessage('error', 'Connection Error', 'Remote desktop is offline', false);
      await pumpCard(tester, SenseConnectCardView(controller: c));
      expect(find.text('Çevrimdışı'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-connect-retry')));
      await tester.pump();
      expect(host.calls, ['retry']);
      c.onMessage('error', 'Connection Error', 'Remote desktop is offline', false);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-connect-close')));
      expect(host.calls, ['retry', 'close']);
    });

    testWidgets('the other window kinds name what they connect for', (tester) async {
      final c = _controller(FakeConnectHost(), SenseConnectKind.file)..showConnecting();
      await pumpCard(tester, SenseConnectCardView(controller: c));
      expect(find.text('Uzak dosyalar · Galeri kioskı'), findsOneWidget);
    });
  });

  group('golden (#164, prototype Durum seçicisi)', () {
    Future<void> card(WidgetTester tester, String name, void Function(SenseConnectController c, FakeConnectHost h) set,
        {SenseConnectKind kind = SenseConnectKind.screen}) async {
      final host = FakeConnectHost();
      final c = _controller(host, kind);
      set(c, host);
      await pumpCard(tester, SenseConnectCardView(controller: c));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden(name)));
    }

    final cards = <String, void Function(SenseConnectController, FakeConnectHost)>{
      'connecting': (c, h) {
        h.step = 1;
        c.showConnecting();
        c.tick();
      },
      'wait_accept': (c, h) => c.onMessage('wait-remote-accept-nook', 'Prompt', '', false),
      'busy': (c, h) => c.onMessage('error', 'Login Error', 'sense_busy', false),
      'offline': (c, h) => c.onMessage('error', 'Connection Error', 'Remote desktop is offline', false),
      'password': (c, h) => c.onMessage('input-password', 'Password Required', '', false),
      'wrong_password': (c, h) => c.onMessage('re-input-password', 'Wrong Password', '', false),
      'otp': (c, h) => c.onMessage('input-2fa', '2FA Required', '', false),
      'denied': (c, h) => c.onMessage('error', 'Login Error', 'Connection not allowed', false),
      'no_permission': (c, h) => c.onMessage('error', 'Login Error', 'No permission of terminal', false),
      'timeout': (c, h) => c.onMessage('error', 'Connection Error', 'Timeout', true),
      'network': (c, h) => c.onMessage('error', 'Connection Error', 'Failed to connect to rendezvous server', false),
    };
    for (final e in cards.entries) {
      testWidgets('golden ${e.key}', (tester) async {
        await card(tester, e.key, e.value);
      }, skip: _skip(e.key), tags: ['golden']);
    }

    testWidgets('golden files_connecting', (tester) async {
      await card(tester, 'files_connecting', (c, h) => c.showConnecting(), kind: SenseConnectKind.file);
    }, skip: _skip('files_connecting'), tags: ['golden']);

    // The same family's session cards (layer_views.dart), drawn on the same ground so all
    // thirteen states of the prototype can be compared side by side.
    testWidgets('golden waiting_image', (tester) async {
      await pumpCard(tester, SenseWaitingImageLayer(direct: false, onEnd: () {}));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('waiting_image')));
    }, skip: _skip('waiting_image'), tags: ['golden']);

    testWidgets('golden ended', (tester) async {
      await pumpCard(
          tester,
          SenseEndedLayer(
            summary: const SenseSessionSummary(
              reason: SenseEndReason.hostEnded,
              duration: Duration(minutes: 42),
              messages: 3,
              files: 1,
              idleLimit: Duration(minutes: 30),
            ),
            backHomeIn: 5,
            reconnect: SenseReconnectState.idle,
            onClose: () {},
            onReconnect: () {},
          ));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('ended')));
    }, skip: _skip('ended'), tags: ['golden']);

    testWidgets('golden lost', (tester) async {
      await pumpCard(
          tester,
          SenseLinkLayer(
            view: const SenseLinkView(
              phase: SenseLinkPhase.lost,
              sample: SenseLinkSample(fps: 0),
              stall: Duration(seconds: 9),
              retries: 2,
              lostFor: Duration(seconds: 9),
            ),
            onEnd: () {},
          ));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('lost')));
    }, skip: _skip('lost'), tags: ['golden']);
  });
}
