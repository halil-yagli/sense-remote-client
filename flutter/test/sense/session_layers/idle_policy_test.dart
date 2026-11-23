// Sense Remote: YH O15, the idle limit comes from peer-status `idle_disconnect_min`.
import 'package:flutter_hbb/sense/screens/session/data/sense_peer_status.dart';
import 'package:flutter_hbb/sense/screens/session/layers/data/idle_policy.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

SensePeerStatusResult _answer(String body) => senseParsePeerStatusResponse(200, body);

void main() {
  late FakeClock clock;
  late FakeHost host;
  late SenseLayerController c;

  setUp(() {
    clock = FakeClock();
    host = FakeHost(clock);
    host.healthy();
    c = SenseLayerController(
        host: host, clock: () => clock.mono, wall: () => clock.wall, autoStart: false);
  });
  tearDown(() => c.dispose());

  void seconds(int n) {
    for (var i = 0; i < n; i++) {
      clock.advance(const Duration(seconds: 1));
      host.healthy();
      c.tick();
    }
  }

  test('parsing: number, null and missing', () {
    expect(_answer('{"online":true,"idle_disconnect_min":15}').status!.idleDisconnectMin, 15);
    expect(_answer('{"online":true,"idle_disconnect_min":null}').status!.idleDisconnectMin, isNull);
    expect(_answer('{"online":true}').status!.idleDisconnectMin, isNull);
    expect(SenseIdlePolicy.limitFromMinutes(0), isNull);
  });

  test('field present: warning at limit minus 1 min, cut at the limit', () async {
    await SenseIdlePolicy.load('1', c,
        fetch: (_) async => _answer('{"online":true,"idle_disconnect_min":10}'));
    seconds(9 * 60);
    expect(c.idle.warning, isTrue);
    expect(c.ended, isNull);
    seconds(60);
    expect(c.ended, isNotNull);
  });

  test('null: never triggers', () async {
    await SenseIdlePolicy.load('1', c,
        fetch: (_) async => _answer('{"online":true,"idle_disconnect_min":null}'));
    seconds(3 * 60 * 60);
    expect(c.idle.warning, isFalse);
    expect(c.ended, isNull);
  });
}
