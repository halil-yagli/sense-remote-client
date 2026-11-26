// Sense Remote: fake session and clock for the connection layer tests (no device).
import 'package:flutter_hbb/sense/screens/session/layers/layer_controller.dart';

class FakeHost implements SenseLayerHost {
  FakeHost(this.clock);

  final FakeClock clock;
  SenseLinkRaw raw = const SenseLinkRaw();
  int messages = 3;
  int files = 1;
  final calls = <String>[];

  /// A healthy link right now.
  void healthy() => raw = SenseLinkRaw(
        delay: '20',
        fps: '60',
        lossEst: 0.1,
        lastFrameMs: 10,
        lastFrameAt: clock.wall,
        probeAt: clock.wall,
      );

  /// Frames under 5 per second on a link that answers (the weak card's condition).
  void weakFps() => raw = SenseLinkRaw(
        delay: '20',
        fps: '3',
        lossEst: 0.1,
        lastFrameMs: 10,
        lastFrameAt: clock.wall,
        probeAt: clock.wall,
      );

  /// High delay but frames and probes keep coming.
  void highDelay() => raw = SenseLinkRaw(
        delay: '900',
        fps: '20',
        lossEst: 0.1,
        lastFrameMs: 10,
        lastFrameAt: clock.wall,
        probeAt: clock.wall,
      );

  /// A link that answers but slowly.
  void slow() => raw = SenseLinkRaw(
        delay: '272',
        fps: '8',
        lossEst: 5.1,
        lastFrameMs: 10,
        lastFrameAt: clock.wall,
        probeAt: clock.wall,
      );

  @override
  SenseLinkRaw readLink() => raw;
  @override
  int chatMessages() => messages;
  @override
  int chatFiles() => files;
  @override
  void goHome() => calls.add('home');
  @override
  void reconnect() => calls.add('reconnect');
  @override
  void keepAlive() => calls.add('keepAlive');
  @override
  void closePopups() => calls.add('closePopups');
}

class FakeClock {
  Duration mono = Duration.zero;
  DateTime wall = DateTime(2026, 11, 23, 12);

  void advance(Duration d) {
    mono += d;
    wall = wall.add(d);
  }
}

