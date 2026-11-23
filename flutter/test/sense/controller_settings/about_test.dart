// Sense Remote: About (YH C4; image a04). Status box Güncel + Denetle / Yeni
// sürüm hazır + Güncelle (macOS in place), tiles, licenses as a category (no
// window), © line; Host never reaches Settings (H1).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart' show senseSettingsTabPage;
import 'package:flutter_hbb/sense/screens/controller/about/sense_about_page.dart';
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart';
import 'package:flutter_hbb/sense/screens/controller/settings/sense_settings_page.dart';
import 'package:flutter_hbb/sense/screens/controller/update/sense_update_view.dart';
import 'package:flutter_hbb/sense/strings/about.dart';
import 'package:flutter_hbb/sense/strings/update.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _FakeUpdate extends SenseUpdateBackend {
  _FakeUpdate(this.json);
  Map<String, Object?> json;
  int polls = 0;
  final installs = <int>[];
  String answer = '';

  @override
  Future<String> status() async {
    polls++;
    return jsonEncode({'current': 3, 'supported': true, ...json});
  }

  @override
  Future<String> install(int version) async {
    installs.add(version);
    return answer;
  }

  @override
  String seenInstalled() => '';
  @override
  Future<void> setSeenInstalled(String key) async {}
  @override
  void openUrl(String url) {}
}

class _FakeAbout implements SenseAboutBackend {
  _FakeAbout({this.homeRole = SenseHomeRole.controller, this.name = 'Halil', Map<String, Object?>? update})
      : update = _FakeUpdate(update ?? {'state': 'idle', 'checked_at': 1000});

  final SenseHomeRole homeRole;
  final String name;
  final opened = <String>[];

  @override
  final _FakeUpdate update;

  @override
  int? version() => 3;
  @override
  SenseHomeRole role() => homeRole;
  @override
  String account() => name;
  @override
  Future<String> myId() async => '482913207';
  @override
  Future<String> fingerprint() async => '3f2a91c0 77aa 01';
  @override
  Future<String> baseVersion() async => '1.4.3';
  @override
  void openUrl(String url) => opened.add(url);
}

