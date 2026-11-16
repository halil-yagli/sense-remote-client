// Sense Remote: Controller list panel order and multi-project membership
// (`sense` extension of /api/device-group/accessible and /api/peers).
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_test/flutter_test.dart';

DeviceGroupPayload _group(String name, [String? projectId, String? sortKey]) {
  final json = <String, dynamic>{'name': name};
  if (projectId != null) {
    json['sense'] = {'project_id': projectId, 'sort_key': sortKey ?? ''};
  }
  return DeviceGroupPayload.fromJson(json);
}

PeerPayload _peer(String id,
    {String? group, List<List<String>>? projects}) {
  final json = <String, dynamic>{
    'id': id,
    'info': <String, dynamic>{},
    'status': 1,
  };
  if (group != null) json['device_group_name'] = group;
  if (projects != null) {
    json['sense'] = {
      'device_id': 'dev_$id',
      'online': true,
      'app_version': null,
      'projects': projects
          .map((p) => {'project_id': p[0], 'sort_key': p[1]})
          .toList(),
    };
  }
  return PeerPayload.fromJson(json);
}

List<String> _sorted(SensePanelOrder order, List<String> ids,
    {String? groupName}) {
  final list = [...ids];
  list.sort((a, b) => order.compare(a, b, groupName: groupName));
  return list;
}

void main() {
  group('parsing', () {
    test('stock server: no sense data', () {
      final g = DeviceGroupPayload.fromJson({'name': 'A'});
      final p = PeerPayload.fromJson({'id': '1', 'device_group_name': 'A'});
      expect(g.sense, isNull);
      expect(p.senseProjects, isNull);
      expect(g.toGroupCacheJson(), {'name': 'A'});
    });

    test('sense data is read; malformed items are skipped', () {
      final g = _group('Muze', 'prj_1', 'a0');
      expect(g.sense!.projectId, 'prj_1');
      expect(g.sense!.sortKey, 'a0');
      // cache keeps only the name (no change to what is written to disk)
      expect(g.toGroupCacheJson(), {'name': 'Muze'});

      final p = PeerPayload.fromJson({
        'id': '1',
        'sense': {
          'projects': [
            {'project_id': 'prj_1', 'sort_key': 'b'},
            {'sort_key': 'x'},
            'junk',
          ]
        }
      });
      expect(p.senseProjects!.map((e) => e.projectId), ['prj_1']);
    });
  });

  group('SensePanelOrder', () {
    test('null without sense data (stock behaviour)', () {
      expect(
          SensePanelOrder.build(
              [_group('B'), _group('A')], [_peer('1', group: 'A')]),
          isNull);
      expect(SensePanelOrder.groupsHaveSense([_group('B')]), isFalse);
      expect(
          SensePanelOrder.groupsHaveSense([_group('B', 'prj_b', 'a0')]),
          isTrue);
    });

    final groups = [
      _group('Zeta', 'prj_z', 'a0'), // panel puts Zeta before Alpha
      _group('Alpha', 'prj_a', 'a1'),
    ];
    // response order: Zeta's peers by in-project key, then Alpha's
    final peers = [
      _peer('900', group: 'Zeta', projects: [
        ['prj_z', 'a0'],
        ['prj_a', 'a2'],
      ]),
      _peer('100', group: 'Zeta', projects: [
        ['prj_z', 'a1'],
      ]),
      _peer('500', group: 'Alpha', projects: [
        ['prj_a', 'a0'],
      ]),
      _peer('300', group: 'Alpha', projects: [
        ['prj_a', 'a1'],
      ]),
      _peer('700', projects: []), // no project
    ];
    final order = SensePanelOrder.build(groups, peers)!;

    test('all view keeps response (panel) order, not id order', () {
      expect(_sorted(order, ['100', '300', '500', '700', '900']),
          ['900', '100', '500', '300', '700']);
    });

    test('selected project sorts by its own sort key', () {
      expect(
          _sorted(order, ['300', '500', '900'], groupName: 'Alpha'),
          ['500', '300', '900']);
    });

    test('multi-project peer belongs to each of its projects', () {
      expect(order.groupNamesOf('900'), containsAll(['Zeta', 'Alpha']));
      expect(order.groupNamesOf('100'), ['Zeta']);
      expect(order.groupNamesOf('700'), isEmpty);
      expect(order.knowsPeer('900'), isTrue);
      expect(order.knowsPeer('unknown'), isFalse);
    });

    test('unknown peers go last, by id', () {
      expect(_sorted(order, ['zz', '300', 'aa']), ['300', 'aa', 'zz']);
    });

    test('peer without sense keeps its legacy group', () {
      final o = SensePanelOrder.build(
          [_group('Alpha', 'prj_a', 'a0')], [_peer('1', group: 'Alpha')])!;
      expect(o.groupNamesOf('1'), ['Alpha']);
    });
  });

  test('sort option: empty means panel order, stored choice is kept', () {
    expect(PeerSortType.values.first, PeerSortType.panelOrder);
    expect(peerSortOrDefault(''), PeerSortType.panelOrder);
    expect(peerSortOrDefault(PeerSortType.remoteId), PeerSortType.remoteId);
  });
}
