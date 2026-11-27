// Sense Remote: idle watch (O15), ending reasons (O14) and the quality adapter (O13).
import 'package:flutter_hbb/sense/screens/session/layers/data/link_meter.dart';
import 'package:flutter_hbb/sense/screens/session/layers/idle_watch.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_strings.dart';
import 'package:flutter_hbb/sense/screens/session/layers/session_end.dart';
import 'package:flutter_test/flutter_test.dart';

Duration _s(int s) => Duration(seconds: s);

void main() {
  group('idle watch (O15)', () {
    test('the strip appears exactly 1 min before the limit, at 60', () {
      final w = SenseIdleWatch(limit: const Duration(minutes: 30));
      expect(w.tick(_s(30 * 60 - 61)).phase, SenseIdlePhase.active);
      final v = w.tick(_s(30 * 60 - 60));
      expect(v.warning, isTrue);
      expect(v.secondsLeft, 60);
    });

    test('the count goes down every second and ends in expired', () {
      final w = SenseIdleWatch(limit: const Duration(minutes: 2));
      expect(w.tick(_s(65)).secondsLeft, 55);
      expect(w.tick(_s(119)).secondsLeft, 1);
      expect(w.tick(_s(120)).expired, isTrue);
      expect(w.tick(_s(121)).expired, isTrue);
    });

    test('"Devam et" / input starts the time over', () {
      final w = SenseIdleWatch(limit: const Duration(minutes: 2));
      expect(w.tick(_s(70)).warning, isTrue);
      expect(w.activity(_s(70)).phase, SenseIdlePhase.active);
      expect(w.tick(_s(129)).phase, SenseIdlePhase.active);
      expect(w.tick(_s(130)).secondsLeft, 60);
    });

    test('after expiry input changes nothing', () {
      final w = SenseIdleWatch(limit: const Duration(minutes: 1));
      w.tick(_s(60));
      expect(w.activity(_s(61)).expired, isTrue);
    });

    test('no limit: never warns', () {
      final w = SenseIdleWatch();
      expect(w.tick(const Duration(hours: 10)).phase, SenseIdlePhase.active);
    });

    test('the limit can arrive later (panel value)', () {
      final w = SenseIdleWatch();
      w.tick(_s(100));
      w.limit = const Duration(minutes: 2);
      expect(w.tick(_s(100)).secondsLeft, 20);
    });
  });

  group('ending messages (O14)', () {
    test('the Host ended it', () {
      expect(senseClassifyMessage('error', 'Connection Error', 'Closed manually by the peer'),
          SenseMessageKind.hostEnded);
    });

    test('the Host cut it for inactivity', () {
      expect(senseClassifyMessage('error', 'Connection Error', 'Connection failed due to inactivity'),
          SenseMessageKind.idle);
    });

    test('the Host is gone', () {
      for (final t in ['Reset by the peer', 'Timeout', 'Remote desktop is offline',
        'Connection reset by peer (os error 104)']) {
        expect(senseClassifyMessage('error', 'Connection Error', t), SenseMessageKind.peerGone,
            reason: t);
      }
    });

    // Sürüm 11 (O7): the first login to a busy computer gets the Sense card, in Turkish.
    test('busy (D1 login error) ends with the Turkish "Meşgul" reason', () {
      expect(senseClassifyMessage('error', 'Login Error', 'sense_busy'), SenseMessageKind.busy);
      expect(senseEndReasonOf(SenseMessageKind.busy), SenseEndReason.busy);
      final s = SenseSessionSummary(
          reason: SenseEndReason.busy,
          duration: Duration.zero,
          messages: 0,
          files: 0,
          idleLimit: const Duration(minutes: 30));
      expect(s.reasonText, 'Meşgul — şu an başka biri bağlı');
      expect(s.reasonText, isNot(contains('sense_busy')));
    });

    // Sürüm 11 (O2): the other windows of a connection ended in one of them.
    test('ended in another window', () {
      expect(senseClassifyMessage('error', 'Connection Error', 'sense_ended_here'),
          SenseMessageKind.endedHere);
      expect(senseEndReasonOf(SenseMessageKind.endedHere), isNull);
    });

    test('other dialogs are left to RustDesk', () {
      expect(senseClassifyMessage('re-input-password', 'Password', 'Wrong Password'), isNull);
      expect(senseClassifyMessage('info', 'Successful', 'Connected, waiting for image...'), isNull);
    });

    test('the three reasons read as YH O14 writes them', () {
      SenseSessionSummary s(SenseEndReason r) => SenseSessionSummary(
          reason: r,
          duration: const Duration(minutes: 42),
          messages: 3,
          files: 1,
          idleLimit: const Duration(minutes: 30));
      expect(s(SenseEndReason.hostEnded).reasonText, 'Sahadaki kişi bağlantıyı bitirdi');
      expect(s(SenseEndReason.idle).reasonText, '30 dk hareketsiz kaldığı için kapandı');
      expect(s(SenseEndReason.peerGone).reasonText, 'Uzak bilgisayar kapandı ya da ağdan çıktı');
    });

    test('card texts', () {
      expect(SenseLayerStrings.durationValue(const Duration(minutes: 42, seconds: 10)), '42 dk');
      expect(SenseLayerStrings.durationValue(const Duration(seconds: 40)), '40 sn');
      expect(SenseLayerStrings.durationValue(const Duration(minutes: 125)), '2 sa 5 dk');
      expect(SenseLayerStrings.chatSummary(3, 1), '3 mesaj · 1 dosya');
      expect(SenseLayerStrings.backHome(5), '5 sn sonra ana ekrana dönülüyor');
    });
  });

  group('quality adapter (O13)', () {
    final now = DateTime(2026, 11, 23, 12);

    test('parses RustDesk strings', () {
      expect(senseParseNumber('22'), 22);
      expect(senseParseNumber('22ms'), 22);
      expect(senseParseNumber(null), isNull);
      expect(senseParseFps('60'), 60);
      expect(senseParseFps('60 0 12'), 60);
      expect(senseParseFps(''), isNull);
    });

    test('ages grow up to now even with no new event (frozen link)', () {
      final s = senseLinkSample(
        now: now,
        delay: '20',
        fps: '0',
        lossEst: 0.4,
        lastFrameMs: 500,
        lastFrameAt: now.subtract(_s(4)),
        probeAt: now.subtract(_s(5)),
      );
      expect(s.frameAge, const Duration(milliseconds: 4500));
      expect(s.probeAge, _s(5));
      expect(s.lossPct, 0.4);
      expect(s.rttMs, 20);
      expect(s.fps, 0);
    });

    test('nothing older than the start of watching counts (connect, reconnect)', () {
      final since = now.subtract(_s(1));
      final s = senseLinkSample(
        now: now,
        lastFrameMs: 9000,
        lastFrameAt: now.subtract(_s(50)),
        probeAt: now.subtract(_s(40)),
        watchingSince: since,
      );
      expect(s.frameAge, _s(1));
      expect(s.probeAge, _s(1));
    });

    test('the picture data rate is read for the still-screen rule (K44)', () {
      final s = senseLinkSample(now: now, speed: '12.5kB/s');
      expect(s.bandwidthMbit, closeTo(0.1024, 0.0001));
      expect(senseLinkSample(now: now, speed: '').bandwidthMbit, isNull);
    });

    test('unknown values stay unknown', () {
      final s = senseLinkSample(now: now);
      expect(s.bandwidthMbit, isNull);
      expect(s.rttMs, isNull);
      expect(s.lossPct, isNull);
      expect(s.frameAge, isNull);
      expect(s.probeAge, isNull);
    });
  });
}
