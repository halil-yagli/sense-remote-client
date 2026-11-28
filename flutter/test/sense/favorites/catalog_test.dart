// Sense Remote (Sürüm 12, #160, #161, #163): the catalogue the list draws, and its equality
// with the core's catalogue (`src/sense/shortcuts/catalog.rs`, FAV-Ç): every id the core can
// run has a Turkish name here and the other way round. While the core file does not exist
// (this build: ÇK-0 skeleton) the equality part is skipped.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/catalog.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_list.dart'
    show SenseFavoritesHotkeys;
import 'package:flutter_hbb/sense/strings/favorites.dart';

const _rustCatalog = '../src/sense/shortcuts/catalog.rs';

void main() {
  test('every entry has a unique id of its system and a Turkish name', () {
    final ids = <String>{};
    for (final d in kSenseFavCatalog) {
      expect(ids.add(d.id), isTrue, reason: 'duplicate ${d.id}');
      expect(RegExp(r'^(win|mac)\.[a-z0-9_]+$').hasMatch(d.id), isTrue, reason: d.id);
      expect(d.id.startsWith('${d.os.code}.'), isTrue, reason: d.id);
      expect(SenseFavoritesStrings.names[d.id], isNotNull, reason: d.id);
    }
    // No name without an entry.
    expect(SenseFavoritesStrings.names.keys.toSet(), ids);
  });

  test('the prototype catalogue: Windows 45, Mac 14, Linux none yet (#163)', () {
    expect(senseFavCatalogOf(SenseFavOs.win), hasLength(45));
    expect(senseFavCatalogOf(SenseFavOs.mac), hasLength(14));
    expect(senseFavCatalogOf(SenseFavOs.linux), isEmpty);
    expect(senseFavCatalogOf(SenseFavOs.mac).where((d) => d.group == SenseFavGroup.mac), hasLength(5));
    expect(senseFavCatalogOf(SenseFavOs.win).where((d) => d.group == SenseFavGroup.mac), isEmpty);
  });

  test('group order of the prototype (FAVORD)', () {
    expect(kSenseFavGroupOrder.map((g) => g.title), [
      'Sistem hareketleri',
      'Dosya ve sistem',
      'Ağ ve sorun giderme',
      'Sistem durumu',
      'Yönetim araçları',
      'Ayarlar',
      'Ekran ve ses',
      'Komut',
      'Mac’e özel',
      'Özel kısayollar',
    ]);
  });

  test('rows that ask, open a pane or send keys (prototype `ask`, `pane`)', () {
    expect(senseFavDef('win.resetnic')!.ask!.ok, 'Sıfırla');
    expect(senseFavDef('win.resetnic')!.ask!.danger, isFalse);
    expect(senseFavDef('win.logoff')!.ask!.danger, isTrue);
    expect(senseFavDef('win.ipinfo')!.pane, SenseFavPane.ip);
    expect(senseFavDef('win.ping')!.pane, SenseFavPane.ping);
    expect(senseFavDef('win.killhung')!.pane, SenseFavPane.windows);
    expect(senseFavDef('mac.forcequit')!.pane, SenseFavPane.windows);
    expect(senseFavDef('win.cad')!.keys, SenseFavKeys.ctrlAltDel);
    expect(senseFavDef('mac.maclock')!.keys, SenseFavKeys.lockScreen);
  });

  test('the core\'s ids all have a Turkish name (missing ones are listed)', () {
    expect(senseFavMissingNames(['win.taskmgr', 'custom:abc', 'mac.actmon']), isEmpty);
    expect(senseFavMissingNames(['win.taskmgr', 'win.new_tool']), ['win.new_tool']);
  });

  test('equal to the core\'s catalogue (catalog.rs)', () {
    final source = File(_rustCatalog).readAsStringSync();
    final rust = RegExp(r'"((?:win|mac|linux)\.[a-z0-9_]+)"').allMatches(source).map((m) => m.group(1)!).toSet();
    final dart = kSenseFavCatalog.map((d) => d.id).toSet();
    expect(rust.difference(dart), isEmpty, reason: 'in the core, no Turkish name here');
    expect(dart.difference(rust), isEmpty, reason: 'drawn here, the core cannot run it');
  }, skip: File(_rustCatalog).existsSync() ? false : 'catalog.rs is not in this build yet (FAV-Ç)');

  test('system from the peer platform string', () {
    expect(SenseFavOs.fromPlatform('Windows'), SenseFavOs.win);
    expect(SenseFavOs.fromPlatform('Mac OS'), SenseFavOs.mac);
    expect(SenseFavOs.fromPlatform('Linux'), SenseFavOs.linux);
    expect(SenseFavOs.fromPlatform('Android'), isNull);
    expect(SenseFavOs.fromPlatform(null), isNull);
  });

  group('hotkeys (K4)', () {
    int? slot(PhysicalKeyboardKey k,
            {bool ctrl = false, bool alt = false, bool shift = false, bool meta = false, bool mac = false}) =>
        SenseFavoritesHotkeys.slotFor(k, ctrl: ctrl, alt: alt, shift: shift, meta: meta, mac: mac);

    test('Windows: Ctrl+Alt+Shift+1–9 only', () {
      expect(slot(PhysicalKeyboardKey.digit1, ctrl: true, alt: true, shift: true), 1);
      expect(slot(PhysicalKeyboardKey.digit9, ctrl: true, alt: true, shift: true), 9);
      expect(slot(PhysicalKeyboardKey.numpad4, ctrl: true, alt: true, shift: true), 4);
      expect(slot(PhysicalKeyboardKey.digit1, ctrl: true), isNull, reason: 'Ctrl+1 goes to the remote');
      expect(slot(PhysicalKeyboardKey.digit1, ctrl: true, alt: true), isNull);
      expect(slot(PhysicalKeyboardKey.digit1, ctrl: true, alt: true, shift: true, meta: true), isNull);
      expect(slot(PhysicalKeyboardKey.digit0, ctrl: true, alt: true, shift: true), isNull);
      expect(slot(PhysicalKeyboardKey.keyB, ctrl: true, alt: true, shift: true), isNull, reason: '#71 bar key');
    });

    test('Mac: Cmd+Option+Shift+1–9', () {
      expect(slot(PhysicalKeyboardKey.digit3, meta: true, alt: true, shift: true, mac: true), 3);
      expect(slot(PhysicalKeyboardKey.digit3, ctrl: true, alt: true, shift: true, mac: true), isNull);
    });

    test('matcher actions sense_fav_<n>', () {
      expect(SenseFavoritesHotkeys.handleAction('toggle_fullscreen'), isFalse);
      expect(SenseFavoritesHotkeys.handleAction('sense_fav_0'), isFalse);
      expect(SenseFavoritesHotkeys.handleAction('sense_fav_3'), isFalse, reason: 'no list is open');
    });
  });
}
