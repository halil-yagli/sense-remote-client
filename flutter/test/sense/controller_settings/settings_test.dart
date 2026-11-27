// Sense Remote: Controller settings (YH C3). Every switch, choice and button
// writes the real option the core reads (key + store + value, TK9 §4; #2, #66);
// panel-managed rows cannot be changed (#68 decision 5); no theme category.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/data/option_keys.dart';
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart';
import 'package:flutter_hbb/sense/screens/controller/settings/data/incoming.dart';
import 'package:flutter_hbb/sense/screens/controller/settings/data/settings_backend.dart';
import 'package:flutter_hbb/sense/screens/controller/settings/sense_settings_page.dart';
import 'package:flutter_hbb/sense/screens/host/data/role.dart';
import 'package:flutter_hbb/sense/screens/host/role/role_category.dart';
import 'package:flutter_hbb/sense/strings/common.dart';
import 'package:flutter_hbb/sense/strings/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _Write {
  _Write(this.key, this.store, this.value);
  final String key;
  final SenseOptionStore store;
  final String value;
  @override
  String toString() => '$key/${store.name}=$value';
}

class _FakeIncoming implements SenseIncomingDirSource {
  String dir = '';
  final sets = <String>[];
  @override
  Future<String> current() async => dir;
  @override
  Future<void> set(String path) async {
    sets.add(path);
    dir = path;
  }
}

/// Stores like the core: main / local / user-default maps, yes/no decoded the
/// way `option2bool` does.
class _FakeBackend extends SenseSettingsBackend {
  _FakeBackend({this.homeRole = SenseHomeRole.controller, Set<String>? lockedKeys})
      : lockedKeys = lockedKeys ?? SenseOptionKeys.lockedByDesign;

  final SenseHomeRole homeRole;
  final Set<String> lockedKeys;
  final stores = <SenseOptionStore, Map<String, String>>{
    SenseOptionStore.main: {},
    SenseOptionStore.local: {},
    SenseOptionStore.userDefault: {'view_style': 'original', 'image_quality': 'balanced'},
  };
  final writes = <_Write>[];
  bool shortcuts = true;
  bool passThrough = false;
  String video = '/home/halil/Videos/Sense';
  String? pick;
  final picks = <String>[];

  @override
  final _FakeIncoming incoming = _FakeIncoming();

  static bool decode(String key, String raw) {
    if (key.startsWith('enable-')) return raw != 'N';
    if (key.startsWith('allow-') || key == 'direct-server' || key == 'force-always-relay') return raw == 'Y';
    return raw != 'N';
  }

  @override
  String read(String key, SenseOptionStore store) => stores[store]?[key] ?? '';

  bool failWrites = false;

  @override
  Future<void> write(String key, SenseOptionStore store, String value) async {
    if (failWrites) throw StateError('write failed');
    writes.add(_Write(key, store, value));
    stores[store]?[key] = value;
  }

  @override
  bool readBool(String key, SenseOptionStore store) {
    final raw = read(key, store);
    return store == SenseOptionStore.userDefault ? raw == 'Y' : decode(key, raw);
  }

  @override
  Future<void> writeBool(String key, SenseOptionStore store, bool value) =>
      write(key, store, value ? 'Y' : 'N');

  @override
  bool shortcutsEnabled() => shortcuts;
  @override
  Future<void> setShortcutsEnabled(bool value) async => shortcuts = value;
  @override
  bool shortcutsPassThrough() => passThrough;
  @override
  Future<void> setShortcutsPassThrough(bool value) async => passThrough = value;
  @override
  String recordDir() => stores[SenseOptionStore.local]!['video-save-directory'] ?? video;
  @override
  Future<String?> pickDirectory(String initial) async {
    picks.add(initial);
    return pick;
  }

  @override
  bool locked(String key) => lockedKeys.contains(key);
  @override
  SenseHomeRole role() => homeRole;
}

class _FakeRole implements SenseRoleBackend {
  _FakeRole(this.roles);
  final List<String> roles;
  @override
  Future<String> status() async => jsonEncode({'roles': roles, 'pending': null, 'error': null});
  @override
  Future<String> begin(String target) async => '{"error":"unavailable"}';
  @override
  Future<String> changeStatus() async => '{"error":"unavailable"}';
  @override
  Future<void> cancel() async {}
}

