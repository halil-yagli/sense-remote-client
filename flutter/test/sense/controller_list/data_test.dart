// Sense Remote: data of the Controller list (plan B3; YH C2, S8, S11): groups
// from the panel lists, search and location filter, number tiles, personal
// order, health for the LEDs (rate-limited cache) and the grants answer.
import 'dart:convert';

import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/sense/screens/controller/data/grants.dart';
import 'package:flutter_hbb/sense/screens/controller/data/peers.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

import '../session_popups/fixtures.dart' show fullJson;
import 'support.dart';

DeviceGroupPayload _group(String name, String id, String key) =>
    DeviceGroupPayload.fromJson({'name': name, 'sense': {'project_id': id, 'sort_key': key}});

PeerPayload _payload(String id, List<List<String>> projects, {bool online = true, String? busy}) =>
    PeerPayload.fromJson({
      'id': id,
      'info': {'device_name': 'PC $id', 'os': 'windows / 11'},
      'status': 1,
      'note': id == '1' ? 'Lobi' : 'Galeri',
      'sense': {
        'device_id': 'dev_$id',
        'online': online,
        'app_version': 4,
        'projects': [for (final p in projects) {'project_id': p[0], 'sort_key': p[1]}],
        'busy': busy == null ? null : {'by': busy},
      },
    });

