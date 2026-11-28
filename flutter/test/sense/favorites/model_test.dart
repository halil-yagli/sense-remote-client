// Sense Remote (Sürüm 12, #160–#163, #169): the "Sık kullanılanlar" model — per-system
// lists from the preference store, the core's real "unsupported" answers, runs and their
// results, key slots, custom requests (K3, K8).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/catalog.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_io.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_model.dart';
import 'package:flutter_hbb/sense/screens/session/data/health.dart';
import 'package:flutter_hbb/sense/screens/session/data/sense_peer_status.dart';
import 'package:flutter_hbb/sense/strings/favorites.dart';

import 'support.dart';

void main() {
  setUp(senseFavResetMemory);

  group('this build\'s core (ÇK-0 skeleton)', () {
    test('unsupported store: the choice stays in memory, the footer says so', () async {
      final io = FakeFavIo();
      final m = await loadedModel(io);
      expect(m.accountSaves, isFalse);
      expect(m.coreCatalog, isFalse);
      expect(m.mine, isEmpty);
      // Every built-in Windows entry is offered while the core has no catalogue.
      expect(m.all.length, senseFavCatalogOf(SenseFavOs.win).length);
      expect(m.all.every((i) => i.available), isTrue);

      m.toggle('win.taskmgr');
      expect(m.mine.map((i) => i.id), ['win.taskmgr']);
      // The next session of the same app run gets the same list.
      final again = await loadedModel(FakeFavIo());
      expect(again.mine.map((i) => i.id), ['win.taskmgr']);
      // A Mac session has its own (empty) list (#163).
      final mac = await loadedModel(FakeFavIo(), os: SenseFavOs.mac);
      expect(mac.mine, isEmpty);
    });

    test('an error object or garbage from the catalogue means "no catalogue"', () {
      expect(senseFavParseCoreCatalog(jsonDecode(kCoreUnsupported)), isEmpty);
      expect(senseFavParseCoreCatalog(jsonDecode(kCoreCatalogEmpty)), isEmpty);
      expect(senseFavParseCoreCatalog(null), isEmpty);
      final c = senseFavParseCoreCatalog(jsonDecode(coreCatalog([('win.cad', 'keys', true), ('win.taskmgr', 'exec', false)])));
      expect(c['win.cad']!.kind, 'keys');
      expect(c['win.taskmgr']!.available, isFalse);
    });

    test('a run reaches the skeleton Host and its unknown_id answer is said calmly', () async {
      final io = FakeFavIo();
      final notes = <String>[];
      final m = await loadedModel(io, notices: notes);
      await m.run('win.taskmgr');
      expect(io.sent.single.$1, 'sense.shortcut-run');
      expect(io.sent.single.$2, {'req': 1, 'id': 'win.taskmgr'});
      // The Host's answer as the core pushes it (`sense_shortcut_result`).
      SenseFavoritesEvents.handle('p1', {'name': 'sense_shortcut_result', 'req': '1', 'ok': 'false', 'err': 'unknown_id'});
      expect(notes.last, 'Görev Yöneticisi · ${SenseFavoritesStrings.errUnknownId}');
      m.dispose();
    });

    testWidgets('an older Host never answers: "yanıt vermedi" after the timeout', (tester) async {
      final io = FakeFavIo();
      final notes = <String>[];
      final m = SenseFavoritesModel(io: io, os: SenseFavOs.win, peerId: 'p2', onNotice: notes.add);
      await m.load();
      await m.run('win.services');
      expect(notes, isEmpty);
      await tester.pump(const Duration(seconds: 9));
      expect(notes.single, 'Hizmetler · ${SenseFavoritesStrings.errTimeout}');
      m.dispose();
    });

    test('a refused send ("not_allowed", "no_session") is "gönderilemedi"', () async {
      final io = FakeFavIo(sendAnswer: 'no_session');
      final notes = <String>[];
      final m = await loadedModel(io, notices: notes);
      await m.run('win.cmd');
      expect(notes.single, 'Komut istemi · ${SenseFavoritesStrings.errNotSent}');
    });
  });

  group('preference store (#169)', () {
    test('the list of the peer\'s system comes back with keys and recent', () async {
      final io = FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs(), SenseFavOs.mac: prototypeMacPrefs()}, setAnswer: '');
      final m = await loadedModel(io);
      expect(m.accountSaves, isTrue);
      expect(m.mine.map((i) => i.id), ['win.taskmgr', 'win.netadapt', 'win.thispc']);
      expect(m.keyOf('win.taskmgr'), 1);
      expect(m.keyOf('win.thispc'), isNull);
      expect(m.recent.map((i) => i.id), ['win.netadapt', 'win.ipinfo', 'win.taskmgr']);
      // Approved custom shortcuts join the catalogue under "Özel kısayollar".
      final custom = m.all.where((i) => i.group == SenseFavGroup.custom).toList();
      expect(custom.map((i) => i.name), ['Sergi uygulamasını yeniden başlat', 'Videolar klasörü']);
      expect(custom.first.description, 'Program · projedeki tüm bilgisayarlar');
      expect(custom.first.id, 'custom:cu1');

      // Switching to a Mac connection loads the Mac list (#163).
      m.setOs(SenseFavOs.mac);
      await pumpEventQueue();
      expect(m.mine.map((i) => i.id), ['mac.actmon', 'mac.net', 'mac.term']);
    });

    test('writes go out as fav.items / fav.recent of that system', () async {
      final io = FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs()}, setAnswer: '');
      final m = await loadedModel(io);
      m.toggle('win.services');
      final body = jsonDecode(io.setCalls.last) as Map<String, dynamic>;
      expect(body['entries'], [
        {
          'os': 'win',
          'key': 'fav.items',
          'value': [
            {'id': 'win.taskmgr', 'key': 1},
            {'id': 'win.netadapt', 'key': 2},
            {'id': 'win.thispc', 'key': null},
            {'id': 'win.services', 'key': null},
          ],
        }
      ]);
      await m.run('win.services');
      final rec = jsonDecode(io.setCalls.last) as Map<String, dynamic>;
      expect(rec['entries'][0]['key'], 'fav.recent');
      expect((rec['entries'][0]['value'] as List).first, 'win.services');
      m.dispose();
    });

    test('a store that turns out unsupported falls back to memory', () async {
      final io = FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs()}, setAnswer: 'unsupported');
      final m = await loadedModel(io);
      m.toggle('win.cmd');
      await pumpEventQueue();
      expect(m.accountSaves, isFalse);
    });

    test('bad values are dropped: unknown key slots, duplicates, more than 24', () async {
      final items = [
        {'id': 'win.taskmgr', 'key': 1},
        {'id': 'win.taskmgr', 'key': 2},
        {'id': 'win.cmd', 'key': 1},
        {'id': 'win.ps', 'key': 12},
        for (var i = 0; i < 30; i++) {'id': 'win.x$i', 'key': null},
      ];
      final io = FakeFavIo(prefs: {SenseFavOs.win: prefsJson(os: SenseFavOs.win, items: items)});
      final m = await loadedModel(io);
      expect(m.chosen.length, kSenseFavMaxItems);
      expect(m.keyOf('win.taskmgr'), 1);
      expect(m.keyOf('win.cmd'), isNull, reason: 'slot 1 is taken');
      expect(m.keyOf('win.ps'), isNull);
      // Unknown ids are kept in the store but not drawn.
      expect(m.mine.map((i) => i.id), ['win.taskmgr', 'win.cmd', 'win.ps']);
    });
  });

  group('choosing', () {
    test('a key slot belongs to one shortcut; reorder keeps the slots', () async {
      final io = FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs()}, setAnswer: '');
      final m = await loadedModel(io);
      m.setKey('win.thispc', 1);
      expect(m.keyOf('win.thispc'), 1);
      expect(m.keyOf('win.taskmgr'), isNull);
      m.reorder(2, 0);
      expect(m.mine.map((i) => i.id), ['win.thispc', 'win.taskmgr', 'win.netadapt']);
      expect(m.keyOf('win.thispc'), 1);
      m.setKey('win.thispc', null);
      expect(m.keyOf('win.thispc'), isNull);
    });

    test('labels follow the Controller: Ctrl+Alt+Shift, on a Mac Cmd+Option+Shift (K4)', () {
      expect(SenseFavoritesStrings.keyLabel(3, mac: false), 'Ctrl+Alt+Shift+3');
      expect(SenseFavoritesStrings.keyLabel(3, mac: true), 'Cmd+Option+Shift+3');
    });

    test('toggle says it in the toast; at most 24', () async {
      final notes = <String>[];
      final m = await loadedModel(FakeFavIo(), notices: notes);
      m.toggle('win.taskmgr');
      expect(notes.last, 'Görev Yöneticisi · kısayollara eklendi');
      m.toggle('win.taskmgr');
      expect(notes.last, 'Görev Yöneticisi · kısayollardan çıkarıldı');
      for (final d in senseFavCatalogOf(SenseFavOs.win).take(25)) {
        m.toggle(d.id);
      }
      expect(m.mine.length, kSenseFavMaxItems);
      expect(notes.last, SenseFavoritesStrings.tooMany);
    });
  });

  group('running', () {
    test('a keys entry is sent from here even before the core has a catalogue', () async {
      final io = FakeFavIo();
      final notes = <String>[];
      final m = await loadedModel(io, notices: notes);
      await m.run('win.cad');
      expect(io.keys, [SenseFavKeys.ctrlAltDel]);
      expect(io.sent, isEmpty);
      expect(notes.single, 'Ctrl+Alt+Del açıldı · Giriş Salonu PC-2');
    });

    test('the core may say exec for a keys-capable entry: then the Host runs it', () async {
      final io = FakeFavIo(catalogJson: coreCatalog([('win.lock', 'exec', true)]));
      final m = await loadedModel(io);
      await m.run('win.lock');
      expect(io.keys, isEmpty);
      expect(io.sent.single.$2['id'], 'win.lock');
      m.dispose();
    });

    test('ok result: "<ad> açıldı · <bilgisayar>"', () async {
      final io = FakeFavIo();
      final notes = <String>[];
      final m = await loadedModel(io, notices: notes);
      await m.run('win.taskmgr');
      SenseFavoritesEvents.handle('p1', {'name': 'sense_shortcut_result', 'req': 1, 'ok': true, 'err': null});
      expect(notes.single, 'Görev Yöneticisi açıldı · Giriş Salonu PC-2');
      // A late or repeated answer is ignored.
      SenseFavoritesEvents.handle('p1', {'name': 'sense_shortcut_result', 'req': 1, 'ok': true});
      expect(notes, hasLength(1));
      m.dispose();
    });

    test('every Host error code has its own line', () {
      expect(senseFavErrorText('no_permission'), SenseFavoritesStrings.errNoPermission);
      expect(senseFavErrorText('unsupported_os'), SenseFavoritesStrings.errUnsupportedOs);
      expect(senseFavErrorText('needs_admin'), SenseFavoritesStrings.errNeedsAdmin);
      expect(senseFavErrorText('failed'), SenseFavoritesStrings.errFailed);
      expect(senseFavErrorText('something_new'), SenseFavoritesStrings.errFailed);
    });

    test('without keyboard and mouse permission nothing runs', () async {
      final io = FakeFavIo();
      final m = await loadedModel(io, input: false);
      await m.run('win.taskmgr');
      await m.run('win.cad');
      expect(io.sent, isEmpty);
      expect(io.keys, isEmpty);
    });

    test('an entry the core cannot run here is not sent', () async {
      final io = FakeFavIo(catalogJson: coreCatalog([('win.regedit', 'exec', false)]));
      final notes = <String>[];
      final m = await loadedModel(io, notices: notes);
      expect(m.item('win.regedit')!.available, isFalse);
      await m.run('win.regedit');
      expect(io.sent, isEmpty);
      expect(notes.single, contains(SenseFavoritesStrings.unavailable));
    });

    test('hotkey slots: run, ask from the list, empty slot passes on', () async {
      final io = FakeFavIo(prefs: {
        SenseFavOs.win: prefsJson(os: SenseFavOs.win, items: [
          {'id': 'win.taskmgr', 'key': 1},
          {'id': 'win.logoff', 'key': 2},
        ])
      });
      final notes = <String>[];
      final m = await loadedModel(io, notices: notes);
      expect(m.runSlot(1), isTrue);
      await pumpEventQueue();
      expect(io.sent.single.$2['id'], 'win.taskmgr');
      expect(m.runSlot(2), isTrue);
      expect(notes.last, 'Oturumu kapat · listeden aç');
      expect(m.runSlot(5), isFalse);
      m.dispose();
    });
  });

  group('custom shortcuts (K3, K8)', () {
    SenseFavCustomForm form(String target, {SenseFavCustomKind kind = SenseFavCustomKind.program, String name = 'Sergi'}) =>
        SenseFavCustomForm(name: name, os: SenseFavOs.win, kind: kind, target: target, scope: SenseFavCustomScope.pc);

    test('only absolute paths without arguments, only https', () {
      expect(senseFavCustomFormError(form('')), SenseFavoritesStrings.formMissing);
      expect(senseFavCustomFormError(form(r'C:\Sergi\sergi.exe')), isNull);
      expect(senseFavCustomFormError(form(r'\\sunucu\paylasim\a.exe')), isNull);
      expect(senseFavCustomFormError(form('/Applications/Sergi.app')), isNull);
      expect(senseFavCustomFormError(form('sergi.exe')), SenseFavoritesStrings.formBadPath);
      expect(senseFavCustomFormError(form(r'C:\a.exe --kiosk')), SenseFavoritesStrings.formBadPath);
      expect(senseFavCustomFormError(form(r'C:\a.exe /S')), SenseFavoritesStrings.formBadPath);
      expect(senseFavCustomFormError(form(r'C:\a.exe && del x')), SenseFavoritesStrings.formBadPath);
      expect(senseFavCustomFormError(form(r'"C:\a.exe"')), SenseFavoritesStrings.formBadPath);
      expect(senseFavCustomFormError(form('https://snsdpt.com/x', kind: SenseFavCustomKind.url)), isNull);
      expect(senseFavCustomFormError(form('http://x.com', kind: SenseFavCustomKind.url)), SenseFavoritesStrings.formBadUrl);
      expect(senseFavCustomFormError(form('javascript:alert(1)', kind: SenseFavCustomKind.url)),
          SenseFavoritesStrings.formBadUrl);
      expect(senseFavCustomFormError(form(r'C:\a.exe', name: 'x' * 61)), SenseFavoritesStrings.formTooLong);
    });

    test('this build cannot send it yet: the form says so and stays', () async {
      final io = FakeFavIo();
      final m = await loadedModel(io);
      expect(await m.requestCustom(form(r'C:\Sergi\sergi.exe')), SenseFavoritesStrings.formUnsupported);
      expect(m.all.where((i) => i.pending), isEmpty);
    });

    test('sent: waits for a Yönetici, shown as pending, never runs', () async {
      final io = FakeFavIo(customAnswer: '{"id":"7f1c","status":"pending"}');
      final notes = <String>[];
      final m = await loadedModel(io, notices: notes, peerId: 'peer-9');
      expect(await m.requestCustom(form(r'C:\Sergi\sergi.exe')), isNull);
      final body = jsonDecode(io.customCalls.single) as Map<String, dynamic>;
      expect(body, {
        'os': 'win',
        'kind': 'program',
        'label': 'Sergi',
        'target': r'C:\Sergi\sergi.exe',
        'scope': 'person',
        'scope_ref': 'peer-9',
      });
      expect(notes.last, 'Yönetici onayına gönderildi · Windows');
      final p = m.all.singleWhere((i) => i.pending);
      expect(p.group, SenseFavGroup.custom);
      m.toggle(p.id);
      await m.run(p.id);
      expect(io.sent, isEmpty);
      expect(notes.last, SenseFavoritesStrings.pendingRun('Sergi'));
      m.dispose();
    });
  });

  test('IP card from the status data: first connected adapter, its gateway and DNS', () {
    final st = SensePeerStatus.fromJson({
      'online': true,
      'network': [
        {'name': 'Wi-Fi', 'kind': 'wifi', 'ipv4': ['10.0.0.8/24'], 'up': true},
        {'name': 'Ethernet', 'kind': 'ethernet', 'ipv4': ['192.168.10.42/24'], 'up': true},
      ],
    });
    final inv = SenseInventory.fromJson({
      'network': [
        {'name': 'Ethernet', 'connected': true, 'gateway': ['192.168.10.1'], 'dns': ['192.168.10.1', '8.8.8.8']},
      ],
    });
    final ip = senseFavIpInfoFrom(st, inv);
    expect(ip.ip, '192.168.10.42');
    expect(ip.gateway, ['192.168.10.1']);
    expect(ip.dns, ['192.168.10.1', '8.8.8.8']);
    expect(senseFavIpInfoFrom(null, null).empty, isTrue);
  });

  test('ping has no message yet: a calm line instead of a result', () async {
    final m = await loadedModel(FakeFavIo());
    expect(await m.ping('8.8.8.8'), SenseFavoritesStrings.pingUnsupported);
    expect(await m.ping(' '), SenseFavoritesStrings.pingEmpty);
  });

  test('events that are not ours are left for the other handlers', () {
    expect(SenseFavoritesEvents.handle('p1', {'name': 'sense_privacy_note'}), isFalse);
    var reloaded = 0;
    void f() => reloaded++;
    SenseFavoritesEvents.listenPrefs(f);
    expect(SenseFavoritesEvents.handleGlobal({'name': 'sense_prefs_changed'}), isTrue);
    expect(reloaded, 1);
    SenseFavoritesEvents.forgetPrefs(f);
  });
}
