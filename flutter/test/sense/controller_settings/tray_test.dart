// Sense Remote: tray menu data (YH C5, H6; #69 native menu). Last 3
// connections, their time labels, and the items in order; Host gets only "Aç".
import 'package:flutter_hbb/sense/screens/controller/data/tray.dart';
import 'package:flutter_test/flutter_test.dart';

class _Source implements SenseTraySource {
  _Source(this.raw);
  final String raw;
  @override
  Future<String> recentJson() async => raw;
}

const _now = 1000000;

void main() {
  test('recent: newest first, at most 3, bad rows dropped', () {
    final list = senseParseTrayRecent('''[
      {"peer_id":"111","name":"Galeri kioskı","at":${_now - 86400}},
      {"peer_id":"222","name":"Giriş Salonu PC-2","at":${_now - 7200}},
      {"peer_id":"","name":"x","at":1},
      {"peer_id":"333","name":"","at":${_now - 3 * 86400}},
      {"peer_id":"444","name":"Eski","at":5},
      {"name":"no id","at":9}
    ]''');
    expect(list.map((e) => e.name), ['Giriş Salonu PC-2', 'Galeri kioskı', '333']);
    expect(senseParseTrayRecent('nope'), isEmpty);
    expect(senseParseTrayRecent('{}'), isEmpty);
  });

  test('time labels like the prototype', () {
    expect(senseTrayAgo(_now - 10, _now), 'az önce');
    expect(senseTrayAgo(_now - 300, _now), '5 dk önce');
    expect(senseTrayAgo(_now - 7200, _now), '2 sa önce');
    expect(senseTrayAgo(_now - 86400, _now), 'dün');
    expect(senseTrayAgo(_now - 3 * 86400, _now), '3 gün');
  });

  test('Controller menu: header, open, SON BAĞLANTILAR, Çıkış yap', () {
    final recent = senseParseTrayRecent('[{"peer_id":"222","name":"Giriş Salonu PC-2","at":${_now - 7200}}]');
    final items = senseTrayMenu(controller: true, connections: 0, recent: recent, nowSeconds: _now);
    expect(items.map((e) => e.kind), [
      SenseTrayItemKind.header,
      SenseTrayItemKind.open,
      SenseTrayItemKind.group,
      SenseTrayItemKind.recent,
      SenseTrayItemKind.separator,
      SenseTrayItemKind.logout,
    ]);
    expect(items.first.detail, 'hazır');
    expect(items[1].label, "Sense Remote'u aç");
    expect(items[2].label, 'SON BAĞLANTILAR');
    expect(items[3].peerId, '222');
    expect(items[3].detail, '2 sa önce');
    expect(items.last.label, 'Çıkış yap');
  });

  test('Host menu: only "Sense Remote\'u aç" (no Servisi durdur, H6)', () {
    final items = senseTrayMenu(controller: false, connections: 1, nowSeconds: _now);
    expect(items.map((e) => e.kind), [SenseTrayItemKind.header, SenseTrayItemKind.open]);
    expect(items.first.detail, '1 bağlantı');
    expect(items.any((e) => e.label.toLowerCase().contains('durdur')), isFalse);
  });

  test('tooltip (H6)', () {
    expect(SenseTrayStrings.tooltip(0), 'Sense Remote · hazır');
    expect(SenseTrayStrings.tooltip(2), 'Sense Remote · 2 bağlantı');
  });

  test('source errors give an empty list; the bridge makes nothing up', () async {
    expect(await senseTrayRecent(_Source('broken')), isEmpty);
    expect(await senseTrayRecent(), isEmpty);
    expect((await senseTrayRecent(_Source('[{"peer_id":"1","name":"A","at":1}]'))).single.peerId, '1');
  });
}