void main() {
  group('panel lists → groups', () {
    final groups = [_group('Müze', 'prj_m', 'a0'), _group('Fuar', 'prj_f', 'a1')];
    final payloads = [
      _payload('1', [['prj_m', 'b']]),
      _payload('2', [['prj_m', 'a'], ['prj_f', 'a']], busy: 'Mevlüt'),
      _payload('3', [], online: false),
    ];
    final order = SensePanelOrder.build(groups, payloads)!;
    final peers = payloads.map(PeerPayload.toPeer).toList();

    test('busy, device id and project ids are read', () {
      expect(order.extras['2']!.busyBy, 'Mevlüt');
      expect(order.extras['1']!.deviceId, 'dev_1');
      expect(order.extras['3']!.online, isFalse);
      expect(order.projectIds, {'Müze': 'prj_m', 'Fuar': 'prj_f'});
    });

    test('groups in panel order, a computer in two projects shows in both, orphans last', () {
      final ps = senseProjectsFrom(projectNames: ['Müze', 'Fuar'], peers: peers, order: order);
      expect(ps.map((p) => p.name), ['Müze', 'Fuar', 'Projesiz']);
      expect(ps[0].computers.map((c) => c.id), ['2', '1'], reason: 'personal sort key order');
      expect(ps[1].computers.single.id, '2');
      expect(ps[0].id, 'prj_m');
      expect(ps[2].orphan, isTrue);
      final busy = ps[0].computers.first;
      expect(busy.busyBy, 'Mevlüt');
      expect(busy.deviceId, 'dev_2');
      expect(busy.os, 'Windows');
    });

    test('a computer that is not online is never busy', () {
      final p = PeerPayload.fromJson({
        'id': '9',
        'info': {},
        'sense': {'device_id': 'dev_9', 'online': false, 'projects': [], 'busy': {'by': 'Halil'}},
      });
      final o = SensePanelOrder.build(groups, [p])!;
      expect(senseComputerOf(PeerPayload.toPeer(p), o).busyBy, isNull);
    });

    test('without the sense extension the connection server state is used', () {
      final p = Peer.fromJson({'id': '7', 'hostname': 'Eski', 'platform': 'Mac OS', 'note': ''})..online = true;
      final c = senseComputerOf(p, null);
      expect(c.online, isTrue);
      expect(c.os, 'macOS');
      expect(c.busy, isFalse);
    });
  });

  group('filter, tiles, locations', () {
    final ps = exampleProjects();

    test('counts are taken once per computer, before search', () {
      final counts = senseCountsOf(ps, {'482913207': SenseLevel.hot, '482913208': SenseLevel.warn});
      expect(counts.total, 8);
      expect(counts.online, 6);
      expect(counts.offline, 2);
      expect(counts.attention, 2);
      expect(counts.attentionLevel, SenseLevel.hot);
      expect(counts.projects, 3);
    });

    test('locations once each with counts, sorted the Turkish way', () {
      final ls = senseLocationsOf(ps);
      expect(ls.map((l) => l.name), ['Ana salon', 'Arka oda', 'Galeri 1', 'Hol 3', 'Kubbe', 'Lobi', 'Stüdyo']);
      expect(ls.firstWhere((l) => l.name == 'Lobi').count, 2);
    });

    test('search: computer, location, project, ID; Turkish i', () {
      expect(senseFilter(ps, query: 'GIRIŞ').expand((p) => p.computers).map((c) => c.name),
          ['Giriş Salonu PC-2', 'Giriş kiosk 2']);
      expect(senseFilter(ps, query: 'kubbe').single.computers.single.name, 'Projeksiyon Mac');
      expect(senseFilter(ps, query: 'fuar').single.computers.length, 2, reason: 'project name keeps all');
      expect(senseFilter(ps, query: '482 913 213').single.computers.single.name, 'Ofis test PC');
      expect(senseFilter(ps, query: 'yok böyle'), isEmpty);
    });

    test('location filter keeps only that place', () {
      final f = senseFilter(ps, location: 'Lobi');
      expect(f.length, 1);
      expect(f.single.computers.map((c) => c.name), ['Giriş Salonu PC-2', 'Giriş kiosk 2']);
    });
  });

  group('order', () {
    test('tile goes in front of the target', () {
      expect(senseMoveBefore(['a', 'b', 'c', 'd'], 'd', 'b'), ['a', 'd', 'b', 'c']);
      expect(senseMoveBefore(['a', 'b', 'c'], 'a', 'c'), ['b', 'a', 'c']);
      expect(senseMoveBefore(['a', 'b'], 'a', 'x'), ['a', 'b']);
    });

    test('group takes the place of the target', () {
      expect(senseMoveTo(['a', 'b', 'c'], 'a', 'c'), ['b', 'c', 'a']);
      expect(senseMoveTo(['a', 'b', 'c'], 'c', 'a'), ['c', 'a', 'b']);
    });

    test('a saved order puts the named first, the rest keep their place', () {
      expect(senseApplyOrder(['a', 'b', 'c', 'd'], ['c', 'a'], (s) => s), ['c', 'a', 'b', 'd']);
    });

    test('group order is kept per person', () {
      expect(senseGroupOrderKey('Halil@Example.com'), 'sense-group-order-halil@example.com');
    });
  });

  group('health', () {
    test('a02: red disk, orange graphics card; network meter left out', () {
      final h = healthFromJson(fullJson());
      expect(h.level, SenseLevel.hot);
      final byLabel = {for (final l in h.lines) l.label: l};
      expect(byLabel['Disk D:']!.level, SenseLevel.hot);
      expect(byLabel['Ekran kartı']!.level, SenseLevel.warn);
      expect(byLabel.containsKey('Ağ'), isFalse);
      expect(h.at, isNotNull);
    });

    test('simple ok computer is green; warm graphics card is orange', () {
      expect(healthFromJson(okJson()).level, SenseLevel.ok);
      expect(healthFromJson(warnJson()).level, SenseLevel.warn);
    });

    test('no health from the panel = no data (hollow LED)', () {
      final j = okJson()..['health'] = null;
      final h = healthFromJson(j);
      expect(h.level, SenseLevel.unknown);
      expect(h.lines, isEmpty);
    });

    test('titles of the LED box', () {
      expect(senseHealthTitle(SenseLevel.ok, online: true), 'Sağlıklı');
      expect(senseHealthTitle(SenseLevel.warn, online: true), 'Uyarı var');
      expect(senseHealthTitle(SenseLevel.hot, online: true), 'Dikkat gerekiyor');
      expect(senseHealthTitle(SenseLevel.ok, online: false), 'Veri yok');
      expect(senseAgoFrom(kNow - 8, kNow), '8 sn önce');
      expect(senseAgoFrom(null, kNow), isNull);
    });

    test('cache asks one computer at a time and keeps the answer', () async {
      final fake = FakePeers()
        ..status['1'] = okJson()
        ..status['2'] = fullJson();
      var now = 1000;
      final cache = SenseHealthCache(fake, now: () => now, gap: Duration.zero);
      var notified = 0;
      cache.addListener(() => notified++);
      cache.want(['1', '2', '3']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await pumpEventQueue();
      expect(fake.asked, ['1', '2', '3']);
      expect(cache.of('1')!.level, SenseLevel.ok);
      expect(cache.of('2')!.level, SenseLevel.hot);
      expect(cache.of('3')!.level, SenseLevel.unknown, reason: 'not found = no panel info');
      expect(notified, 3);
      cache.want(['1']);
      await pumpEventQueue();
      expect(fake.asked.length, 3, reason: 'fresh answers are not asked again');
      now += 61;
      cache.want(['1']);
      await pumpEventQueue();
      expect(fake.asked.length, 4);
      cache.dispose();
    });
  });

  group('grants', () {
    test('ok answer opens only its permissions', () {
      final g = SenseGrants.parse(jsonEncode({'state': 'ok', 'perms': ['connect', 'bogus'], 'email': 'a@b.c', 'rev': 4}));
      expect(g.can(SensePerm.connect), isTrue);
      expect(g.can(SensePerm.recordSession), isFalse);
      expect(g.perms, {'connect'});
      expect(g.rev, 4);
    });

    test('missing, expired, invalid or broken = everything closed', () {
      for (final raw in [
        jsonEncode({'state': 'missing', 'perms': ['connect']}),
        jsonEncode({'state': 'expired', 'perms': ['connect']}),
        jsonEncode({'state': 'invalid', 'perms': ['connect']}),
        'not json',
        '[]',
      ]) {
        expect(SenseGrants.parse(raw).can(SensePerm.connect), isFalse, reason: raw);
      }
    });

    test('the watch reads, notifies on change and refreshes on request', () async {
      final fake = FakeGrants();
      final w = SenseGrantsWatch(fake, interval: const Duration(hours: 1));
      var n = 0;
      w.addListener(() => n++);
      expect(w.loaded, isFalse);
      w.start();
      await pumpEventQueue();
      expect(w.loaded, isTrue);
      expect(w.grants.can(SensePerm.connect), isTrue);
      fake.answer = jsonEncode({'state': 'expired'});
      await w.refresh();
      expect(fake.refreshes, 1);
      expect(w.grants.ok, isFalse);
      expect(n, 2);
      w.dispose();
    });

    test('until D3a the bridge opens every permission (panel still refuses)', () async {
      final g = SenseGrants.parse(await const SenseGrantsBridge().grants());
      expect(g.ok, isTrue);
      expect(g.perms, SensePerm.all.toSet());
    });
  });
}