Future<void> _pump(WidgetTester tester, _FakeAbout b, {bool licenses = false, Size size = const Size(1450, 1000)}) async {
  await pumpSense(
      tester,
      SizedBox(
        width: size.width,
        height: size.height,
        child: SenseAboutView(backend: b, year: 2026, now: () => 1240, licensesOpen: licenses),
      ),
      size: size,
      center: false);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Güncel + Denetle: Denetle asks the status again', (tester) async {
    final b = _FakeAbout();
    await _pump(tester, b);
    expect(find.text('Güncel'), findsOneWidget);
    expect(find.text('Son denetim 4 dk önce · panelden otomatik'), findsOneWidget);
    final before = b.update.polls;
    await tester.tap(find.byKey(const Key('sense-about-check')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(b.update.polls, before + 1);
    final note = tester.widget<AnimatedOpacity>(
        find.ancestor(of: find.text(senseUpdateText('checked_current')), matching: find.byType(AnimatedOpacity)).first);
    expect(note.opacity, 1);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testWidgets('Yeni sürüm hazır + Güncelle installs the target', (tester) async {
    final b = _FakeAbout(update: {'state': 'available', 'target': 4, 'checked_at': 1000});
    await _pump(tester, b);
    expect(find.text('Yeni sürüm hazır: Sürüm 4'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-about-update')));
    await tester.pumpAndSettle();
    expect(b.update.installs, [4]);
  });

  testWidgets('a refused install is said in the box', (tester) async {
    final b = _FakeAbout(update: {'state': 'available', 'target': 4, 'checked_at': 1000});
    b.update.answer = 'busy';
    await _pump(tester, b);
    await tester.tap(find.byKey(const Key('sense-about-update')));
    await tester.pumpAndSettle();
    expect(find.text('Güncelleme zaten sürüyor.'), findsOneWidget);
  });

  testWidgets('macOS: second step in place; Vazgeç does not update', (tester) async {
    final b = _FakeAbout(
        update: {'state': 'available', 'target': 4, 'checked_at': 1000, 'mac_permission_warning': true});
    await _pump(tester, b);
    await tester.tap(find.byKey(const Key('sense-about-update')));
    await tester.pumpAndSettle();
    expect(find.text(senseUpdateText('mac_short')), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    await tester.tap(find.byKey(const Key('sense-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(b.update.installs, isEmpty);
    await tester.tap(find.byKey(const Key('sense-about-update')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sense-confirm-ok')));
    await tester.pumpAndSettle();
    expect(b.update.installs, [4]);
  });

  testWidgets('tiles: role, panel, account, id (Controller), fingerprint', (tester) async {
    final b = _FakeAbout();
    await _pump(tester, b);
    expect(find.text('Controller'), findsOneWidget);
    expect(find.text('bağlı · Halil'), findsOneWidget);
    expect(find.text('Halil · Sense Department'), findsOneWidget);
    expect(find.text('482 913 207'), findsOneWidget);
    expect(find.text('3F2A · 91C0 · …'), findsOneWidget);
    expect(find.text('Sürüm 3'), findsOneWidget);
    expect(find.text('© 2026 Sense Department'), findsOneWidget);
  });

  testWidgets('Host: no Kimlik tile, panel managed', (tester) async {
    final b = _FakeAbout(homeRole: SenseHomeRole.host, name: '');
    await _pump(tester, b);
    expect(find.byKey(const Key('sense-about-id')), findsNothing);
    expect(find.text(SenseAboutStrings.panelManaged), findsOneWidget);
  });

  testWidgets('licenses: a closable category with the public source, no window', (tester) async {
    final b = _FakeAbout();
    await _pump(tester, b);
    expect(find.text(SenseAboutStrings.licensesSummary), findsOneWidget);
    expect(find.byKey(const Key('sense-about-licenses-body')), findsNothing);
    await tester.tap(find.text(SenseAboutStrings.licenses));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const Key('sense-about-licenses-body')), findsOneWidget);
    expect(find.text('Taban sürüm: 1.4.3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-licenses-source')));
    await tester.tap(find.byKey(const Key('sense-licenses-text')));
    expect(b.opened, [kSenseSourceUrl, kSenseLicenseUrl]);
    await tester.tap(find.text(SenseAboutStrings.licenses));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sense-about-licenses-body')), findsNothing);
  });

  test('fingerprint and panel texts', () {
    expect(senseFingerprintShort(''), '');
    expect(senseFingerprintShort('ab'), 'AB');
    expect(senseFingerprintShort('3f2a 91c0'), '3F2A · 91C0');
    expect(senseAboutPanelValue(SenseHomeRole.controller, ''), SenseAboutStrings.panelSignedOut);
    expect(senseAboutPanelValue(SenseHomeRole.both, ''), SenseAboutStrings.panelManaged);
  });

  test('settings tab: a Host only gets About (H1, TK9 Risk H1)', () {
    expect(senseSettingsTabPage(about: false, incomingOnly: true), isA<SenseAboutPage>());
    expect(senseSettingsTabPage(about: true, incomingOnly: true), isA<SenseAboutPage>());
    expect(senseSettingsTabPage(about: true, incomingOnly: false), isA<SenseAboutPage>());
    expect(senseSettingsTabPage(about: false, incomingOnly: false), isA<SenseSettingsPage>());
  });

  group('golden images (a04)', () {
    testWidgets('about_current', (tester) async {
      await _pump(tester, _FakeAbout());
      await expectLater(find.byType(SenseAboutView), matchesGoldenFile(goldenPath('about_current')));
    }, skip: goldenSkip('about_current'), tags: const ['golden']);

    testWidgets('about_ready_licenses', (tester) async {
      await _pump(tester, _FakeAbout(update: {'state': 'available', 'target': 4, 'checked_at': 1000}),
          licenses: true);
      await expectLater(find.byType(SenseAboutView), matchesGoldenFile(goldenPath('about_ready_licenses')));
    }, skip: goldenSkip('about_ready_licenses'), tags: const ['golden']);
  });
}
