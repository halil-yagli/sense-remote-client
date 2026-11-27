// Sense Remote: session bar data (YH O1, T6, T9, S9-b, S10; plan C1).
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/sense/screens/session/data/frame_rate.dart';
import 'package:flutter_hbb/sense/screens/session/data/grants.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

void main() {
  group('connection line (O1, T6)', () {
    // Karar #152: no path word on the bar (the path is on the connection card).
    test('direct and relay: only fps and delay', () {
      final l = senseLinkLine(const SenseLinkSample(path: SenseLinkPath.direct, fps: 60, rttMs: 18));
      expect(l.text, '60 fps · 18 ms');
      expect(l.level, SenseLevel.ok);
      final r = senseLinkLine(const SenseLinkSample(path: SenseLinkPath.relay, fps: 58, rttMs: 24));
      expect(r.text, '58 fps · 24 ms');
    });

    test('nothing measured yet: Bağlanıyor…', () {
      expect(senseLinkLine(const SenseLinkSample()).text, 'Bağlanıyor…');
    });

    test('over the orange limits: Dalgalı in orange', () {
      for (final s in const [
        SenseLinkSample(fps: 60, rttMs: 150),
        SenseLinkSample(fps: 14, rttMs: 20),
        SenseLinkSample(fps: 60, rttMs: 20, lossPct: 2),
      ]) {
        final l = senseLinkLine(s);
        expect(l.text, startsWith('Dalgalı'));
        expect(l.level, SenseLevel.warn);
      }
    });

    test('no frame and no delay answer: Görüntü gelmiyor in red', () {
      final l = senseLinkLine(const SenseLinkSample(fps: 0, lastFrameMs: kSenseNoImageMs));
      expect(l.text, 'Görüntü gelmiyor');
      expect(l.level, SenseLevel.hot);
      final slow = senseLinkLine(const SenseLinkSample(fps: 0, rttMs: 320, lastFrameMs: kSenseNoImageMs + 1000));
      // Under 30 s the line does not claim it (karar #94).
      expect(senseLinkLine(const SenseLinkSample(fps: 0, lastFrameMs: 6000)).text, isNot('Görüntü gelmiyor'));
      expect(slow.text, 'Görüntü gelmiyor');
    });

    test('a still screen with good delay is not "no image"', () {
      final l = senseLinkLine(const SenseLinkSample(fps: 0, rttMs: 20, lastFrameMs: 9000));
      expect(l.text, isNot('Görüntü gelmiyor'));
      expect(l.level, SenseLevel.ok);
    });

    // Karar #152: the rate drawn on this screen; a still screen shows the last rate measured
    // while the picture moved (else the reachable one), never 0.
    test('still screen: last measured rate, hint says so', () {
      const s = SenseLinkSample(fps: 0, rttMs: 3, lastFrameMs: 9000, wavy: false, recentFps: 120, reachableFps: 60);
      final l = senseLinkLine(s);
      expect(l.text, '120 fps · 3 ms');
      expect(l.level, SenseLevel.ok);
      expect(l.hint, 'Ekranda değişiklik yok. Son ölçülen kare hızı 120 fps.');
      expect(senseFrameLine(s), 'Kare hızı: 120 fps · ekran durağan');
    });

    test('still screen before any movement: reachable rate, "henüz ölçülmedi"', () {
      const s = SenseLinkSample(fps: 0, rttMs: 3, lastFrameMs: 9000, wavy: false, reachableFps: 60, remoteHz: 144);
      expect(senseLinkLine(s).text, '60 fps · 3 ms');
      expect(senseLinkLine(s).hint,
          'Ekranda değişiklik yok. Kare hızı henüz ölçülmedi; görüntü değişince en çok 60 fps ile akar.');
      expect(senseFrameLine(s), 'Kare hızı: 60 fps · ekran durağan · karşı ekran 144 Hz');
      // The K44 rule (low rate, old last frame) is a still screen too.
      expect(senseLinkLine(const SenseLinkSample(fps: 2, rttMs: 20, lastFrameMs: 6000, reachableFps: 30)).text,
          '30 fps · 20 ms');
    });

    test('moving picture: the rate drawn now, with the Host refresh rate in the hint', () {
      const s = SenseLinkSample(fps: 118, rttMs: 3, lastFrameMs: 10, wavy: false, recentFps: 120, remoteHz: 144);
      expect(senseLinkLine(s).text, '118 fps · 3 ms');
      expect(senseLinkLine(s).hint, 'Kare hızı şu an 118 fps (karşı ekran 144 Hz)');
      expect(senseFrameLine(s), 'Kare hızı: 118 fps · karşı ekran 144 Hz');
      expect(senseLinkLine(const SenseLinkSample(fps: 58, rttMs: 3, lastFrameMs: 10)).hint, 'Kare hızı şu an 58 fps');
    });

    test('stalling: the real low rate in orange, hint with the seconds', () {
      const s = SenseLinkSample(fps: 7, rttMs: 20, lastFrameMs: 10, wavy: true, recentFps: 120, troubleSecs: 6);
      final l = senseLinkLine(s);
      expect(l.text, 'Dalgalı · 7 fps · 20 ms');
      expect(l.level, SenseLevel.warn);
      expect(l.hint, "Görüntü takılıyor: son 6 sn'de 7 fps geldi");
      expect(senseFrameLine(s), 'Kare hızı: 7 fps · takılıyor');
    });

    test('frame helpers', () {
      expect(senseSessionFpsCap(), kSenseDefaultFpsCap);
      expect(senseSessionFpsCap(imageQuality: 'custom', customFps: 60), 60);
      expect(senseSessionFpsCap(imageQuality: 'balanced', customFps: 60), kSenseDefaultFpsCap);
      expect(senseReachableFps(refreshHz: 144, cap: 120), 120);
      expect(senseReachableFps(refreshHz: 59.94, cap: 120), 60);
      expect(senseReachableFps(cap: 30), 30);
      expect(senseDrawnFps(decoded: 144, rasterized: 120), 120);
      expect(senseDrawnFps(decoded: 30, rasterized: 60), 30);
      expect(senseDrawnFps(decoded: 30), 30);
      final m = SenseFrameMeter();
      m.add(at: const Duration(seconds: 1), fps: 118, still: false);
      m.add(at: const Duration(seconds: 2), fps: 120, still: false);
      m.add(at: const Duration(seconds: 3), fps: 4, still: false);
      m.add(at: const Duration(seconds: 4), fps: 0, still: true);
      expect(m.recent(const Duration(seconds: 5)), 120);
      expect(m.recent(const Duration(seconds: 70)), isNull, reason: 'older than the window');
    });

    test('parsers', () {
      expect(senseParseFps('60'), 60);
      expect(senseParseFps('60 58 30'), 30);
      expect(senseParseFps(null), isNull);
      expect(senseParseMs('18'), 18);
      expect(senseParseMs('18ms'), 18);
      expect(senseParseDouble('2.5'), 2.5);
    });
  });

  group('T9 labels', () {
    test('wide bar uses the full names', () {
      final l = senseBarLabels(1600);
      expect(l.keyboard, 'Klavye ve fare');
      expect(l.status, 'Bilgisayar durumu');
      expect(l.info, 'Ekran bilgisi');
      expect(l.ghost(false), 'Hayalet mod');
      expect(l.ghost(true), 'Hayalet mod açık');
      expect(l.fullscreen, 'Tam ekran');
    });

    test('at and under 1500 px the short names', () {
      for (final w in [1500.0, 1366.0, 1300.0, 1280.0]) {
        final l = senseBarLabels(w);
        expect(l.keyboard, 'Klavye');
        expect(l.status, 'Durum');
        expect(l.info, 'Ekran');
        expect(l.ghost(false), 'Hayalet');
        expect(l.fullscreen, 'Tam');
      }
    });
  });

  test('bar controller: one list at a time, opening a list tells the owner', () {
    final c = SenseBarController();
    var opened = 0;
    c.onMenuOpened = () => opened++;
    c.toggle(SenseBarMenu.screens);
    expect(c.openMenu, SenseBarMenu.screens);
    c.toggle(SenseBarMenu.actions);
    expect(c.openMenu, SenseBarMenu.actions);
    c.toggle(SenseBarMenu.actions);
    expect(c.openMenu, isNull);
    expect(opened, 2);
  });

  group('core events (D1)', () {
    test('ghost notes reach the session', () {
      final s = SenseSessionEvents.of('p1');
      expect(SenseSessionEvents.handle('p1', {'name': 'sense_privacy_note', 'code': 'denied', 'details': ''}), isTrue);
      expect(s.privacyNote, 'denied');
      expect(s.privacySerial, 1);
      expect(SenseSessionEvents.handle('p1', {'name': 'msgbox'}), isFalse);
      SenseSessionEvents.remove('p1');
    });
  });

  test('the connection layer decides "Dalgalı" when it runs (C4)', () {
    expect(senseLinkLine(const SenseLinkSample(fps: 60, rttMs: 200, wavy: false)).text, '60 fps · 200 ms');
    expect(senseLinkLine(const SenseLinkSample(fps: 60, rttMs: 20, wavy: true)).text, startsWith('Dalgalı'));
  });

  group('person rights (plan §2.1)', () {
    test('valid envelope: only the listed rights', () {
      final g = SenseSessionGrants.parse('{"state":"ok","perms":["connect","control"],"email":"x","rev":3}');
      expect(g.allows(SenseGrant.control), isTrue);
      expect(g.allows(SenseGrant.recordSession), isFalse);
    });

    test('missing / expired / broken envelope: nothing', () {
      for (final raw in ['{"state":"missing"}', '{"state":"expired","perms":["control"]}', 'not json']) {
        expect(SenseSessionGrants.parse(raw).allows(SenseGrant.control), isFalse);
      }
    });

    test('without the bridge (tests, old core) nothing is locked by the person', () {
      expect(const SenseSessionGrants.unavailable().allows(SenseGrant.privacyMode), isTrue);
    });
  });

  test('Sense copies of the RustDesk values match consts.dart', () {
    expect(SenseRd.allDisplays, kAllDisplayValue);
    expect(SenseRd.viewOriginal, kRemoteViewStyleOriginal);
    expect(SenseRd.viewAdaptive, kRemoteViewStyleAdaptive);
    expect(SenseRd.viewCustom, kRemoteViewStyleCustom);
    expect(SenseRd.qualityBest, kRemoteImageQualityBest);
    expect(SenseRd.qualityBalanced, kRemoteImageQualityBalanced);
    expect(SenseRd.qualityLow, kRemoteImageQualityLow);
    expect(SenseRd.qualityCustom, kRemoteImageQualityCustom);
    expect(SenseRd.scrollAuto, kRemoteScrollStyleAuto);
    expect(SenseRd.scrollBar, kRemoteScrollStyleBar);
    expect(SenseRd.scrollEdge, kRemoteScrollStyleEdge);
    expect(SenseRd.modeLegacy, kKeyLegacyMode);
    expect(SenseRd.modeMap, kKeyMapMode);
    expect(SenseRd.modeTranslate, kKeyTranslateMode);
    expect(SenseRd.qualityMin, kMinQuality);
    expect(SenseRd.qualityMax, kMaxQuality);
    expect(SenseRd.fpsMin, kMinFps);
    expect(SenseRd.fpsMax, kMaxFps);
    expect(SenseRd.trackpadMin, kMinTrackpadSpeed);
    expect(SenseRd.trackpadMax, kMaxTrackpadSpeed);
  });
}