Future<void> _pump(WidgetTester tester, _FakeBackend b,
    {String? open, Size size = const Size(1180, 1400), Widget? password}) async {
  await pumpSense(
      tester,
      SizedBox(
        width: size.width,
        height: size.height,
        child: SenseSettingsView(
          backend: b,
          initialOpen: open,
          isWindowsHost: true,
          passwordSection: password,
          roleBackend: _FakeRole(b.homeRole == SenseHomeRole.both
              ? ['host_controller']
              : [b.homeRole == SenseHomeRole.host ? 'host' : 'controller']),
        ),
      ),
      size: size,
      center: false);
  await tester.pumpAndSettle();
}

/// The green "Kaydedildi" of [rowKey] is showing.
bool _saved(WidgetTester tester, String rowKey) {
  final note =
      find.descendant(of: find.byKey(Key('sense-set-$rowKey')), matching: find.text(SenseCommonStrings.saved));
  final op = tester.widget<AnimatedOpacity>(find.ancestor(of: note, matching: find.byType(AnimatedOpacity)).first);
  return op.opacity == 1;
}

Future<void> _tapRow(WidgetTester tester, String rowKey) async {
  final row = find.byKey(Key('sense-set-$rowKey'));
  expect(row, findsOneWidget, reason: rowKey);
  // The control is at the right end of the row.
  final r = tester.getRect(row);
  await tester.tapAt(Offset(r.right - 20, r.center.dy));
  await tester.pump();
}

