// Sense Remote: Host window (plan B2; YH H1, H2; prototype "Bu bilgisayar", images
// a09–a11). Pure rules, every button / field / category of the page, the
// permanent password and role flows with fake bridges, the "no way to the
// settings" check (TK9 Risk H1) and the golden images.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/state_model.dart' show SvcStatus;
import 'package:flutter_hbb/sense/screens/host/data/host_status.dart';
import 'package:flutter_hbb/sense/screens/host/data/identity.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_model.dart' show SenseLoginStatus;
import 'package:flutter_hbb/sense/screens/host/host_format.dart';
import 'package:flutter_hbb/sense/screens/host/password/password_category.dart';
import 'package:flutter_hbb/sense/screens/host/password/password_rules.dart';
import 'package:flutter_hbb/sense/screens/host/permissions/permissions_category.dart';
import 'package:flutter_hbb/sense/screens/host/recent/recent_category.dart';
import 'package:flutter_hbb/sense/screens/host/role/role_category.dart';
import 'package:flutter_hbb/sense/screens/host/sense_password_model.dart';
import 'package:flutter_hbb/sense/screens/host/shell/host_shell.dart';
import 'package:flutter_hbb/sense/screens/host/this_computer/this_computer_view.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/strings/host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'host_support.dart';

const _allOn = [true, true, true, true, true, true, true, true];

SenseThisComputerView _view({
  SenseHostPhase phase = SenseHostPhase.ready,
  SenseIdentity identity = kIdentity,
  SensePasswordController? password,
  SenseRoleController? role,
  List<bool> permissions = _allOn,
  List<SenseRecentConnection> recent = const [],
  Future<String?> Function(String)? onRename,
  Future<String?> Function(SensePlace)? onPlace,
  VoidCallback? onRetry,
  VoidCallback? onStartService,
  VoidCallback? onOpenPermissions,
  VoidCallback? onOpenSettingsPassword,
  List<String> macMissing = const [],
  int connections = 0,
  String? connectedBy,
  int? connectedSeconds,
  String? initialOpen,
}) =>
    SenseThisComputerView(
      phase: phase,
      identity: identity,
      deviceId: '482 913 207',
      permissions: permissions,
      recent: recent,
      now: DateTime(2026, 11, 23, 12),
      macMissing: macMissing,
      connections: connections,
      connectedBy: connectedBy,
      connectedSeconds: connectedSeconds,
      onRetry: onRetry,
      onStartService: onStartService,
      onOpenPermissions: onOpenPermissions,
      onRename: onRename,
      onPlace: onPlace,
      passwordController: password,
      passwordStatus: SensePasswordStatus.parse(statusJson({})),
      onOpenSettingsPassword: onOpenSettingsPassword,
      roleController: role,
      initialOpen: initialOpen,
    );

final _recent = [
  SenseRecentConnection(who: 'Mevlüt', at: DateTime(2026, 11, 22, 17, 10), seconds: 14 * 60, screens: 2),
  SenseRecentConnection(who: 'Halil', at: DateTime(2026, 11, 12, 9, 30), seconds: 6 * 60, screens: 1),
];

