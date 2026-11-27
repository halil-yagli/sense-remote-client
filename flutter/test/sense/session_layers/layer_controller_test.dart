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

    test('fps 2 on a still screen (good link, little data): no card (K44, #118)', () {
      void stillLow() => host.raw = SenseLinkRaw(
            delay: '5',
            fps: '2',
            lossEst: 0,
            lastFrameMs: 10,
            lastFrameAt: clock.wall,
            probeAt: clock.wall,
            speed: '20kB/s',
          );
      seconds(30, stillLow);
      expect(c.link.layerUp, isFalse);
      expect(c.link.sample.still, isTrue);
      expect(c.ended, isNull);
    });

    test('delay 900 ms with fps 20: no card', () {
      seconds(90, host.highDelay);
      expect(c.link.layerUp, isFalse);
      expect(c.ended, isNull);
    });

    // Sürüm 11 (O1): a link that was up and went silent (TCP says nothing by itself) is
    // reconnected for real; the session ends 30 s later only if it does not come back.
    test('no data: 10 s quiet, then the lost card with real attempts; ended 30 s later', () {
      seconds(1, host.healthy);
      seconds(11);
      expect(c.link.layerUp, isFalse);
      expect(host.calls, isNot(contains('retry')));
      seconds(2);
      expect(c.link.phase, SenseLinkPhase.lost);
      expect(host.calls.where((x) => x == 'retry').length, 1);
      seconds(28);
      expect(c.ended, isNull);
      expect(host.calls.where((x) => x == 'retry').length, 5, reason: '1, 2, 4, 8, 8 s apart');
      expect(c.link.attempt, 5, reason: 'the card counts the real attempts');
      seconds(1);
      expect(c.ended!.reason, SenseEndReason.peerGone);
    });

    test('an attempt that works: the card goes, the policy is read again, no end', () {
      var reloads = 0;
      c.onReconnected = () => reloads++;
      seconds(1, host.healthy);
      seconds(14);
      expect(c.link.phase, SenseLinkPhase.lost);
      expect(host.calls, contains('retry'));
      seconds(4, host.healthy);
      expect(c.link.layerUp, isFalse);
      expect(c.ended, isNull);
      expect(reloads, 1);
      expect(c.recoveredSerial, 1);
    });

    test('the Host never answered yet (waiting for approval): no attempts', () {
      host.raw = const SenseLinkRaw();
      seconds(25);
      expect(host.calls, isNot(contains('retry')));
      expect(c.link.layerUp, isFalse);
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

    test('frozen and never back: the ended card, reason "Uzak bilgisayar…", popups closed', () {
      seconds(1, host.healthy);
      seconds(42);
      expect(c.ended, isNotNull);
      expect(c.ended!.reason, SenseEndReason.peerGone);
      expect(host.calls, contains('closePopups'));
    });

    // Sürüm 11 (O2): every window of the connection closes, not only this one.
    test('"Bağlantıyı bitir" ends the connection in every window', () {
      c.endByUser();
      expect(host.calls, ['end']);
    });

    test('ended in another window of the connection: this one closes too', () {
      seconds(3, host.healthy);
      expect(c.onMessage('error', 'Connection Error', 'sense_ended_here'), isTrue);
      expect(host.calls, contains('home'));
      expect(c.ended, isNull, reason: 'no ended card, the window just goes');
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
      // Sürüm 11 (O1): real attempts during the 30 s; RustDesk's dialogs of the failed rounds
      // stay away.
      seconds(2);
      expect(host.calls, contains('retry'));
      expect(c.onMessage('error', 'Connection Error', 'Failed to connect via rendezvous server'), isTrue);
      expect(c.onMessage('restarting-show', 'Connecting...', 'Connection in progress.'), isTrue);
      seconds(27);
      expect(c.ended, isNull);
      seconds(1);
      expect(c.ended!.reason, SenseEndReason.peerGone);
    });

    test('a reset on a link that was up reconnects instead of ending at once', () {
      seconds(3, host.healthy);
      expect(c.onMessage('error', 'Connection Error', 'Reset by the peer'), isTrue);
      expect(c.ended, isNull);
      expect(c.link.phase, SenseLinkPhase.lost);
      seconds(1);
      expect(host.calls, contains('retry'));
    });

    // Sürüm 11 (O7): the first login to a busy computer gets the Sense card, in Turkish.
    test('busy at the first login: Sense card "Meşgul", RustDesk dialog taken', () {
      expect(c.onMessage('error', 'Login Error', 'sense_busy'), isTrue);
      expect(c.ended!.reason, SenseEndReason.busy);
      expect(c.ended!.reasonText, 'Meşgul — şu an başka biri bağlı');
    });

    test('"Yeniden bağlan" without an answer gives the buttons back after 20 s', () {
      c.onMessage('error', 'Connection Error', 'Closed manually by the peer');
      c.reconnectEnded();
      seconds(19);
      expect(c.reconnectState, SenseReconnectState.connecting);
      seconds(1);
      expect(c.reconnectState, SenseReconnectState.idle);
      expect(c.reconnectFailed, isTrue);
      expect(c.backHomeIn, 5);
    });

    test('"Yeniden bağlan" and a connection error: not stuck on "Bağlanıyor…"', () {
      c.onMessage('error', 'Connection Error', 'Closed manually by the peer');
      c.reconnectEnded();
      expect(c.onMessage('error', 'Connection Error', 'Failed to connect via relay server'), isTrue);
      expect(c.reconnectState, SenseReconnectState.idle);
      expect(c.reconnectFailed, isTrue);
    });

    test('"Yeniden bağlan" that works reads the idle limit again', () {
      var reloads = 0;
      c.onReconnected = () => reloads++;
      c.onMessage('error', 'Connection Error', 'Closed manually by the peer');
      c.reconnectEnded();
      clock.advance(const Duration(seconds: 1));
      host.healthy();
      c.tick();
      expect(c.ended, isNull);
      expect(reloads, 1);
    });

    // Sürüm 11 (#121): logged in, no picture: "Görüntü bekleniyor" instead of black.
    test('no picture 3 s after login: the waiting card; it goes with the first picture', () {
      void waiting() => host.raw = SenseLinkRaw(
          delay: '20', fps: '0', probeAt: clock.wall, waitingImage: true);
      seconds(3, waiting); // first seen at 1 s
      expect(c.waitingImage, isFalse);
      seconds(1, waiting);
      expect(c.waitingImage, isTrue);
      seconds(1, host.healthy);
      expect(c.waitingImage, isFalse);
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

    // Sürüm 10 (#110): the logo area opens the connection card.
    test('logo area: minimized weak card comes back; good link opens the info card', () {
      seconds(16, host.weakFps);
      c.minimize();
      expect(c.minimized, isTrue);
      c.openCard();
      expect(c.minimized, isFalse);
      expect(c.infoOpen, isFalse, reason: 'the weak card itself, not the info card');
      seconds(4, host.healthy);
      expect(c.link.phase, SenseLinkPhase.normal);
      c.openCard();
      expect(c.infoOpen, isTrue);
      seconds(5, host.healthy);
      expect(c.infoOpen, isTrue, reason: 'stays open and follows the values');
      c.closeInfo();
      expect(c.infoOpen, isFalse);
    });

    test('info card gives way to the weak card and to the ended card; no reopen by itself', () {
      seconds(2, host.healthy);
      c.openCard();
      expect(c.infoOpen, isTrue);
      seconds(16, host.weakFps);
      expect(c.link.phase, SenseLinkPhase.weak);
      expect(c.infoOpen, isFalse);
      seconds(4, host.healthy);
      expect(c.link.phase, SenseLinkPhase.normal);
      expect(c.infoOpen, isFalse, reason: 'only a new click opens it');
      c.openCard();
      expect(c.onMessage('error', 'Connection Error', 'Closed manually by the peer'), isTrue);
      expect(c.ended, isNotNull);
      expect(c.infoOpen, isFalse);
      c.openCard();
      expect(c.infoOpen, isFalse, reason: 'nothing opens over the ended card');
    });

    test('connection type of the last reading', () {
      expect(c.direct, isNull);
      host.raw = SenseLinkRaw(delay: '20', fps: '60', lastFrameMs: 10, lastFrameAt: clock.wall, probeAt: clock.wall, direct: false);
      seconds(1);
      expect(c.direct, isFalse);
      host.healthy();
      seconds(1);
      expect(c.direct, isFalse, reason: 'an unknown reading keeps the last type');
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

    // Sürüm 11 (O3): input in another window of the same connection counts here too.
    test('input in another window of the connection resets the time', () {
      seconds(29 * 60 + 10, host.healthy);
      expect(c.idle.warning, isTrue);
      host.sharedIdleValue = const Duration(seconds: 2);
      seconds(1, host.healthy);
      expect(c.idle.warning, isFalse);
      host.sharedIdleValue = null;
      seconds(60, host.healthy);
      expect(c.ended, isNull);
    });

    test('input in this window goes to the shared count at most once a second', () {
      c.activity();
      c.activity();
      expect(host.shared, 1);
      clock.advance(const Duration(seconds: 1));
      c.activity();
      expect(host.shared, 2);
    });

    test('the limit comes from the panel value', () {
      c.idleLimit = const Duration(minutes: 10);
      seconds(9 * 60, host.healthy);
      expect(c.idle.secondsLeft, 60);
    });
  });
}
