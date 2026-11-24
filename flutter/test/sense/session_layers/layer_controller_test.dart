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

    test('slow 2 s: "Dalgalı" only; slow forever: never a card', () {
      seconds(2, host.slow);
      expect(c.wavy.value, isTrue);
      expect(c.link.layerUp, isFalse);
      seconds(120, host.slow);
      expect(c.link.layerUp, isFalse, reason: 'delay and loss alone never open the card');
      expect(c.ended, isNull);
    });

    test('fps 3: 14 s no card, 16 s the weak card; the bar keeps the warning', () {
      seconds(14, host.weakFps);
      expect(c.link.layerUp, isFalse);
      seconds(2, host.weakFps);
      expect(c.link.phase, SenseLinkPhase.weak);
      expect(c.wavy.value, isTrue);
    });

    test('fps 0 while the delay measurement keeps coming (still screen): no card, no end', () {
      void still() => host.raw = SenseLinkRaw(
            delay: '20',
            fps: '0',
            lossEst: 0,
            lastFrameMs: 60000,
            lastFrameAt: clock.wall,
            probeAt: clock.wall,
          );
      seconds(120, still);
      expect(c.link.layerUp, isFalse);
      expect(c.ended, isNull);
    });

    test('delay 900 ms with fps 20: no card', () {
      seconds(90, host.highDelay);
      expect(c.link.layerUp, isFalse);
      expect(c.ended, isNull);
    });

    test('no data for 29 s: no card; 32 s: the ended card', () {
      seconds(1, host.healthy);
      seconds(29);
      expect(c.link.layerUp, isFalse);
      expect(c.ended, isNull);
      seconds(3);
      expect(c.ended, isNotNull);
    });

    test('data keeps coming: the layer never closes or reconnects the session', () {
      seconds(300, host.weakFps);
      seconds(300, host.highDelay);
      expect(c.ended, isNull);
      expect(host.calls, isNot(contains('home')));
      expect(host.calls, isNot(contains('reconnect')));
    });

    test('recovered: the toast serial goes up once', () {
      seconds(16, host.weakFps);
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

    test('transport lost (restarting) with no data: "Kesildi" card, session ends after 30 s', () {
      seconds(1, host.healthy);
      seconds(10);
      expect(c.link.layerUp, isFalse);
      expect(c.onMessage('restarting-show', 'Connecting...', 'Connection in progress.'), isTrue);
      expect(c.link.phase, SenseLinkPhase.lost);
      expect(c.ended, isNull);
      seconds(22);
      expect(c.ended!.reason, SenseEndReason.peerGone);
    });

    test('lost card has no "x": minimize does nothing', () {
      seconds(1, host.healthy);
      seconds(10);
      c.onMessage('restarting-show', 'Connecting...', 'Connection in progress.');
      c.minimize();
      expect(c.minimized, isFalse);
    });

    test('"x": the weak card minimizes, stays closed, opens on request', () {
      seconds(16, host.weakFps);
      c.minimize();
      expect(c.minimized, isTrue);
      expect(c.wavy.value, isTrue);
      seconds(60, host.weakFps);
      expect(c.minimized, isTrue, reason: 'the same trouble does not reopen it');
      c.restoreCard();
      expect(c.minimized, isFalse);
      expect(c.link.phase, SenseLinkPhase.weak);
    });

    test('closed card: after recovery a new weak spell reopens it at most every 5 min', () {
      seconds(16, host.weakFps);
      c.minimize();
      seconds(4, host.healthy);
      expect(c.link.phase, SenseLinkPhase.normal);
      seconds(16, host.weakFps);
      expect(c.link.phase, SenseLinkPhase.weak);
      expect(c.minimized, isTrue, reason: 'under 5 min since the "x"');
      seconds(10, host.healthy);
      seconds(5 * 60, host.healthy);
      seconds(16, host.weakFps);
      expect(c.link.phase, SenseLinkPhase.weak);
      expect(c.minimized, isFalse, reason: '5 min passed: the card opens');
    });

    test('a restart on a working link is left to RustDesk', () {
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
