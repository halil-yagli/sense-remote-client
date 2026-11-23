// Sense Remote: the layers' controller with a fake session and a fake clock
// (YH O13, O14, O15 kabul testleri, the parts that do not need a device).
import 'package:flutter_hbb/sense/screens/session/layers/idle_watch.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_controller.dart';
import 'package:flutter_hbb/sense/screens/session/layers/link_machine.dart';
import 'package:flutter_hbb/sense/screens/session/layers/session_end.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late FakeClock clock;
  late FakeHost host;
  late SenseLayerController c;

  SenseLayerController make({Duration? idle}) => SenseLayerController(
        host: host,
        idleLimit: idle,
        clock: () => clock.mono,
        wall: () => clock.wall,
        autoStart: false,
      );

  /// [n] seconds; [each] runs before every tick (keeps the link healthy / slow).
  void seconds(int n, [void Function()? each]) {
    for (var i = 0; i < n; i++) {
      clock.advance(const Duration(seconds: 1));
      each?.call();
      c.tick();
    }
  }

  setUp(() {
    clock = FakeClock();
    host = FakeHost(clock);
    host.healthy();
    c = make();
  });

  tearDown(() => c.dispose());

  group('O13 through the controller', () {
    test('healthy link: nothing shows', () {
      seconds(20, host.healthy);
      expect(c.link.layerUp, isFalse);
      expect(c.wavy.value, isFalse);
      expect(c.ended, isNull);
    });

    test('slow 2 s: "Dalgalı" only; slow 5 s: weak layer', () {
      seconds(2, host.slow);
      expect(c.wavy.value, isTrue);
      expect(c.link.layerUp, isFalse);
      seconds(3, host.slow);
      expect(c.link.layerUp, isFalse, reason: '4 s since the first bad second');
      seconds(1, host.slow);
      expect(c.link.phase, SenseLinkPhase.weak);
      expect(c.wavy.value, isFalse);
    });

    test('frozen link (no event at all): lost after 3 s, by the own tick', () {
      seconds(2, host.healthy);
      // From here no event arrives: raw stays as it was, only time passes.
      seconds(3);
      expect(c.link.layerUp, isFalse, reason: '3 s since the last frame, probe late 2 s');
      seconds(1);
      expect(c.link.layerUp, isFalse, reason: 'probe 4 s old: late 2.98 s');
      seconds(1);
      expect(c.link.phase, SenseLinkPhase.lost);
    });

    test('recovered: the toast serial goes up once', () {
      seconds(6, host.slow);
      expect(c.link.layerUp, isTrue);
      final before = c.recoveredSerial;
      seconds(3, host.healthy);
      expect(c.link.layerUp, isTrue, reason: '"toparlandı" counts down');
      seconds(1, host.healthy);
      expect(c.link.layerUp, isFalse);
      expect(c.recoveredSerial, before + 1);
      seconds(5, host.healthy);
      expect(c.recoveredSerial, before + 1);
    });

    test('30 s frozen: the ended card, reason "Uzak bilgisayar…", popups closed', () {
      seconds(1, host.healthy);
      seconds(32);
      expect(c.ended, isNotNull);
      expect(c.ended!.reason, SenseEndReason.peerGone);
      expect(host.calls, contains('closePopups'));
    });

    test('"Bağlantıyı bitir" closes the window', () {
      c.endByUser();
      expect(host.calls, ['home']);
    });
  });

  group('O14', () {
    test('Host message: card with reason, duration and chat summary; RustDesk dialog taken', () {
      seconds(42 * 60, host.healthy);
      expect(c.onMessage('error', 'Connection Error', 'Closed manually by the peer'), isTrue);
      final e = c.ended!;
      expect(e.reason, SenseEndReason.hostEnded);
      expect(e.duration, const Duration(minutes: 42));
      expect(e.messages, 3);
      expect(e.files, 1);
      expect(c.backHomeIn, 5);
    });

    test('other dialogs pass through to RustDesk', () {
      expect(c.onMessage('re-input-password', 'Password', 'Wrong Password'), isFalse);
      expect(c.ended, isNull);
    });

    test('5 s later it returns home by itself', () {
      c.onMessage('error', 'Connection Error', 'Reset by the peer');
      seconds(4);
      expect(c.backHomeIn, 1);
      expect(host.calls, isNot(contains('home')));
      seconds(1);
      expect(host.calls, contains('home'));
    });

    test('while the card is up RustDesk retry dialogs stay away', () {
      c.onMessage('error', 'Connection Error', 'Reset by the peer');
      expect(c.onMessage('restarting-show', 'Connecting...', 'Connection in progress.'), isTrue);
      expect(c.onMessage('error', 'Connection Error', 'Timeout'), isTrue);
    });

    test('"Kapat" goes home', () {
      c.onMessage('error', 'Connection Error', 'Closed manually by the peer');
      c.closeEnded();
      expect(host.calls.last, 'home');
    });

    test('"Yeniden bağlan": same computer; the count waits; a new probe closes the card', () {
      c.onMessage('error', 'Connection Error', 'Closed manually by the peer');
      c.reconnectEnded();
      expect(host.calls, contains('reconnect'));
      expect(c.reconnectState, SenseReconnectState.connecting);
      seconds(8); // no probe yet: no return home while connecting
      expect(host.calls, isNot(contains('home')));
      expect(c.ended, isNotNull);
      clock.advance(const Duration(seconds: 1));
      host.healthy();
      c.tick();
      expect(c.ended, isNull);
      expect(c.reconnectState, SenseReconnectState.idle);
      seconds(10, host.healthy);
      expect(c.link.layerUp, isFalse);
    });

    test('"Yeniden bağlan" to a busy computer says Meşgul and counts down again', () {
      c.onMessage('error', 'Connection Error', 'Closed manually by the peer');
      seconds(2);
      c.reconnectEnded();
      expect(c.onMessage('error', 'Login Error', 'sense_busy'), isTrue);
      expect(c.reconnectState, SenseReconnectState.busy);
      expect(c.backHomeIn, 5);
      seconds(5);
      expect(host.calls, contains('home'));
    });

    test('RustDesk reconnect after its 30 s timeout while "Kesildi" is up ends the session', () {
      seconds(1, host.healthy);
      seconds(10);
      expect(c.link.phase, SenseLinkPhase.lost);
      expect(c.onMessage('restarting-show', 'Connecting...', 'Connection in progress.'), isTrue);
      expect(c.ended!.reason, SenseEndReason.peerGone);
    });

    test('a restart without an outage is left to RustDesk', () {
      seconds(3, host.healthy);
      expect(c.onMessage('restarting-show', 'Connecting...', 'Connection in progress.'), isFalse);
    });
  });

  group('O15', () {
    setUp(() {
      c.dispose();
      c = make(idle: const Duration(minutes: 30));
    });

    test('strip exactly 1 min before; counts down; idle card at zero', () {
      seconds(29 * 60 - 1, host.healthy);
      expect(c.idle.warning, isFalse);
      seconds(1, host.healthy);
      expect(c.idle.warning, isTrue);
      expect(c.idle.secondsLeft, 60);
      seconds(5, host.healthy);
      expect(c.idle.secondsLeft, 55);
      seconds(55, host.healthy);
      expect(c.ended!.reason, SenseEndReason.idle);
      expect(c.ended!.reasonText, '30 dk hareketsiz kaldığı için kapandı');
    });

    test('"Devam et" resets the time and tells the Host', () {
      seconds(29 * 60 + 10, host.healthy);
      expect(c.idle.warning, isTrue);
      c.keepGoing();
      expect(c.idle.phase, SenseIdlePhase.active);
      expect(host.calls, contains('keepAlive'));
      seconds(29 * 60 - 1, host.healthy);
      expect(c.idle.warning, isFalse);
      seconds(1, host.healthy);
      expect(c.idle.warning, isTrue);
    });

    test('mouse / keyboard input resets the time', () {
      seconds(29 * 60 + 30, host.healthy);
      c.activity();
      expect(c.idle.warning, isFalse);
      seconds(60, host.healthy);
      expect(c.ended, isNull);
    });

    test('the limit comes from the panel value', () {
      c.idleLimit = const Duration(minutes: 10);
      seconds(9 * 60, host.healthy);
      expect(c.idle.secondsLeft, 60);
    });
  });
}