void main() {
  group('pure rules', () {
    test('state of the status box: stopped and macOS win, a connection is "Bağlı"', () {
      SenseHostPhase p({SvcStatus svc = SvcStatus.ready, bool stopped = false, bool mac = false, int n = 0}) =>
          senseHostPhase(svc: svc, stopped: stopped, macBlocked: mac, connections: n);
      expect(p(), SenseHostPhase.ready);
      expect(p(svc: SvcStatus.connecting), SenseHostPhase.connecting);
      expect(p(svc: SvcStatus.notReady), SenseHostPhase.down);
      expect(p(stopped: true, mac: true, n: 1), SenseHostPhase.stopped);
      expect(p(mac: true, n: 1), SenseHostPhase.mac);
      expect(p(n: 1, svc: SvcStatus.notReady), SenseHostPhase.busy);
      expect(senseHostPhaseLevel(SenseHostPhase.ready), SenseLevel.ok);
      expect(senseHostPhaseLevel(SenseHostPhase.connecting), SenseLevel.warn);
      for (final hot in [SenseHostPhase.down, SenseHostPhase.stopped, SenseHostPhase.mac]) {
        expect(senseHostPhaseLevel(hot), SenseLevel.hot);
        expect(senseHostPhaseWord(hot), 'Hazır değil');
      }
      expect(senseHostPhaseWord(SenseHostPhase.busy), 'Bağlı');
    });

    test('identity JSON and save answers', () {
      final i = SenseIdentity.parse(jsonEncode({
        'name': ' Galeri kioskı ',
        'location_id': 'g1',
        'location_name': 'Galeri 1',
        'locations': [
          {'id': 'g1', 'name': 'Galeri 1'},
          {'id': 'x', 'name': ''},
          'bad',
        ],
        'panel': 'unreachable',
      }));
      expect(i.name, 'Galeri kioskı');
      expect(i.places, const [SensePlace('g1', 'Galeri 1')]);
      expect(i.panelOk, isFalse);
      expect(SenseIdentity.parse('nope').name, '');
      expect(SenseIdentity.parse('{"panel":"ok"}').panelOk, isTrue);
      expect(senseIdentitySetError('{"ok":true}'), isNull);
      expect(senseIdentitySetError('{"error":"network"}'), 'network');
      expect(senseIdentitySetError('garbage'), 'other');
      expect(senseIdentityErrorText('location_not_in_project'), SenseHostStrings.errLocation);
      expect(senseIdentityErrorText('unavailable'), SenseHostStrings.errUnavailable);
      expect(senseIdentityErrorText('zzz'), SenseHostStrings.errOther);
    });

    test('role sets and answers', () {
      expect(senseRoleTarget({SenseRole.host}), 'host');
      expect(senseRoleTarget({SenseRole.controller}), 'controller');
      expect(senseRoleTarget(SenseRole.values.toSet()), 'host_controller');
      expect(senseRoleTarget({}), isNull);
      final s = SenseRoleStatus.parse('{"roles":["host_controller"],"pending":{"target":"host","stage":"applying"}}');
      expect(s.roles, SenseRole.values.toSet());
      expect(s.pendingStage, 'applying');
      final a = SenseRoleAnswer.parse('{"pairing_code":"731054","url":"$kUrl","expires_at":5}');
      expect(a.code, '731054');
      expect(a.expiresAt, 5);
      expect(SenseRoleAnswer.parse('x').error, 'other');
      expect(senseRoleSetName(SenseRole.values.toSet()), 'Host + Controller');
      for (final code in ['admin_denied', 'role_change_denied', 'last_role', 'timeout', 'network', 'unavailable']) {
        expect(senseRoleErrorText(code), isNot(SenseHostStrings.roleErrOther), reason: code);
      }
    });

    test('password rule list follows the service rule (rule.rs cases)', () {
      bool ok(String p) => sensePasswordRulesMet(p, p, '123456789');
      expect(ok('Mavi-Kapi_47!tuz'), isTrue);
      expect(ok('Mavi Kapi 47 tuz'), isFalse); // charset
      expect(ok('aB3\$eF7!kL9'), isFalse); // length
      expect(ok('123456789012'), isFalse); // sequence
      expect(ok('lkjihgfedcba'), isFalse); // descending
      expect(ok('Kx7#mKx7#mKx'), isFalse); // 5 different characters
      expect(ok('Kx!123456789#Tz'), isFalse); // contains the ID
      expect(sensePasswordRulesMet('Mavi-Kapi_47!tuz', 'Mavi-Kapi_47!tu', ''), isFalse);
      final empty = sensePasswordRuleLines('', '', '1');
      expect(empty.every((l) => l.met == null), isTrue);
      expect(empty.map((l) => l.text), [
        '12–64 karakter',
        'Boşluk yok, İngilizce harf/rakam/işaret',
        '1234 ya da aaaa gibi dizi yok',
        'Kimliği içermiyor',
        'İki şifre aynı',
      ]);
      expect(sensePasswordRuleLines('x' * 65, '', '').first.met, isFalse);
    });

    test('dates, durations and summaries', () {
      final now = DateTime(2026, 11, 23, 12);
      expect(senseHostDate(DateTime(2026, 11, 12)), '12 Kas 2026');
      expect(senseHostDay(DateTime(2026, 11, 23, 8), now), 'bugün');
      expect(senseHostDayTime(DateTime(2026, 11, 22, 17, 10), now), 'dün 17:10');
      expect(senseHostDay(DateTime(2025, 3, 2), now), '2 Mar 2025');
      expect(SenseHostStrings.duration(14 * 60), '14 dk');
      expect(SenseHostStrings.duration(30), '1 dk');
      expect(SenseHostStrings.duration(65 * 60), '1 sa 5 dk');
      expect(senseHostPairingCode('482913'), '482 · 913');
      expect(senseHostCountdown(174), '2:54');
      expect(senseHostCountdown(-3), '0:00');
      expect(senseRecentSummary(_recent, now), 'dün · Mevlüt · 14 dk');
      expect(senseRecentSummary(const [], now), 'henüz yok');
      expect(senseRecentLine(_recent.first, now), 'dün 17:10 · 14 dk · 2 ekran');
      expect(senseHostPermissionsSummary([true, false, true]), 'panelden · imzalı · 2 açık');
      expect(senseOptionOn(''), isTrue);
      expect(senseOptionOn('N'), isFalse);
      expect(kSenseHostPermissions.map((p) => p.label), [
        'Ekran', 'Fare ve klavye', 'Pano', 'Dosya', 'Ses', 'Yeniden başlatma', 'Oturum kaydı', 'Hayalet mod', //
      ]);
      final recent = senseRecentParse('[{"name":"Ayşe","at":1000,"seconds":60,"screens":3},{"name":1}]');
      expect(recent, hasLength(1));
      expect(recent.single.screens, 3);
      final set = SensePasswordStatus.parse(statusJson({}));
      expect(senseHostPasswordSummary(set), 'ayarlı · 12 Kas 2026');
      expect(senseHostPasswordLevel(set), SenseLevel.ok);
      final none = SensePasswordStatus.parse(statusJson({'perm_set': false}));
      expect(senseHostPasswordSummary(none), 'ayarlı değil');
      expect(senseHostPasswordLevel(none), SenseLevel.warn);
    });
  });

  group('status box (H1, six states)', () {
    testWidgets('each state: title, text and its one button', (tester) async {
      setWindow(tester, const Size(1180, 900));
      final taps = <String>[];
      final cases = <SenseHostPhase, (String, String?)>{
        SenseHostPhase.ready: ('Hazır — Galeri kioskı', null),
        SenseHostPhase.connecting: ('Bağlanıyor — Galeri kioskı', null),
        SenseHostPhase.down: ('Hazır değil — Galeri kioskı', 'Yeniden dene'),
        SenseHostPhase.stopped: ('Hazır değil — Galeri kioskı', 'Servisi başlat'),
        SenseHostPhase.mac: ('Hazır değil — Galeri kioskı', 'İzinleri aç'),
        SenseHostPhase.busy: ('Bağlı — Galeri kioskı', null),
      };
      for (final e in cases.entries) {
        await tester.pumpWidget(app(page(_view(
          phase: e.key,
          macMissing: const ['Ekran Kaydı', 'Erişilebilirlik'],
          connections: e.key == SenseHostPhase.busy ? 1 : 0,
          connectedBy: e.key == SenseHostPhase.busy ? 'Halil' : null,
          connectedSeconds: e.key == SenseHostPhase.busy ? 14 * 60 : null,
          onRetry: () => taps.add('retry'),
          onStartService: () => taps.add('start'),
          onOpenPermissions: () => taps.add('perm'),
        ))));
        final title = e.value.$1;
        expect(find.textContaining(title.split(' — ').first), findsWidgets, reason: '${e.key}');
        expect(find.text('Galeri kioskı'), findsOneWidget);
        final button = e.value.$2;
        if (button != null) {
          await tester.tap(find.text(button));
          await tester.pump();
        }
        for (final other in ['Yeniden dene', 'Servisi başlat', 'İzinleri aç']) {
          if (other != button) expect(find.text(other), findsNothing, reason: '${e.key} $other');
        }
      }
      expect(taps, ['retry', 'start', 'perm']);
    });

    testWidgets('texts of the states and the tiles', (tester) async {
      setWindow(tester, const Size(1180, 900));
      await tester.pumpWidget(app(page(_view(phase: SenseHostPhase.mac, macMissing: const ['Ekran Kaydı', 'Erişilebilirlik']))));
      expect(find.text('Ekran Kaydı ve Erişilebilirlik izinleri verilmemiş.'), findsOneWidget);
      await tester.pumpWidget(app(page(_view(
          phase: SenseHostPhase.busy, connections: 1, connectedBy: 'Halil', connectedSeconds: 14 * 60))));
      expect(find.text('Halil bu bilgisayarda · 14 dk'), findsOneWidget);
      expect(find.text('1 · Halil'), findsOneWidget);
      await tester.pumpWidget(app(page(_view(phase: SenseHostPhase.busy, connections: 1))));
      expect(find.text('Sense ekibi bu bilgisayarda'), findsOneWidget);
      await tester.pumpWidget(app(page(_view())));
      expect(find.text('Kimlik'), findsOneWidget);
      expect(find.text('482 913 207'), findsOneWidget);
      expect(find.text('Yer'), findsOneWidget);
      expect(find.text('Galeri 1'), findsOneWidget);
      expect(find.text('bağlı'), findsOneWidget);
      expect(find.text('yok'), findsOneWidget);
      await tester.pumpWidget(app(page(_view(
          phase: SenseHostPhase.down, identity: const SenseIdentity(name: 'A', placeName: 'B')))));
      expect(find.text('ulaşılamıyor'), findsOneWidget);
    });

    testWidgets('Kopyala copies the ID and says so', (tester) async {
      setWindow(tester, const Size(1180, 900));
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(app(page(_view())));
      await tester.tap(find.byKey(const Key('sense-host-copy-id')));
      await tester.pump();
      expect(copied, ['482913207']);
      expect(find.text(SenseHostStrings.idCopied), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('name and place in place (#33)', () {
    testWidgets('Enter saves the name: "Kaydedildi · panel ve Controller\'lar güncellendi"', (tester) async {
      setWindow(tester, const Size(1180, 900));
      final names = <String>[];
      await tester.pumpWidget(app(page(_view(onRename: (n) async {
        names.add(n);
        return null;
      }))));
      await tester.tap(find.text('Galeri kioskı'));
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Giriş kioskı');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(names, ['Giriş kioskı']);
      expect(find.text(SenseHostStrings.identitySaved), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(SenseHostStrings.identitySaved), findsNothing);
    });

    testWidgets('Esc gives up; an error is said in place', (tester) async {
      setWindow(tester, const Size(1180, 900));
      final names = <String>[];
      await tester.pumpWidget(app(page(_view(onRename: (n) async {
        names.add(n);
        return 'network';
      }))));
      await tester.tap(find.text('Galeri kioskı'));
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Başka ad');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      expect(names, isEmpty);
      await tester.tap(find.text('Galeri kioskı'));
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Başka ad');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(names, ['Başka ad']);
      expect(find.text(SenseHostStrings.errNetwork), findsOneWidget);
    });

    testWidgets('place: ✎ opens the list of the project places; a choice saves', (tester) async {
      setWindow(tester, const Size(1180, 900));
      final places = <String>[];
      await tester.pumpWidget(app(page(_view(onPlace: (p) async {
        places.add(p.id);
        return null;
      }))));
      await tester.tap(find.byKey(const Key('sense-host-place')));
      await tester.pump();
      expect(find.byKey(const Key('sense-host-place-select')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-host-place-select')));
      await tester.pump();
      await tester.tap(find.text('Lobi').last);
      await tester.pump();
      expect(places, ['lobi']);
      expect(find.text(SenseHostStrings.identitySaved), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('one place only, or no save: no ✎', (tester) async {
      setWindow(tester, const Size(1180, 900));
      await tester.pumpWidget(app(page(_view(
          identity: const SenseIdentity(name: 'A', placeId: 'g1', placeName: 'Galeri 1', places: [SensePlace('g1', 'Galeri 1')]),
          onPlace: (_) async => null))));
      await tester.tap(find.text('Galeri 1'));
      await tester.pump();
      expect(find.byKey(const Key('sense-host-place-select')), findsNothing);
    });
  });

  group('categories (H2)', () {
    testWidgets('one open at a time; summaries on the right', (tester) async {
      setWindow(tester, const Size(1180, 1400));
      final pw = passwordIn(SensePasswordStage.locked);
      final role = roleWith();
      await tester.pumpWidget(app(page(_view(
          password: pw, role: role, recent: _recent, permissions: const [true, true, true, true, true, true, true, false]))));
      expect(find.text('panelden · imzalı · 7 açık'), findsOneWidget);
      expect(find.text('ayarlı · 12 Kas 2026'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('dün · Mevlüt · 14 dk'), findsOneWidget);
      await tester.tap(find.text('Yetkiler'));
      await tester.pump();
      expect(find.text('Fare ve klavye'), findsOneWidget);
      await tester.tap(find.text('Son bağlantılar'));
      await tester.pump();
      expect(find.text('Fare ve klavye'), findsNothing);
      expect(find.text('Mevlüt'), findsOneWidget);
      expect(find.text('12 Kas 09:30 · 6 dk · 1 ekran'), findsOneWidget);
      await tester.tap(find.text('Son bağlantılar'));
      await tester.pump();
      expect(find.text('Mevlüt'), findsNothing);
      pw.dispose();
      role.dispose();
    });

    testWidgets('permissions are locked: a tap changes nothing', (tester) async {
      setWindow(tester, const Size(1180, 1400));
      await tester.pumpWidget(app(page(_view(initialOpen: 'perm'))));
      expect(find.text(SenseHostStrings.permissionsHint), findsOneWidget);
      expect(find.text('Panelden yönetilir'), findsNWidgets(8));
      final toggles = find.byType(SenseToggle);
      expect(toggles, findsNWidgets(8));
      for (final t in tester.widgetList<SenseToggle>(toggles)) {
        expect(t.locked, isTrue);
        expect(t.onChanged, isNull);
      }
      await tester.tap(toggles.first);
      await tester.pump();
      expect(tester.widget<SenseToggle>(toggles.first).value, isTrue);
    });

    testWidgets('no recent connection yet', (tester) async {
      setWindow(tester, const Size(1180, 1200));
      await tester.pumpWidget(app(page(_view(initialOpen: 'recent'))));
      expect(find.text('henüz yok'), findsOneWidget);
      expect(find.text(SenseHostStrings.recentEmpty), findsOneWidget);
    });

    testWidgets('Host + Controller: password opens Ayarlar, no role category', (tester) async {
      setWindow(tester, const Size(1180, 1200));
      var opened = 0;
      await tester.pumpWidget(app(page(_view(initialOpen: 'pw', onOpenSettingsPassword: () => opened++))));
      expect(find.text(SenseHostStrings.role), findsNothing);
      await tester.tap(find.text("Ayarlar'da aç"));
      expect(opened, 1);
    });
  });

  group('permanent password in the category (H2)', () {
    testWidgets('Değiştir → code + QR + countdown → Vazgeç', (tester) async {
      setWindow(tester, const Size(1180, 1200));
      final fake = FakePassword();
      var t = kNow;
      final c = SensePasswordController(fake, interval: const Duration(days: 1), now: () => kNow);
      await c.load();
      await tester.pumpWidget(app(page(SensePasswordCategoryBody(controller: c, deviceId: '482 913 207', now: () => t))));
      expect(find.textContaining('Ayarlı · son değişiklik 12 Kas 2026'), findsOneWidget);
      await tester.tap(find.text('Değiştir'));
      await tester.pump();
      expect(fake.calls, ['begin']);
      expect(find.text(SenseHostStrings.preparing), findsOneWidget);
      await c.tick();
      await tester.pump();
      expect(find.text('482 · 913'), findsOneWidget);
      expect(find.byKey(const Key('sense-host-qr')), findsOneWidget);
      expect(find.text('Onay bekleniyor · 3:00'), findsOneWidget);
      t += 6;
      c.notifyListeners();
      await tester.pump();
      expect(find.text('Onay bekleniyor · 2:54'), findsOneWidget);
      await tester.tap(find.text('Bağlantıyı kopyala'));
      await tester.pump();
      expect(fake.calls, contains('copy'));
      await tester.tap(find.text('Vazgeç'));
      await tester.pump();
      await tester.pump();
      expect(fake.calls, contains('cancel'));
      expect(find.text('Değiştir'), findsOneWidget);
      c.dispose();
    });

    testWidgets('not set: Belirle; network error is said in place', (tester) async {
      setWindow(tester, const Size(1180, 1200));
      final fake = FakePassword()
        ..statusAnswer = statusJson({'perm_set': false})
        ..beginAnswer = '{"ok":false,"error":"network"}';
      final c = SensePasswordController(fake, interval: const Duration(days: 1), now: () => kNow);
      await c.load();
      await tester.pumpWidget(app(page(SensePasswordCategoryBody(controller: c, deviceId: '1'))));
      expect(find.text(SenseHostStrings.passwordRowNone), findsOneWidget);
      await tester.tap(find.text('Belirle'));
      await tester.pump();
      expect(find.text('Panele ulaşılamadı. Ağ bağlantısını denetleyip yeniden dene.'), findsOneWidget);
      c.dispose();
    });

    testWidgets('approval timed out', (tester) async {
      setWindow(tester, const Size(1180, 1200));
      final fake = FakePassword()..logins = [jsonEncode({'state': 'failed', 'error': 'timeout'})];
      final c = SensePasswordController(fake, interval: const Duration(days: 1), now: () => kNow);
      await c.load();
      await tester.pumpWidget(app(page(SensePasswordCategoryBody(controller: c, deviceId: '1'))));
      await tester.tap(find.text('Değiştir'));
      await tester.pump();
      await c.tick();
      await tester.pump();
      expect(find.text('Onay zamanında gelmedi. Yeniden doğrula.'), findsOneWidget);
      c.dispose();
    });

    testWidgets('live rules, Kaydet only when every rule is met, then back with a toast', (tester) async {
      setWindow(tester, const Size(1180, 1200));
      final fake = FakePassword()
        ..logins = [
          jsonEncode({'state': 'waiting', 'url': kUrl, 'pairing_code': '482913'}),
          jsonEncode({'state': 'done', 'user': {'name': 'halil@example.com'}}),
        ];
      final c = SensePasswordController(fake, interval: const Duration(days: 1), now: () => kNow);
      await c.load();
      await tester.pumpWidget(app(page(SensePasswordCategoryBody(controller: c, deviceId: '482 913 207'))));
      await tester.tap(find.text('Değiştir'));
      await tester.pump();
      await c.tick();
      await c.tick();
      await tester.pump();
      expect(find.text('Yeni kalıcı şifre'), findsOneWidget);
      expect(find.textContaining('Doğrulandı: Halil · 5:00'), findsOneWidget);
      SenseButton save() => tester.widget<SenseButton>(find.byKey(const Key('sense-pw-save')));
      expect(save().onPressed, isNull);
      await tester.enterText(find.byKey(const Key('sense-pw-new')), 'x482913207abcQ!');
      await tester.pump();
      expect(find.text('✕ Kimliği içermiyor'), findsOneWidget);
      expect(find.text('· İki şifre aynı'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('sense-pw-new')), 'Mavi-Kapi_47!tuz');
      await tester.enterText(find.byKey(const Key('sense-pw-repeat')), 'Mavi-Kapi_47!tuz');
      await tester.pump();
      expect(find.text('✓ İki şifre aynı'), findsOneWidget);
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('sense-pw-save')));
      await tester.pump();
      await tester.pump();
      expect(fake.calls, containsAllInOrder(['check', 'set']));
      expect(fake.setPasswords, ['Mavi-Kapi_47!tuz']);
      expect(find.text(SenseHostStrings.passwordChangedToast), findsOneWidget);
      expect(find.text('Değiştir'), findsOneWidget);
      expect(c.password.text, isEmpty);
      await tester.pump(const Duration(seconds: 3));
      c.dispose();
    });

    testWidgets('the unlock window ends: "Süre doldu"', (tester) async {
      setWindow(tester, const Size(1180, 1200));
      var t = kNow;
      final fake = FakePassword();
      final c = SensePasswordController(fake, interval: const Duration(days: 1), now: () => t);
      c.status = SensePasswordStatus.parse(statusJson({}));
      c.stage = SensePasswordStage.unlocked;
      c.until = kNow + 10;
      c.user = 'Halil';
      await tester.pumpWidget(app(page(SensePasswordCategoryBody(controller: c, deviceId: '1'))));
      expect(find.textContaining('0:10 içinde kilitlenir'), findsOneWidget);
      t += 11;
      await c.tick();
      await tester.pump();
      expect(find.text('Süre doldu. Yeniden doğrula.'), findsOneWidget);
      expect(fake.calls, contains('cancel'));
      c.dispose();
    });
  });

  group('role of this computer (H2, S4)', () {
    Future<SenseRoleController> pumpRole(WidgetTester tester, FakeRole fake, {VoidCallback? onRestart}) async {
      setWindow(tester, const Size(1180, 1000));
      final c = SenseRoleController(fake, interval: const Duration(days: 1), now: () => kNow, onRestart: onRestart);
      await c.load();
      await tester.pumpWidget(app(page(SenseRoleCategoryBody(controller: c))));
      return c;
    }

    testWidgets('add Controller → verify → applying → splash (restart)', (tester) async {
      final fake = FakeRole()..statuses = ['{"stage":"login"}', '{"stage":"applying"}', '{"stage":"restarting"}'];
      var restarted = 0;
      final c = await pumpRole(tester, fake, onRestart: () => restarted++);
      expect(find.text('kurulu'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-role-card-controller')));
      await tester.pump();
      expect(find.text('Controller eklenecek'), findsOneWidget);
      expect(find.textContaining('Windows yönetici onayı'), findsOneWidget);
      await tester.tap(find.text('Sense hesabıyla doğrula'));
      await tester.pump();
      expect(fake.calls, ['begin:host_controller']);
      expect(find.text('731 · 054'), findsOneWidget);
      expect(find.text('Onay bekleniyor · 2:54'), findsOneWidget);
      await c.tick();
      await tester.pump();
      expect(find.byKey(const Key('sense-role-login')), findsOneWidget);
      await c.tick();
      await tester.pump();
      expect(find.text('Rol uygulanıyor… Windows yönetici onayı isteyecek.'), findsOneWidget);
      await c.tick();
      await tester.pump();
      expect(restarted, 1);
      expect(find.byKey(const Key('sense-role-restarting')), findsOneWidget);
      c.dispose();
    });

    testWidgets('removing Host warns in orange; Vazgeç restores', (tester) async {
      final c = await pumpRole(tester, FakeRole(roles: ['host_controller']));
      await tester.tap(find.byKey(const Key('sense-role-card-host')));
      await tester.pump();
      expect(find.text('Host kaldırılacak'), findsOneWidget);
      expect(find.textContaining('Sense ekibi bu bilgisayara artık bağlanamaz'), findsOneWidget);
      final title = tester.widget<Text>(find.text('Host kaldırılacak'));
      expect(title.style!.color, SenseColors.warn);
      await tester.tap(find.byKey(const Key('sense-role-reset')));
      await tester.pump();
      expect(find.text('Host kaldırılacak'), findsNothing);
      c.dispose();
    });

    testWidgets('the last role can not be removed', (tester) async {
      final c = await pumpRole(tester, FakeRole());
      await tester.tap(find.byKey(const Key('sense-role-card-host')));
      await tester.pump();
      expect(find.text(SenseHostStrings.lastRole), findsOneWidget);
      expect(find.text('Sense hesabıyla doğrula'), findsNothing);
      await c.verify();
      expect(c.stage, SenseRoleStage.idle);
      c.dispose();
    });

    testWidgets('errors: no right, admin said no, approval cancelled', (tester) async {
      final fake = FakeRole()..beginAnswer = '{"error":"role_change_denied"}';
      final c = await pumpRole(tester, fake);
      await tester.tap(find.byKey(const Key('sense-role-card-controller')));
      await tester.pump();
      await tester.tap(find.text('Sense hesabıyla doğrula'));
      await tester.pump();
      expect(find.text(SenseHostStrings.roleErrDenied), findsOneWidget);
      fake.beginAnswer = jsonEncode({'pairing_code': '731054', 'url': kUrl});
      fake.statuses = ['{"error":"admin_denied"}'];
      await tester.tap(find.text('Sense hesabıyla doğrula'));
      await tester.pump();
      expect(find.text(SenseHostStrings.roleWaitLong), findsOneWidget);
      await c.tick();
      await tester.pump();
      expect(find.text(SenseHostStrings.roleErrAdminDenied), findsOneWidget);
      await tester.tap(find.text('Sense hesabıyla doğrula'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-role-cancel')));
      await tester.pump();
      expect(fake.calls.last, 'cancel');
      expect(find.text('Controller eklenecek'), findsOneWidget);
      c.dispose();
    });

    testWidgets('approval window ends on this side too', (tester) async {
      var t = kNow;
      final fake = FakeRole();
      setWindow(tester, const Size(1180, 1000));
      final c = SenseRoleController(fake, interval: const Duration(days: 1), now: () => t);
      await c.load();
      await tester.pumpWidget(app(page(SenseRoleCategoryBody(controller: c, mac: true))));
      c.toggle(SenseRole.controller);
      await tester.pump();
      expect(find.textContaining('macOS yönetici parolası'), findsOneWidget);
      await c.verify();
      t += 200;
      await c.tick();
      await tester.pump();
      expect(find.text(SenseHostStrings.roleErrTimeout), findsOneWidget);
      expect(fake.calls.last, 'cancel');
      c.dispose();
    });
  });

  group('window (H1)', () {
    testWidgets('menu: Bu bilgisayar, Hakkında; version opens Hakkında', (tester) async {
      setWindow(tester, const Size(1180, 720));
      final navs = <SenseHostNav>[];
      await tester.pumpWidget(app(SenseHostShellView(
        nav: SenseHostNav.thisComputer,
        version: 4,
        onNav: navs.add,
        child: const Text('sayfa'),
      )));
      expect(find.text('Panelden yönetilir'), findsOneWidget);
      expect(find.text('Sürüm 4'), findsOneWidget);
      await tester.tap(find.text('Hakkında'));
      await tester.tap(find.text('Sürüm 4'));
      await tester.tap(find.byKey(const Key('sense-host-nav-this')));
      expect(navs, [SenseHostNav.about, SenseHostNav.about, SenseHostNav.thisComputer]);
      expect(find.text('Ayarlar'), findsNothing);
    });

    testWidgets('no version number: no chip (nothing made up); splash on role change', (tester) async {
      setWindow(tester, const Size(1180, 720));
      await tester.pumpWidget(app(SenseHostShellView(
          nav: SenseHostNav.about, onNav: (_) {}, splash: true, child: const SizedBox())));
      expect(find.byKey(const Key('sense-host-version')), findsNothing);
      expect(find.byKey(const Key('sense-host-splash')), findsOneWidget);
    });

    test('TK9 Risk H1: nothing of the Host window leads to the settings tab page', () {
      final dirs = ['shell', 'this_computer', 'password', 'role', 'recent', 'permissions', 'data'];
      final banned = RegExp(r'senseOpenAbout|DesktopSettingPage|onAddSetting|switch2page|SettingsTabKey');
      final upstream = RegExp('rust' 'desk', caseSensitive: false);
      var files = 0;
      for (final d in dirs) {
        for (final f in Directory('lib/sense/screens/host/$d').listSync(recursive: true).whereType<File>()) {
          final src = f.readAsStringSync();
          expect(banned.hasMatch(src), isFalse, reason: f.path);
          expect(upstream.hasMatch(src), isFalse, reason: f.path);
          files++;
        }
      }
      expect(files, greaterThan(10));
      expect(upstream.hasMatch(File('lib/sense/strings/host.dart').readAsStringSync()), isFalse);
      // The Host branch of the home page builds only the Sense window.
      final home = File('lib/desktop/pages/desktop_home_page.dart').readAsStringSync();
      final start = home.indexOf('if (senseHomeRole() == SenseHomeRole.host) {\n      return _buildBlock(');
      expect(start, greaterThan(0));
      final branch = home.substring(start, home.indexOf('}', start));
      expect(branch, contains('SenseHostShell()'));
      expect(branch, isNot(contains('buildLeftPane')));
      expect(branch, isNot(contains('Password')));
    });
  });

  group('golden images (a09–a11)', () {
    Widget window(Widget child, {SenseHostNav nav = SenseHostNav.thisComputer}) => RepaintBoundary(
          key: const Key('golden'),
          child: SizedBox(
            width: SenseSizes.windowWidth,
            height: SenseSizes.windowHeight,
            child: SenseHostShellView(nav: nav, version: 4, onNav: (_) {}, child: child),
          ),
        );

    Future<void> shot(WidgetTester tester, String name, Widget child, {Size size = const Size(1180, 720)}) async {
      setWindow(tester, size);
      await tester.pumpWidget(app(Align(alignment: Alignment.topLeft, child: child)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile(name)));
    }

    testWidgets('a09: Bu bilgisayar, categories closed', (tester) async {
      final pw = passwordIn(SensePasswordStage.locked);
      final role = roleWith();
      await shot(tester, 'host_a09', window(_view(password: pw, role: role, recent: _recent)));
      pw.dispose();
      role.dispose();
    }, skip: goldenSkip('host_a09'));

    testWidgets('a10: Kalıcı şifre · doğrulama', (tester) async {
      final pw = passwordIn(SensePasswordStage.verifying)
        ..login = const SenseLoginStatus('waiting', url: kUrl, pairingCode: '482913');
      final role = roleWith();
      await shot(tester, 'host_a10', window(_view(password: pw, role: role, recent: _recent, initialOpen: 'pw')));
      pw.dispose();
      role.dispose();
    }, skip: goldenSkip('host_a10'));

    testWidgets('a11: Bu bilgisayarın rolü, Controller eklenecek', (tester) async {
      final pw = passwordIn(SensePasswordStage.locked);
      final role = roleWith()..toggle(SenseRole.controller);
      await shot(tester, 'host_a11', window(_view(password: pw, role: role, recent: _recent, initialOpen: 'role')));
      pw.dispose();
      role.dispose();
    }, skip: goldenSkip('host_a11'));

    testWidgets('status box: the six states', (tester) async {
      Widget one(SenseHostPhase p) => SizedBox(
            width: 580,
            child: _view(
              phase: p,
              macMissing: const ['Ekran Kaydı', 'Erişilebilirlik'],
              connections: p == SenseHostPhase.busy ? 1 : 0,
              connectedBy: p == SenseHostPhase.busy ? 'Halil' : null,
              connectedSeconds: p == SenseHostPhase.busy ? 14 * 60 : null,
              onRetry: () {},
              onStartService: () {},
              onOpenPermissions: () {},
            ),
          );
      await shot(
          tester,
          'host_states',
          RepaintBoundary(
            key: const Key('golden'),
            child: Container(
              color: SenseColors.bg,
              padding: const EdgeInsets.all(10),
              width: 1200,
              child: Wrap(spacing: 20, runSpacing: 20, children: [for (final p in SenseHostPhase.values) one(p)]),
            ),
          ),
          size: const Size(1200, 1500));
    }, skip: goldenSkip('host_states'));

    testWidgets('password and role steps', (tester) async {
      var t = kNow;
      final pws = [
        passwordIn(SensePasswordStage.locked, status: {'perm_set': false}),
        passwordIn(SensePasswordStage.verifying),
        passwordIn(SensePasswordStage.unlocked)
          ..until = kNow + 263
          ..user = 'Halil',
        passwordIn(SensePasswordStage.expired)..message = 'Panele ulaşılamadı. Ağ bağlantısını denetleyip yeniden dene.',
      ];
      pws[2].password.text = 'Mavi-Kapi_47!';
      pws[2].repeat.text = 'Mavi';
      final roles = [
        roleWith(current: SenseRole.values.toSet())..toggle(SenseRole.host),
        roleWith()..toggle(SenseRole.host),
        roleWith()
          ..stage = SenseRoleStage.login
          ..code = '731054'
          ..url = kUrl
          ..expiresAt = kNow + 174,
        roleWith()..stage = SenseRoleStage.applying,
        roleWith()..error = SenseHostStrings.roleErrDenied,
      ];
      Widget box(Widget child) => Container(
            width: 560,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: SenseColors.surface,
                border: Border.all(color: SenseColors.line),
                borderRadius: BorderRadius.circular(SenseRadii.categoryLarge)),
            child: child,
          );
      await shot(
          tester,
          'host_steps',
          RepaintBoundary(
            key: const Key('golden'),
            child: Container(
              color: SenseColors.bg,
              padding: const EdgeInsets.all(10),
              width: 1200,
              child: Wrap(spacing: 20, runSpacing: 20, children: [
                for (final c in pws) box(SensePasswordCategoryBody(controller: c, deviceId: '482 913 207', now: () => t)),
                for (final c in roles) box(SenseRoleCategoryBody(controller: c)),
              ]),
            ),
          ),
          size: const Size(1200, 1700));
      for (final c in pws) {
        c.dispose();
      }
      for (final c in roles) {
        c.dispose();
      }
    }, skip: goldenSkip('host_steps'));
  });
}
