// Sense Remote (Sürüm 12, #157): the admin terminal request — hand-over between windows,
// the `sense_term_admin_result` event, the controller and the Turkish error sentences.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/terminal/terminal_admin.dart';
import 'package:flutter_hbb/sense/strings/terminal.dart';

void main() {
  group('hand-over (window → terminal window)', () {
    final now = DateTime(2026, 11, 28, 12);

    test('same computer within 30 s matches', () {
      final v = senseTermAdminRequestValue('123456789', now);
      expect(senseTermAdminRequestMatches(v, '123456789', now.add(const Duration(seconds: 29))), isTrue);
    });

    test('other computer, stale, empty or broken value does not', () {
      final v = senseTermAdminRequestValue('123456789', now);
      expect(senseTermAdminRequestMatches(v, '987654321', now), isFalse);
      expect(senseTermAdminRequestMatches(v, '123456789', now.add(const Duration(seconds: 31))), isFalse);
      expect(senseTermAdminRequestMatches(v, '123456789', now.subtract(const Duration(seconds: 1))), isFalse);
      expect(senseTermAdminRequestMatches('', '123456789', now), isFalse);
      expect(senseTermAdminRequestMatches('123456789|x', '123456789', now), isFalse);
    });

    test('peer ids with "|" keep working (last one splits)', () {
      final v = senseTermAdminRequestValue('a|b', now);
      expect(senseTermAdminRequestMatches(v, 'a|b', now), isTrue);
    });
  });

  group('event', () {
    test('ok as JSON bool or text; err only when not ok', () {
      expect(senseTermAdminResultOf({'ok': true, 'err': null}), (ok: true, err: null));
      expect(senseTermAdminResultOf({'ok': 'true'}), (ok: true, err: null));
      expect(senseTermAdminResultOf({'ok': false, 'err': 'expired'}), (ok: false, err: 'expired'));
      expect(senseTermAdminResultOf({'ok': false, 'err': null}), (ok: false, err: 'unknown'));
      expect(senseTermAdminResultOf({}), (ok: false, err: 'unknown'));
    });

    test('handle takes only its event and reaches the waiting controller', () async {
      final c = SenseTermAdminController(peerId: 'p-ev', begin: () async => '');
      final f = c.run();
      await Future<void>.delayed(Duration.zero);
      expect(SenseTermAdminEvents.handle('p-ev', {'name': 'other'}), isFalse);
      expect(SenseTermAdminEvents.handle('p-ev', {'name': kSenseTermAdminResultEvent, 'ok': true}), isTrue);
      expect(await f, isTrue);
      expect(c.phase, SenseTermAdminPhase.granted);
      expect(SenseTermAdminEvents.isGranted('p-ev'), isTrue);
      SenseTermAdminEvents.setGranted('p-ev', false);
      expect(SenseTermAdminEvents.isGranted('p-ev'), isFalse);
      c.dispose();
    });

    test('an event with no controller waiting is still taken (no stock handling)', () {
      expect(SenseTermAdminEvents.handle('nobody', {'name': kSenseTermAdminResultEvent, 'ok': false}), isTrue);
    });
  });

  group('controller', () {
    test('a begin code fails at once with that code', () async {
      final c = SenseTermAdminController(peerId: 'p1', begin: () async => 'signed_out');
      expect(await c.run(), isFalse);
      expect(c.phase, SenseTermAdminPhase.failed);
      expect(c.error, 'signed_out');
      c.dispose();
    });

    test('Host refusal from the event', () async {
      final c = SenseTermAdminController(peerId: 'p2', begin: () async => '');
      final f = c.run();
      await Future<void>.delayed(Duration.zero);
      expect(c.phase, SenseTermAdminPhase.requesting);
      SenseTermAdminEvents.handle('p2', {'name': kSenseTermAdminResultEvent, 'ok': false, 'err': 'unsupported'});
      expect(await f, isFalse);
      expect(c.error, 'unsupported');
      expect(SenseTermAdminEvents.isGranted('p2'), isFalse);
      c.dispose();
    });

    testWidgets('no answer at all: "timeout" after the safety time', (tester) async {
      bool? result;
      final c = SenseTermAdminController(peerId: 'p3', begin: () async => '', safety: const Duration(seconds: 40));
      c.run().then((v) => result = v);
      await tester.pump();
      await tester.pump(const Duration(seconds: 39));
      expect(result, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(result, isFalse);
      expect(c.error, 'timeout');
      c.dispose();
    });

    test('a second run while waiting returns the same answer; reset after a failure', () async {
      final began = <int>[];
      final c = SenseTermAdminController(peerId: 'p4', begin: () async {
        began.add(1);
        return '';
      });
      final a = c.run();
      final b = c.run();
      await Future<void>.delayed(Duration.zero);
      SenseTermAdminEvents.handle('p4', {'name': kSenseTermAdminResultEvent, 'ok': false, 'err': 'expired'});
      expect(await a, isFalse);
      expect(await b, isFalse);
      expect(began, hasLength(1));
      c.reset();
      expect(c.phase, SenseTermAdminPhase.idle);
      expect(c.error, isNull);
      c.dispose();
    });

    test('dispose while waiting answers false', () async {
      final c = SenseTermAdminController(peerId: 'p5', begin: () async => '');
      final f = c.run();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      expect(await f, isFalse);
    });

    test('begin throwing counts as "no_session"', () async {
      final c = SenseTermAdminController(peerId: 'p6', begin: () => Future.error(StateError('x')));
      expect(await c.run(), isFalse);
      expect(c.error, 'no_session');
      c.dispose();
    });
  });

  group('Turkish error sentences', () {
    const codes = [
      'token_invalid',
      'not_admin',
      'no_terminal_permission',
      'device_not_accessible',
      'policy_terminal_off',
      'signing_unavailable',
      'rate_limited',
      'panel_error',
      'network',
      'bad_sig',
      'expired',
      'replay',
      'wrong_host',
      'policy_off',
      'unsupported',
      'signed_out',
      'busy',
      'timeout',
      'not_terminal',
      'no_session',
    ];

    test('every contract code has its own sentence, no code or English shows', () {
      final fallback = SenseTerminalStrings.error('???');
      final seen = <String>{};
      for (final code in codes) {
        final text = SenseTerminalStrings.error(code);
        expect(text, isNot(fallback), reason: code);
        expect(text.contains(code), isFalse, reason: code);
        expect(text.toLowerCase().contains('error'), isFalse, reason: code);
        seen.add(text);
      }
      // not_terminal and no_session share one sentence.
      expect(seen.length, codes.length - 1);
    });

    test('unsupported names the fallback; not_admin names the role', () {
      expect(SenseTerminalStrings.error('unsupported'), contains('Windows yönetici hesabıyla'));
      expect(SenseTerminalStrings.error('not_admin'), contains('Yönetici rolündeki'));
    });

    test('retry only where a second try can help', () {
      expect(SenseTerminalStrings.retryable('expired'), isTrue);
      expect(SenseTerminalStrings.retryable('timeout'), isTrue);
      expect(SenseTerminalStrings.retryable('not_admin'), isFalse);
      expect(SenseTerminalStrings.retryable('unsupported'), isFalse);
      expect(SenseTerminalStrings.retryable('wrong_host'), isFalse);
    });
  });

  test('the request time limit and the safety time match the contract', () {
    expect(kSenseTermAdminRequestTtl, const Duration(seconds: 30));
    // Rust answers `unsupported` 10 s after sending; the panel request comes first.
    expect(kSenseTermAdminSafety > const Duration(seconds: 10), isTrue);
    expect(kSenseTermAdminResultEvent, 'sense_term_admin_result');
  });
}
