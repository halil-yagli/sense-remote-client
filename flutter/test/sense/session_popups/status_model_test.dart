// Sense Remote (C2, YH O8): the "Bilgisayar durumu" content comes from the
// panel's peer-status; a value the computer did not send is "okunamadı" (null),
// never guessed. Colours follow T6 and a category takes its worst value.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/data/peer_status.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_format.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_model.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'fixtures.dart';

SenseStatusCategory cat(SenseStatusView v, String id) => v.categories.firstWhere((c) => c.id == id);

Iterable<SenseStatusRow> flat(List<SenseStatusRow> rows) sync* {
  for (final r in rows) {
    yield r;
    if (r is SenseStatusCard) yield* flat(r.rows);
  }
}

SenseStatusLine line(List<SenseStatusRow> rows, String label) =>
    flat(rows).whereType<SenseStatusLine>().firstWhere((l) => l.label == label);

SenseStatusMeter meter(List<SenseStatusRow> rows, String label) =>
    flat(rows).whereType<SenseStatusMeter>().firstWhere((m) => m.label == label);

void main() {
  group('parse', () {
    test('health_v2 and inventory are read from the same body', () {
      final f = parseFull(fullJson());
      expect(f.status.online, isTrue);
      expect(f.health!.cpuMhz, 4050);
      expect(f.health!.topProcesses, hasLength(3));
      expect(f.inventory!.cpu!.model, contains('i7-12700'));
      expect(f.inventory!.physicalDisks!.first.mounts, ['C:']);
      expect(f.inventory!.network!.last.connected, isFalse);
    });

    test('out-of-range and badly shaped values are dropped, not clamped', () {
      final j = fullJson();
      final h = j['health']! as Map<String, Object?>;
      h['cpu_temp_c'] = 400;
      h['gpu_temp_c'] = 0; // "no sensor"
      h['cpu_pct'] = 'yüksek';
      final inv = j['inventory']! as Map<String, Object?>;
      (inv['network']! as List).add({'name': 'X', 'mac': 'not-a-mac'});
      final f = parseFull(j);
      expect(f.health!.cpuTempC, isNull);
      expect(f.health!.gpuTempC, isNull);
      expect(f.health!.cpuPct, isNull);
      expect(f.inventory!.network!.last.mac, isNull);
    });

    test('an invalid answer is null', () {
      expect(SensePeerStatusFull.parse('{"x":1}'), isNull);
      expect(SensePeerStatusFull.parse('nope'), isNull);
    });
  });

  group('view of the example computer (img c06, s01–s06)', () {
    final v = senseBuildStatusView(parseFull(fullJson()));

    test('eight categories in the locked order', () {
      expect(v.categories.map((c) => c.title), [
        'İşlemci', 'Ekran kartı', 'Bellek', 'Depolama', 'Ağ', 'Ekranlar', 'Bileşenler', 'Yazılım ve sürücüler',
      ]);
    });

    test('summaries', () {
      expect(cat(v, 'cpu').summary, 'i7-12700 · %23 · 58 °C');
      expect(cat(v, 'gpu').summary, 'RTX 4070 · %71 · 84 °C');
      expect(cat(v, 'memory').summary, '14,1 / 32 GB · %44');
      expect(cat(v, 'storage').summary, 'C: %62 · D: %96');
      expect(cat(v, 'network').summary, '3 bağdaştırıcı · 192.168.10.42');
      expect(cat(v, 'displays').summary, '3 ekran · 2× 4K + 1× 1080p');
      expect(cat(v, 'components').summary, 'PRIME B660M-A D4 · BIOS 2611');
      expect(cat(v, 'software').summary, 'Windows 11 Pro 24H2 · Sense Remote 3');
    });

    test('levels: GPU 84 °C orange, D: %96 red, overall "Dikkat gerekiyor"', () {
      expect(cat(v, 'cpu').level, SenseLevel.ok);
      expect(cat(v, 'gpu').level, SenseLevel.warn);
      expect(cat(v, 'storage').level, SenseLevel.hot);
      expect(v.level, SenseLevel.hot);
      expect(v.title, 'Dikkat gerekiyor');
      expect(v.alerts.map((c) => c.title), ['Ekran kartı', 'Depolama']);
    });

    test('overall box: six meters with % · °C', () {
      expect(v.meters.map((m) => m.label), ['İşlemci', 'Ekran kartı', 'Bellek', 'Disk C:', 'Disk D:', 'Ağ']);
      expect(v.meters.map((m) => m.text),
          ['%23 · 58 °C', '%71 · 84 °C', '14,1 / 32 GB', '%62 · 41 °C', '%96', '↓ 12 · ↑ 3 Mbit/s']);
      expect(v.meters[1].valueLevel, SenseLevel.warn);
      expect(v.meters[1].barLevel, SenseLevel.ok);
      expect(v.meters[4].barLevel, SenseLevel.hot);
    });

    test('İşlemci rows', () {
      final rows = cat(v, 'cpu').rows;
      expect(meter(rows, 'Kullanım').text, '%23');
      expect(line(rows, 'Sıcaklık').value, '58 °C');
      expect(line(rows, 'Model').value, '12th Gen Intel(R) Core(TM) i7-12700');
      expect(line(rows, 'Çekirdek / iş parçacığı').value, '12 / 20');
      expect(line(rows, 'Temel / anlık hız').value, '2,10 / 4,05 GHz');
      expect(line(rows, 'TouchDesigner.exe').value, '%14');
    });

    test('Ekran kartı: one card per GPU, integrated tagged, Kopyala text', () {
      final cards = cat(v, 'gpu').rows.whereType<SenseStatusCard>().toList();
      expect(cards.map((c) => c.title), ['NVIDIA GeForce RTX 4070', 'Intel UHD Graphics 770']);
      expect(cards[1].tags, ['tümleşik']);
      expect(cards[0].level, SenseLevel.warn);
      expect(meter(cards[0].rows, 'Video belleği').text, '5,8 / 12 GB');
      expect(line(cards[0].rows, 'Güç').value, '148 W');
      expect(line(cards[0].rows, 'Sürücü tarihi').value, '05.12.2025');
      expect(cards[0].copyText, contains('Sürücü sürümü: 31.0.15.6636'));
      // Integrated: no own temperature, fan or power rows.
      expect(flat(cards[1].rows).whereType<SenseStatusLine>().map((l) => l.label), ['Sürücü sürümü', 'Sürücü tarihi']);
    });

    test('Bellek: modules and free slots', () {
      final rows = cat(v, 'memory').rows;
      expect(line(rows, 'Kullanılabilir').value, '17,9 GB');
      expect(line(rows, 'Sayfa dosyası').value, '2,1 / 8 GB');
      expect(line(rows, 'Yuva A2').value, '16 GB DDR4-3200 · Kingston KF432C16BB/16');
      expect(line(rows, 'Boş yuva').value, '2 / 4');
    });

    test('Depolama: disk cards, unread temperature and total written stay "okunamadı"', () {
      final cards = cat(v, 'storage').rows.whereType<SenseStatusCard>().toList();
      expect(cards.map((c) => c.title), ['Samsung SSD 980 PRO 1TB', 'WDC WD20EZBX 2TB']);
      expect(cards.map((c) => c.tags), [['NVMe'], ['SATA HDD']]);
      expect(meter(cards[0].rows, 'C:').text, '577 / 931 GB');
      expect(meter(cards[1].rows, 'D:').text, '1,75 / 1,82 TB');
      expect(line(cards[0].rows, 'Sağlık').value, 'İyi · kalan ömür %96');
      expect(line(cards[0].rows, 'Anlık okuma / yazma').value, '24 / 3 MB/s');
      expect(line(cards[1].rows, 'Sıcaklık').value, isNull);
      expect(line(cards[0].rows, 'Toplam yazılan').value, isNull);
      expect(cards[1].level, SenseLevel.hot);
    });

    test('Ağ: wired first, STATİK / DHCP tags, unplugged adapter short', () {
      final cards = cat(v, 'network').rows.whereType<SenseStatusCard>().toList();
      expect(cards.map((c) => c.title), ['Ethernet', 'Ethernet 2', 'Wi-Fi']);
      expect(cards.map((c) => c.tags), [['bağlı'], ['kablo takılı değil'], ['bağlı']]);
      final eth = cards[0].rows;
      expect(line(eth, 'IPv4').value, '192.168.10.42');
      expect(line(eth, 'IPv4').tag, 'STATİK');
      expect(line(eth, 'IPv4').tagStrong, isTrue);
      expect(line(eth, 'IPv4 (ek)').value, '10.0.0.5');
      expect(line(eth, 'DNS').value, '192.168.10.1 · 1.1.1.1');
      expect(line(eth, 'Hız').value, '1 Gbit/s');
      expect(meter(eth, 'Anlık trafik').text, '↓ 12 · ↑ 3 Mbit/s');
      expect(flat(cards[1].rows).whereType<SenseStatusLine>().map((l) => l.label), ['Kart', 'MAC']);
      expect(line(cards[2].rows, 'IPv4').tag, 'DHCP');
      expect(line(cards[2].rows, 'Ağ adı').value, 'Ornek-Personel · 5 GHz · sinyal %78');
      expect(cat(v, 'network').rows.last, isA<SenseStatusNote>());
    });

    test('Ekranlar, Bileşenler, Yazılım', () {
      expect(line(cat(v, 'displays').rows, '1 · Ana').value, 'Samsung QM55B · 3840×2160 · 60 Hz · HDMI · %150');
      final comp = cat(v, 'components').rows;
      expect(line(comp, 'BIOS').value, '2611 · 24.10.2025');
      expect(line(comp, 'USB aygıtları').value, 'Logitech K400, Elo Touch 2201L, Stream Deck MK.2');
      // macOS-only field on a Windows computer: not guessed.
      expect(line(comp, 'Elektrik kesilince').value, isNull);
      final soft = cat(v, 'software').rows;
      expect(line(soft, 'Açık kalma').value, '3 gün 4 sa');
      expect(line(soft, 'Son güncelleme').value, '12.11.2026');
      expect(line(soft, 'Ekran kartı').value, 'NVIDIA 566.36');
      expect(soft.whereType<SenseStatusLine>().where((l) => l.label == 'Sürüm').last.value, '3 (rol: Host)');
      expect(line(soft, 'Hizmet').value, 'Çalışıyor');
    });
  });

  group('every field is real data or "okunamadı" (O8 acceptance)', () {
    test('an older computer without inventory shows "okunamadı", nothing invented', () {
      final v = senseBuildStatusView(parseFull(v1Json()));
      final cpu = cat(v, 'cpu').rows;
      expect(meter(cpu, 'Kullanım').text, '%12');
      expect(line(cpu, 'Model').value, isNull);
      expect(line(cpu, 'Temel / anlık hız').value, isNull);
      expect(cpu.whereType<SenseStatusUnreadable>(), hasLength(1)); // processes
      expect(line(cat(v, 'memory').rows, 'Boş yuva').value, isNull);
      expect(cat(v, 'network').rows.single, isA<SenseStatusUnreadable>());
      expect(cat(v, 'components').level, SenseLevel.unknown);
      // Volume without an inventory disk still shown, from health.
      expect(meter(cat(v, 'storage').rows, 'C:').text, '190 / 476 GB');
    });

    test('without inventory, every inventory line is "okunamadı"', () {
      final v = senseBuildStatusView(parseFull(v1Json()));
      for (final id in ['components', 'software']) {
        for (final l in flat(cat(v, id).rows).whereType<SenseStatusLine>()) {
          if (['Açık kalma', 'Sürüm', 'Hizmet'].contains(l.label)) continue;
          expect(l.value, isNull, reason: '$id / ${l.label}');
        }
      }
    });
  });

  group('format', () {
    test('Turkish numbers', () {
      expect(senseNum(14.099), '14,1');
      expect(senseNum(32), '32');
      expect(senseNum(1840, digits: 0), '1.840');
      expect(senseGhz(2100), '2,10');
      expect(sensePct(0.2), '%0,2');
      expect(sensePct(96), '%96');
      expect(senseUptime(274000), '3 gün 4 sa');
      expect(senseAgo(const Duration(seconds: 8)), '8 sn önce');
      expect(senseAgo(const Duration(minutes: 3)), '3 dk önce');
      expect(senseLinkSpeed(866), '866 Mbit/s');
      expect(senseShortCpu('AMD Ryzen 7 5800X 8-Core Processor'), 'Ryzen 7 5800X');
      expect(senseShortCpu('Apple M2 Pro'), 'M2 Pro');
    });
  });
}