void main() {
  group('Bağlantılar: each switch writes its own option (local store)', () {
    const keys = [
      'enable-open-new-connections-in-tabs',
      'enable-confirm-closing-tabs',
      'keep-awake-during-outgoing-sessions',
      'allow-sync-clipboard-between-sessions',
      'allow-ask-for-note', // R7: off by default
    ];
    for (final key in keys) {
      testWidgets(key, (tester) async {
        final b = _FakeBackend();
        await _pump(tester, b, open: SenseSettingsCategory.connections);
        final before = b.readBool(key, SenseOptionStore.local);
        await _tapRow(tester, key);
        expect(b.writes.single.key, key);
        expect(b.writes.single.store, SenseOptionStore.local);
        expect(b.readBool(key, SenseOptionStore.local), !before);
        await tester.pump(const Duration(milliseconds: 400));
        expect(_saved(tester, key), isTrue);
        await tester.pumpAndSettle(const Duration(seconds: 3));
      });
    }

    testWidgets('keyboard shortcuts and pass-through (ShortcutModel)', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.connections);
      expect(find.text(SenseSettingsStrings.passThrough), findsOneWidget);
      await _tapRow(tester, 'pass-through');
      expect(b.passThrough, isTrue);
      await _tapRow(tester, 'shortcuts');
      expect(b.shortcuts, isFalse);
      await tester.pumpAndSettle(const Duration(seconds: 3));
      // Pass-through is meaningless without shortcuts (prototype: hidden).
      expect(find.text(SenseSettingsStrings.passThrough), findsNothing);
    });
  });

  group('Yeni bağlantılar: defaults of new connections (user-default store)', () {
    testWidgets('Uzak ekranı göster: Sığdır / 1:1', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.newConnections);
      await tester.tap(find.text(SenseSettingsStrings.viewFit).last);
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(b.writes.last.toString(), 'view_style/userDefault=adaptive');
      await tester.tap(find.text(SenseSettingsStrings.viewOriginal));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(b.writes.last.toString(), 'view_style/userDefault=original');
    });

    testWidgets('Görüntü kalitesi: İyi / Dengeli / Hızlı', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.newConnections);
      for (final e in {
        SenseSettingsStrings.qualityBest: 'best',
        SenseSettingsStrings.qualityFast: 'low',
        SenseSettingsStrings.qualityBalanced: 'balanced',
      }.entries) {
        await tester.tap(find.text(e.key).last);
        await tester.pumpAndSettle(const Duration(seconds: 3));
        expect(b.writes.last.toString(), 'image_quality/userDefault=${e.value}');
      }
    });

    testWidgets('Yalnız izleyerek başla, Hayalet modla başla', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.newConnections);
      await _tapRow(tester, 'view_only');
      expect(b.writes.last.toString(), 'view_only/userDefault=Y');
      // B7: "Hayalet modla başla" is on by default (karar #95); tapping turns it off, written "N".
      expect(find.text('1:1 · Dengeli · yalnız izleme · Hayalet mod'), findsOneWidget);
      await _tapRow(tester, 'privacy_mode');
      expect(b.writes.last.toString(), 'privacy_mode/userDefault=N');
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(find.text('1:1 · Dengeli · yalnız izleme'), findsOneWidget);
      await _tapRow(tester, 'privacy_mode');
      expect(b.writes.last.toString(), 'privacy_mode/userDefault=Y');
    });

    testWidgets('B9: a write that fails says "Kaydedilemedi" and writes no record', (tester) async {
      final b = _FakeBackend()..failWrites = true;
      await _pump(tester, b, open: SenseSettingsCategory.newConnections);
      await _tapRow(tester, 'view_only');
      await tester.pump();
      expect(find.byKey(const Key('sense-settings-failed')), findsOneWidget);
      expect(find.text(SenseSettingsStrings.saveFailedTitle), findsOneWidget);
    });
  });

  group('Gelen dosyalar ve kayıt', () {
    testWidgets('chat files folder: Değiştir picks and saves (D3d1 adapter)', (tester) async {
      final b = _FakeBackend()..pick = r'D:\Sense Gelen';
      await _pump(tester, b, open: SenseSettingsCategory.incoming);
      expect(find.text(SenseSettingsStrings.downloads), findsWidgets);
      await tester.tap(find.byKey(const Key('sense-set-sense:incoming-dir-change')));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(b.incoming.sets, [r'D:\Sense Gelen']);
      expect(find.text(r'D:\Sense Gelen'), findsOneWidget);
      // Summary shows the folder name.
      expect(find.text('Sense Gelen · kayıt kapalı'), findsOneWidget);
    });

    testWidgets('cancelled picker changes nothing', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.incoming);
      await tester.tap(find.byKey(const Key('sense-set-sense:incoming-dir-change')));
      await tester.pumpAndSettle();
      expect(b.incoming.sets, isEmpty);
      expect(b.writes, isEmpty);
    });

    testWidgets('auto record and the recording folder (#57 note)', (tester) async {
      final b = _FakeBackend()..pick = '/data/kayit';
      await _pump(tester, b, open: SenseSettingsCategory.incoming);
      expect(find.text(SenseSettingsStrings.recordDirHint), findsOneWidget);
      await _tapRow(tester, 'allow-auto-record-outgoing');
      expect(b.writes.last.toString(), 'allow-auto-record-outgoing/local=Y');
      await tester.tap(find.byKey(const Key('sense-set-video-save-directory-change')));
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(b.picks.last, '/home/halil/Videos/Sense');
      expect(b.writes.last.toString(), 'video-save-directory/local=/data/kayit');
      expect(find.text('/data/kayit'), findsOneWidget);
    });
  });

  group('Güvenlik, Performans, Ağ, Güncelleme', () {
    testWidgets('locked rows show the value and "Panelden yönetilir"', (tester) async {
      final b = _FakeBackend()
        ..stores[SenseOptionStore.main]!.addAll({
          'allow-auto-disconnect': 'Y',
          'auto-disconnect-timeout': '30',
          'enable-lan-discovery': 'N',
          'direct-server': 'N',
          'conn-type': 'outgoing',
        });
      await _pump(tester, b, open: SenseSettingsCategory.security);
      expect(find.text(SenseSettingsStrings.passwordController), findsOneWidget);
      expect(find.text('30 dk sonra'), findsOneWidget);
      expect(find.text(SenseSettingsStrings.acceptConnNone), findsOneWidget);
      expect(find.text(SenseSettingsStrings.loginValue), findsOneWidget);
      // conn-type, idle, LAN, direct IP, login.
      expect(find.text(SenseCommonStrings.managedByPanel), findsNWidgets(5));
      await _tapRow(tester, 'enable-lan-discovery');
      await _tapRow(tester, 'direct-server');
      expect(b.writes, isEmpty);
    });

    testWidgets('IP access (security) and direct connection (network) are told apart', (tester) async {
      final b = _FakeBackend()..stores[SenseOptionStore.main]!.addAll({'direct-server': 'N'});
      await _pump(tester, b, open: SenseSettingsCategory.security);
      expect(find.text(SenseSettingsStrings.directIp), findsOneWidget);
      expect(find.text(SenseSettingsStrings.directIpHint), findsOneWidget);
      expect(find.text('Doğrudan IP erişimi'), findsNothing);
      // The relay-less path stays "açık" while IP access is closed: two different settings.
      expect(SenseSettingsStrings.sumNetwork(true), contains('doğrudan bağlantı açık'));
      // B8: with no Sense server the summary says "Genel sunucu", not "Sense sunucusu".
      expect(SenseSettingsStrings.sumNetwork(true, publicServer: true), startsWith('Genel sunucu'));
      expect(SenseSettingsStrings.sumNetwork(true), startsWith('Sense sunucusu'));
      expect(SenseSettingsStrings.directIp, isNot(contains('Doğrudan')));
    });

    testWidgets('Bağlantılar: shortcut hint follows decision 71 (Ctrl+Alt+Shift, no arrows)', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.connections);
      final hint = SenseSettingsStrings.shortcutsHint;
      expect(find.text(hint), findsOneWidget);
      expect(hint, contains('Ctrl+Alt+Shift+B'));
      expect(hint, contains('Ctrl+Alt+Shift+Q'));
      expect(hint, isNot(contains('Ctrl+Alt+F')));
      expect(RegExp('[←→↑↓]').hasMatch(hint), isFalse);
    });

    testWidgets('hardware decoder (main store)', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.performance);
      await _tapRow(tester, 'enable-hwcodec');
      expect(b.writes.last.toString(), 'enable-hwcodec/main=N');
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(find.text(SenseSettingsStrings.sumHwcodec(false)), findsOneWidget);
    });

    testWidgets('network: server, panel, proxy (decision 5), direct; all locked', (tester) async {
      final b = _FakeBackend()
        ..stores[SenseOptionStore.main]!.addAll({
          'custom-rendezvous-server': 'x',
          'api-server': 'y',
          'proxy-url': '',
        });
      await _pump(tester, b, open: SenseSettingsCategory.network);
      expect(find.text(SenseSettingsStrings.serverSense), findsOneWidget);
      expect(find.text(SenseSettingsStrings.panelSense), findsOneWidget);
      expect(find.text(SenseSettingsStrings.proxyNone), findsOneWidget);
      expect(find.text(SenseCommonStrings.managedByPanel), findsNWidgets(4));
      // No address is shown on screen.
      expect(find.text('x'), findsNothing);
    });

    testWidgets('update: automatic, from the panel', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.update);
      expect(find.text(SenseSettingsStrings.autoUpdateController), findsOneWidget);
      expect(find.text(SenseCommonStrings.managedByPanel), findsOneWidget);
    });

    testWidgets('a switch the panel locks cannot be changed', (tester) async {
      final b = _FakeBackend(lockedKeys: {
        ...SenseOptionKeys.lockedByDesign,
        'enable-open-new-connections-in-tabs',
        'image_quality',
      });
      await _pump(tester, b, open: SenseSettingsCategory.connections);
      await _tapRow(tester, 'enable-open-new-connections-in-tabs');
      expect(b.writes, isEmpty);
      expect(find.text(SenseCommonStrings.managedByPanel), findsOneWidget);
      await tester.tap(find.text(SenseSettingsStrings.catNew));
      await tester.pumpAndSettle();
      await tester.tap(find.text(SenseSettingsStrings.qualityFast).last);
      await tester.pumpAndSettle();
      expect(b.writes, isEmpty);
    });
  });

  group('page', () {
    testWidgets('overview counts the rows (Controller)', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b);
      expect(find.text(SenseSettingsStrings.overviewTitle('Controller', 15, 10)), findsOneWidget);
      expect(find.text(SenseSettingsStrings.live), findsOneWidget);
    });

    testWidgets('categories in order, no theme category (#38)', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b);
      final ids = [
        SenseSettingsCategory.role,
        SenseSettingsCategory.connections,
        SenseSettingsCategory.newConnections,
        SenseSettingsCategory.incoming,
        SenseSettingsCategory.security,
        SenseSettingsCategory.performance,
        SenseSettingsCategory.network,
        SenseSettingsCategory.update,
      ];
      double y = -1;
      for (final id in ids) {
        final f = find.byKey(ValueKey('sense-acc-$id'));
        expect(f, findsOneWidget, reason: id);
        final top = tester.getTopLeft(f).dy;
        expect(top, greaterThan(y), reason: id);
        y = top;
      }
      expect(find.textContaining('Tema'), findsNothing);
      expect(find.textContaining('Açık tema'), findsNothing);
    });

    testWidgets('one category open at a time', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.connections);
      expect(find.text(SenseSettingsStrings.openInTabs), findsOneWidget);
      await tester.tap(find.text(SenseSettingsStrings.catNew));
      await tester.pumpAndSettle();
      expect(find.text(SenseSettingsStrings.openInTabs), findsNothing);
      expect(find.text(SenseSettingsStrings.viewStyle), findsOneWidget);
    });

    testWidgets('role category is the Host role component (H2 = C3)', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.role);
      expect(find.byType(SenseRoleCategoryBody), findsOneWidget);
      expect(find.text('Controller'), findsWidgets);
    });

    testWidgets('Host + Controller: password flow and the Host rows', (tester) async {
      final b = _FakeBackend(homeRole: SenseHomeRole.both);
      await _pump(tester, b,
          open: SenseSettingsCategory.security, password: const Text('password-flow', key: Key('pw')));
      expect(find.byKey(const Key('pw')), findsOneWidget);
      await tester.tap(find.text(SenseSettingsStrings.catPerformance));
      await tester.pumpAndSettle();
      expect(find.text(SenseSettingsStrings.directx), findsOneWidget);
      expect(find.text(SenseSettingsStrings.wallpaper), findsOneWidget);
      expect(find.text(SenseSettingsStrings.hwcodec), findsOneWidget);
    });

    testWidgets('fits the smallest screen (T9)', (tester) async {
      final b = _FakeBackend();
      await _pump(tester, b, open: SenseSettingsCategory.newConnections, size: const Size(1280 - 212, 720));
      expect(tester.takeException(), isNull);
    });

    test('no upstream product name in the settings screens', () {
      final banned = RegExp('rust' 'desk', caseSensitive: false);
      for (final dir in ['lib/sense/screens/controller/settings', 'lib/sense/screens/controller/about']) {
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
          expect(banned.hasMatch(f.readAsStringSync()), isFalse, reason: f.path);
        }
      }
      for (final f in ['lib/sense/strings/settings.dart', 'lib/sense/strings/about.dart']) {
        expect(banned.hasMatch(File(f).readAsStringSync()), isFalse, reason: f);
      }
    });

    test('folder labels', () {
      expect(senseFolderShort(''), SenseSettingsStrings.downloads);
      expect(senseFolderShort(r'D:\Sense Gelen'), 'Sense Gelen');
      expect(senseFolderShort('/home/a/Kayit/'), 'Kayit');
      expect(senseFolderLabel(' '), SenseSettingsStrings.downloads);
    });
  });

  group('golden images (a03, s10, s11, s12)', () {
    for (final e in {
      'settings_role': SenseSettingsCategory.role,
      'settings_connections': SenseSettingsCategory.connections,
      'settings_new': SenseSettingsCategory.newConnections,
      'settings_security': SenseSettingsCategory.security,
      'settings_incoming': SenseSettingsCategory.incoming,
    }.entries) {
      testWidgets(e.key, (tester) async {
        final b = _FakeBackend()
          ..stores[SenseOptionStore.local]!.addAll({
            'allow-sync-clipboard-between-sessions': 'N',
          })
          ..stores[SenseOptionStore.main]!.addAll({'custom-rendezvous-server': 'x', 'api-server': 'y'});
        await _pump(tester, b, open: e.value, size: const Size(1450, 1000));
        await expectLater(find.byType(SenseSettingsView), matchesGoldenFile(goldenPath(e.key)));
      }, skip: goldenSkip(e.key), tags: const ['golden']);
    }
  });
}
