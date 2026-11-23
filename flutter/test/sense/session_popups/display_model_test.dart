// Sense Remote (C2, YH O9): "Ekran bilgisi" content — displays from the panel,
// session numbers from RustDesk; different refresh / 4:2:2 in orange with a
// note; latency 80 / 150 ms; frame rate by T6.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/popups/display/display_data.dart';
import 'package:flutter_hbb/sense/screens/session/popups/display/display_model.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_model.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'fixtures.dart';

SenseDisplayView view([SenseSessionVideo video = kVideo]) =>
    senseBuildDisplayView(panel: parseFull(fullJson()).status.displays, video: video);

SenseStatusLine line(List<SenseStatusRow> rows, String label) =>
    rows.whereType<SenseStatusLine>().firstWhere((l) => l.label == label);

void main() {
  test('top line, header and categories (img c07)', () {
    final v = view();
    expect(v.liveText, '3 ekran · Ekran 1 izleniyor');
    expect(v.subtitle, 'Ekran 1');
    expect(v.categories.map((c) => c.title), ['Ekran 1 · ana', 'Ekran 2', 'Ekran 3', 'Oturum görüntüsü']);
    expect(v.categories.map((c) => c.summary), [
      '3840×2160 · 60 Hz · HDMI',
      '3840×2160 · 50 Hz · HDMI',
      '1920×1080 · 60 Hz · DP',
      'VP9 · 60 fps · 18 ms',
    ]);
  });

  test('Ekran 2: different refresh and YCbCr 4:2:2 are orange with the advice note', () {
    final v = view();
    final e2 = v.categories[1];
    expect(e2.level, SenseLevel.warn);
    expect(line(e2.rows, 'Yenileme').value, '50 Hz (diğerleri 60 Hz)');
    expect(line(e2.rows, 'Yenileme').valueLevel, SenseLevel.warn);
    expect(line(e2.rows, 'Renk').value, '8 bit · YCbCr 4:2:2');
    expect(line(e2.rows, 'Renk').valueLevel, SenseLevel.warn);
    expect((e2.rows.last as SenseStatusNote).text, startsWith('YCbCr 4:2:2: ince yazı'));
    expect(v.level, SenseLevel.warn);
    expect(v.title, 'Uyarı var');
    expect(v.alerts.map((c) => c.title), ['Ekran 2']);
  });

  test('Ekran 1 rows', () {
    final rows = view().categories[0].rows;
    expect(line(rows, 'Monitör').value, 'Samsung QM55B');
    expect(line(rows, 'Bağlantı').value, 'HDMI');
    expect(line(rows, 'Çözünürlük').value, '3840 × 2160 (yerel)');
    expect(line(rows, 'Ölçek').value, '%150');
    expect(line(rows, 'Renk').value, '10 bit · RGB 4:4:4');
    expect(line(rows, 'HDR').value, 'Kapalı');
    expect(line(rows, 'Konum').value, '0, 0');
    expect(line(view().categories[2].rows, 'Bağlantı').value, 'DisplayPort');
  });

  test('status box: 60 / 60 fps, 18 ms, Doğrudan · VP9 · Dengeli', () {
    final m = view().meters;
    expect((m[0] as SenseStatusMeter).text, '60 / 60 fps');
    expect((m[1] as SenseStatusMeter).text, '18 ms');
    expect((m[2] as SenseStatusLine).value, 'Doğrudan · VP9 · Dengeli');
  });

  test('Oturum görüntüsü rows; loss is marked as an estimate', () {
    final rows = view().categories.last.rows;
    expect(line(rows, 'Bağlantı türü').value, 'Doğrudan (aktarma yok)');
    expect(line(rows, 'Kodek').value, 'VP9');
    expect(line(rows, 'Kalite').value, 'Dengeli');
    expect(line(rows, 'Bant genişliği').value, '6,4 Mbit/s');
    expect(line(rows, 'Kayıp kare').value, '%0,2 (tahmini)');
  });

  test('latency 80 ms orange, 150 ms red; frame rate under 15 orange, under 8 red', () {
    SenseLevel lat(double ms) => (view(SenseSessionVideo(rttMs: ms, fps: 60)).meters[1] as SenseStatusMeter).barLevel;
    expect(lat(79), SenseLevel.ok);
    expect(lat(80), SenseLevel.warn);
    expect(lat(150), SenseLevel.hot);
    SenseLevel fps(double f) => (view(SenseSessionVideo(fps: f)).meters[0] as SenseStatusMeter).barLevel;
    expect(fps(15), SenseLevel.ok);
    expect(fps(14), SenseLevel.warn);
    expect(fps(7), SenseLevel.hot);
    expect(view(const SenseSessionVideo(rttMs: 200)).alerts.map((c) => c.title), contains('Oturum görüntüsü'));
  });

  test('nothing measured: "okunamadı", no guess', () {
    final v = senseBuildDisplayView(panel: const [], video: const SenseSessionVideo());
    final rows = v.categories.single.rows;
    for (final l in rows.whereType<SenseStatusLine>()) {
      expect(l.value, isNull, reason: l.label);
    }
    expect((v.meters[0] as SenseStatusMeter).text, isNull);
  });

  test('display known only to the session: geometry, the rest unread', () {
    final v = senseBuildDisplayView(
        panel: const [], video: const SenseSessionVideo(displays: [SenseSessionDisplay(index: 0, x: 0, y: 0, width: 1920, height: 1080)]));
    final rows = v.categories.first.rows;
    expect(line(rows, 'Çözünürlük').value, '1920 × 1080');
    expect(line(rows, 'Monitör').value, isNull);
    expect(line(rows, 'Yenileme').value, isNull);
  });

  test('watching all displays', () {
    final v = view(const SenseSessionVideo(watched: -1));
    expect(v.liveText, '3 ekran · tüm ekranlar izleniyor');
  });

  test('RustDesk speed text to Mbit/s', () {
    expect(senseParseSpeedMbit('781.25kB/s'), closeTo(6.4, 0.01));
    expect(senseParseSpeedMbit(''), isNull);
    expect(senseParseSpeedMbit(null), isNull);
  });
}
