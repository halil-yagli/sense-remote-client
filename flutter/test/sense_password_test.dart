// Sense Remote: "Kalıcı şifre" page (permanent password plan 2026-11-21, §4,
// package U13). Status JSON → text and buttons for every state and error
// code, the flow with a fake backend (mismatch, Kaydet → set, expiry), the
// password fields, and golden images.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/pages/sense_home_about.dart';
import 'package:flutter_hbb/desktop/pages/sense_home_host.dart';
import 'package:flutter_hbb/desktop/pages/sense_home_strings.dart';
import 'package:flutter_hbb/desktop/pages/sense_install_model.dart'
    show SenseLoginStatus;
import 'package:flutter_hbb/desktop/pages/sense_password_model.dart';
import 'package:flutter_hbb/desktop/pages/sense_password_page.dart';
import 'package:flutter_hbb/desktop/pages/sense_password_strings.dart';
import 'package:flutter_hbb/desktop/widgets/sense_version_chip.dart';
import 'package:flutter_test/flutter_test.dart';

const _now = 1000000;
const _url = 'https://remote.example/onay?f=deneme-akisi';

String _status(Map<String, Object?> json) => jsonEncode({
      'supported': true,
      'role': 'host',
      'perm_set': true,
      'changed_at': null,
      'stage': 'locked',
      'until': null,
      'user': null,
      ...json,
    });

SensePasswordStatus _s(Map<String, Object?> json) =>
    SensePasswordStatus.parse(_status(json));

class _Fake implements SensePasswordBackend {
  String statusJson = _status({});
  String beginAnswer = '{"ok":true}';
  List<String> logins = [
    jsonEncode({'state': 'waiting', 'url': _url, 'pairing_code': '482913'}),
    jsonEncode({'state': 'done', 'user': {'name': 'ayse@example.com'}}),
  ];
  String unlockAnswer =
      jsonEncode({'ok': true, 'until': _now + 300, 'user': 'Ayşe'});
  String checkAnswer = '';
  String setAnswer = '';
  final calls = <String>[];
  final setPasswords = <String>[];
  final opened = <String>[];
  final copied = <String>[];

  @override
  Future<String> status() async => statusJson;
  @override
  Future<String> begin() async {
    calls.add('begin');
    return beginAnswer;
  }

  @override
  Future<String> loginStatus() async =>
      logins.length > 1 ? logins.removeAt(0) : logins.first;
  @override
  Future<String> unlock() async {
    calls.add('unlock');
    return unlockAnswer;
  }

  @override
  Future<String> check(String password) async {
    calls.add('check');
    return checkAnswer;
  }

  @override
  Future<String> set(String password) async {
    calls.add('set');
    setPasswords.add(password);
    return setAnswer;
  }

  @override
  Future<void> cancel() async => calls.add('cancel');
  @override
  void openUrl(String url) => opened.add(url);
  @override
  Future<void> copy(String text) async => copied.add(text);
}

/// Controller with a hand-driven clock; the timer never fires by itself.
({SensePasswordController c, _Fake f, void Function(int) setNow}) _make(
    [_Fake? fake]) {
  var now = _now;
  final f = fake ?? _Fake();
  final c = SensePasswordController(f,
      interval: const Duration(days: 1), now: () => now);
  return (c: c, f: f, setNow: (v) => now = v);
}

/// Locked → verifying → unlocked.
Future<void> _unlock(SensePasswordController c) async {
  await c.load();
  await c.unlockPressed();
  await c.tick(); // waiting: code + QR
  await c.tick(); // done → unlock
}

Future<void> _loadFonts() async {
  final loader = FontLoader('Poppins');
  for (final w in ['ExtraLight', 'Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('assets/fonts/Poppins-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Future<void> _pump(WidgetTester tester, Widget child, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: Colors.black, body: child)));
  // No pumpAndSettle: a focused field blinks its cursor for ever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('status JSON', () {
    test('unreadable is "not supported", never a button', () {
      for (final raw in ['', 'null', '[]', '{', '{"supported":"yes"}']) {
        final s = SensePasswordStatus.parse(raw);
        expect(s.supported, isFalse, reason: raw);
        expect(sensePasswordInitialStage(s, _now),
            SensePasswordStage.unsupported);
        expect(sensePasswordActions(SensePasswordStage.unsupported, s), isEmpty);
        expect(sensePasswordHostLine(s), isNull);
      }
    });

    test('first stage of the page', () {
      SensePasswordStage st(Map<String, Object?> j) =>
          sensePasswordInitialStage(_s(j), _now);
      expect(st({'supported': false}), SensePasswordStage.unsupported);
      expect(st({'role': 'controller'}), SensePasswordStage.controller);
      expect(st({}), SensePasswordStage.locked);
      expect(st({'role': 'both'}), SensePasswordStage.locked);
      expect(st({'role': 'none'}), SensePasswordStage.locked);
      expect(st({'stage': 'verifying'}), SensePasswordStage.verifying);
      expect(st({'stage': 'unlocked', 'until': _now + 10}),
          SensePasswordStage.unlocked);
      expect(st({'stage': 'unlocked', 'until': _now}), SensePasswordStage.locked);
      expect(st({'stage': 'unlocked'}), SensePasswordStage.locked);
    });

    test('About row and Host line', () {
      final d = DateTime(2026, 11, 21, 14, 5);
      expect(sensePasswordSummary(_s({}), d), 'Ayarlı · 21.11.2026 14:05');
      expect(sensePasswordSummary(_s({})), 'Ayarlı');
      expect(sensePasswordSummary(_s({'perm_set': false})), 'Ayarlı değil');
      expect(sensePasswordSummary(_s({'perm_set': null})), 'Kilitli');
      expect(sensePasswordSummary(_s({'role': 'controller'})),
          'Bu bilgisayarda gerekmez');
      expect(sensePasswordSummary(_s({'supported': false})),
          'Bu sürümde henüz açık değil');
      expect(sensePasswordHostLine(_s({})), 'Kalıcı şifre: ayarlı');
      expect(sensePasswordHostLine(_s({'perm_set': false})), 'Kalıcı şifre: yok');
      expect(sensePasswordHostLine(_s({'perm_set': null})), 'Kalıcı şifre');
      expect(sensePasswordHostLine(_s({'role': 'controller'})), isNull);
      expect(sensePasswordHostLine(_s({'supported': false})), isNull);
    });

    test('locked text (§4)', () {
      expect(sensePasswordLockedText(_s({}), DateTime(2026, 11, 21, 9, 3)),
          'Kalıcı şifre ayarlı · son değişiklik 21.11.2026 09:03. '
          'Değiştirmek için Sense hesabınla doğrula.');
      expect(sensePasswordLockedText(_s({'perm_set': false})),
          'Kalıcı şifre yok. Başında kimse yokken bağlanmak için kalıcı şifre belirle.');
      expect(sensePasswordLockedText(_s({'perm_set': null})),
          contains('Sense hesabınla doğrula'));
    });

    test('buttons: Host QR first, Host + Controller browser first', () {
      final host = _s({}), both = _s({'role': 'both'});
      expect(sensePasswordActions(SensePasswordStage.locked, host),
          [SensePasswordAction.unlock]);
      expect(sensePasswordActions(SensePasswordStage.expired, host),
          [SensePasswordAction.unlock]);
      expect(sensePasswordActions(SensePasswordStage.verifying, host), [
        SensePasswordAction.copyLink,
        SensePasswordAction.openBrowser,
        SensePasswordAction.cancel
      ]);
      expect(sensePasswordActions(SensePasswordStage.verifying, both), [
        SensePasswordAction.openBrowser,
        SensePasswordAction.copyLink,
        SensePasswordAction.cancel
      ]);
      expect(
          sensePasswordActions(SensePasswordStage.verifying, host, hasUrl: false),
          [SensePasswordAction.cancel]);
      expect(sensePasswordActions(SensePasswordStage.unlocked, host),
          [SensePasswordAction.save, SensePasswordAction.cancel]);
      expect(sensePasswordActions(SensePasswordStage.done, host),
          [SensePasswordAction.ok]);
      for (final st in [
        SensePasswordStage.loading,
        SensePasswordStage.controller,
        SensePasswordStage.unsupported
      ]) {
        expect(sensePasswordActions(st, host), isEmpty);
      }
    });

    test('only http(s) links with a host become a QR or open', () {
      expect(sensePasswordSafeUrl(_url), _url);
      expect(sensePasswordSafeUrl('javascript:alert(1)'), isNull);
      expect(sensePasswordSafeUrl('file:///etc/passwd'), isNull);
      expect(sensePasswordSafeUrl(''), isNull);
    });
  });

  group('texts', () {
    const codes = {
      // begin
      'not_incoming': 'Bu bilgisayar yalnız bağlanır; kalıcı şifre gerekmez.',
      'unsupported': 'Bu özellik bu sürümde henüz açık değil.',
      'busy': 'Başka bir işlem sürüyor. Biraz sonra yeniden dene.',
      'rate_limited': 'Çok fazla deneme. 1 saat içinde yeniden dene.',
      'ipc_failed': 'Sense Remote servisine ulaşılamadı. Biraz sonra yeniden dene.',
      // unlock (PasswordGrantError + network + panel_outdated)
      'token_invalid': 'Giriş geçersiz, yeniden doğrula.',
      'password_scope': 'Giriş geçersiz, yeniden doğrula.',
      'device_mismatch': 'Bu giriş bu bilgisayar için değil, yeniden doğrula.',
      'device_not_eligible': 'Bu bilgisayar panelde etkin değil.',
      'bad_request_signature': 'Doğrulama isteği kabul edilmedi, yeniden doğrula.',
      'request_expired': 'Doğrulamanın süresi doldu, yeniden doğrula.',
      'replayed': 'Giriş geçersiz, yeniden doğrula.',
      'signing_unavailable': 'Panel şu an izin veremiyor. Biraz sonra yeniden dene.',
      'validation': 'Doğrulama isteği kabul edilmedi, yeniden doğrula.',
      'network': 'Panele ulaşılamadı. Ağ bağlantısını denetleyip yeniden dene.',
      'panel_outdated': 'Panel bu özelliği henüz desteklemiyor.',
      // set
      'no_pending': 'Doğrulamanın süresi doldu, yeniden doğrula.',
      'grant_invalid:expired': 'İzin doğrulanamadı, yeniden doğrula.',
      'grant_invalid:bad_signature': 'İzin doğrulanamadı, yeniden doğrula.',
      'nonce_mismatch': 'İzin doğrulanamadı, yeniden doğrula.',
      'weak_password:length': 'Şifre 12–64 karakter olmalı.',
      'weak_password:charset':
          'Yalnız İngilizce harf, rakam ve işaret; boşluk ve Türkçe karakter olmaz.',
      'weak_password:repeated': 'Tek karakter tekrarı ya da 1234… gibi dizi olmaz.',
      'weak_password:contains_id': 'Şifre bilgisayarın kimliğini içermemeli.',
      'weak_password:common': 'Bu şifre çok yaygın; başka bir şifre seç.',
      'weak_password:new_rule': 'Bu şifre kurala uymuyor; başka bir şifre seç.',
      'write_failed': 'Şifre kaydedilemedi. Yeniden dene.',
      // sign-in and the page itself
      'login_timeout': 'Onay zamanında gelmedi. Yeniden doğrula.',
      'login_failed': 'Giriş tamamlanamadı. Yeniden dene.',
      'mismatch': 'İki şifre aynı değil.',
      'something_new': 'İşlem tamamlanamadı. Yeniden dene.',
    };

    test('every error code has its text, no internals', () {
      codes.forEach((code, text) {
        expect(sensePasswordErrorText(code), text, reason: code);
      });
    });

    test('which set answers lock the page again', () {
      for (final c in [
        'unsupported',
        'not_incoming',
        'no_pending',
        'grant_invalid:expired',
        'nonce_mismatch'
      ]) {
        expect(sensePasswordSetRelocks(c), isTrue, reason: c);
      }
      for (final c in [
        'weak_password:length',
        'write_failed',
        'busy',
        'ipc_failed'
      ]) {
        expect(sensePasswordSetRelocks(c), isFalse, reason: c);
      }
    });

    test('Turkish and English have the same keys; no "RustDesk"', () {
      expect(kSensePasswordTr.keys.toSet(), kSensePasswordEn.keys.toSet());
      for (final t in [...kSensePasswordTr.values, ...kSensePasswordEn.values]) {
        expect(t.toLowerCase(), isNot(contains('rustdesk')));
      }
    });

    test('countdown and date', () {
      expect(senseCountdown(300), '5:00');
      expect(senseCountdown(299), '4:59');
      expect(senseCountdown(9), '0:09');
      expect(senseCountdown(-3), '0:00');
      expect(senseShortDate(DateTime(2026, 1, 2, 3, 4)), '02.01.2026 03:04');
    });
  });

  group('flow (fake backend)', () {
    test('locked → verifying → unlocked → Kaydet → done', () async {
      final m = _make();
      addTearDown(m.c.dispose);
      await m.c.load();
      expect(m.c.stage, SensePasswordStage.locked);
      await m.c.unlockPressed();
      expect(m.c.stage, SensePasswordStage.verifying);
      await m.c.tick();
      expect(m.c.login.pairingCode, '482913');
      expect(m.c.login.url, _url);
      await m.c.tick();
      expect(m.c.stage, SensePasswordStage.unlocked);
      expect(m.c.user, 'Ayşe');
      expect(m.c.remaining, 300);

      m.c.password.text = 'deneme-Sifre-42';
      m.c.repeat.text = 'deneme-Sifre-42';
      await m.c.save();
      expect(m.f.calls, ['begin', 'unlock', 'check', 'set']);
      expect(m.f.setPasswords, ['deneme-Sifre-42']);
      expect(m.c.stage, SensePasswordStage.done);
      expect(m.c.password.text, isEmpty);
      expect(m.c.repeat.text, isEmpty);

      await m.c.okPressed();
      expect(m.c.stage, SensePasswordStage.locked);
    });

    test('two different passwords: mismatch, nothing sent, fields cleared',
        () async {
      final m = _make();
      addTearDown(m.c.dispose);
      await _unlock(m.c);
      m.c.password.text = 'deneme-Sifre-42';
      m.c.repeat.text = 'deneme-Sifre-43';
      await m.c.save();
      expect(m.c.message, 'İki şifre aynı değil.');
      expect(m.f.calls, isNot(contains('check')));
      expect(m.f.calls, isNot(contains('set')));
      expect(m.c.stage, SensePasswordStage.unlocked);
      expect(m.c.password.text, isEmpty);
    });

    test('rule hint stops before set; the window stays open', () async {
      final m = _make();
      addTearDown(m.c.dispose);
      m.f.checkAnswer = 'length';
      await _unlock(m.c);
      m.c.password.text = 'kisa';
      m.c.repeat.text = 'kisa';
      await m.c.save();
      expect(m.c.message, 'Şifre 12–64 karakter olmalı.');
      expect(m.f.calls, isNot(contains('set')));
      expect(m.c.stage, SensePasswordStage.unlocked);
    });

    test('every set answer: text, and locked again when the grant is gone',
        () async {
      for (final code in [
        'unsupported',
        'not_incoming',
        'no_pending',
        'grant_invalid:expired',
        'nonce_mismatch',
        'weak_password:common',
        'write_failed',
        'busy',
        'ipc_failed',
      ]) {
        final m = _make();
        m.f.setAnswer = code;
        await _unlock(m.c);
        m.c.password.text = 'deneme-Sifre-42';
        m.c.repeat.text = 'deneme-Sifre-42';
        await m.c.save();
        expect(m.c.message, sensePasswordErrorText(code), reason: code);
        expect(
            m.c.stage,
            sensePasswordSetRelocks(code)
                ? SensePasswordStage.locked
                : SensePasswordStage.unlocked,
            reason: code);
        expect(m.c.password.text, isEmpty, reason: code);
        m.c.dispose();
      }
    });

    test('every begin error: text, no sign-in', () async {
      for (final code in [
        'unsupported',
        'busy',
        'rate_limited',
        'ipc_failed',
        'not_incoming'
      ]) {
        final m = _make();
        m.f.beginAnswer = jsonEncode({'ok': false, 'error': code});
        await m.c.load();
        await m.c.unlockPressed();
        expect(m.c.message,
            code == 'not_incoming' ? isNull : sensePasswordErrorText(code),
            reason: code);
        expect(
            m.c.stage,
            code == 'not_incoming'
                ? SensePasswordStage.controller
                : SensePasswordStage.locked,
            reason: code);
        m.c.dispose();
      }
    });

    test('every unlock error: locked with its text', () async {
      for (final code in [
        'token_invalid',
        'password_scope',
        'device_mismatch',
        'device_not_eligible',
        'bad_request_signature',
        'request_expired',
        'replayed',
        'rate_limited',
        'signing_unavailable',
        'validation',
        'network',
        'panel_outdated',
      ]) {
        final m = _make();
        m.f.unlockAnswer = jsonEncode({'ok': false, 'error': code});
        await _unlock(m.c);
        expect(m.c.stage, SensePasswordStage.locked, reason: code);
        expect(m.c.message, sensePasswordErrorText(code), reason: code);
        m.c.dispose();
      }
    });

    test('sign-in timeout: locked, sign-in given back', () async {
      final m = _make();
      addTearDown(m.c.dispose);
      m.f.logins = [jsonEncode({'state': 'failed', 'error': 'timeout'})];
      await m.c.load();
      await m.c.unlockPressed();
      await m.c.tick();
      expect(m.c.stage, SensePasswordStage.locked);
      expect(m.c.message, 'Onay zamanında gelmedi. Yeniden doğrula.');
      expect(m.f.calls.last, 'cancel');
    });

    test('time is up: expired, fields cleared, grant given back', () async {
      final m = _make();
      addTearDown(m.c.dispose);
      await _unlock(m.c);
      m.c.password.text = 'deneme-Sifre-42';
      m.setNow(_now + 299);
      await m.c.tick();
      expect(m.c.stage, SensePasswordStage.unlocked);
      expect(senseCountdown(m.c.remaining), '0:01');
      m.setNow(_now + 300);
      await m.c.tick();
      expect(m.c.stage, SensePasswordStage.expired);
      expect(m.c.password.text, isEmpty);
      expect(m.f.calls.last, 'cancel');
      await m.c.save();
      expect(m.f.calls, isNot(contains('set')));
    });

    test('Vazgeç and closing the page give the grant back', () async {
      final m = _make();
      await _unlock(m.c);
      await m.c.cancelPressed();
      expect(m.c.stage, SensePasswordStage.locked);
      expect(m.f.calls.last, 'cancel');

      final n = _make();
      await _unlock(n.c);
      n.c.dispose();
      expect(n.f.calls.last, 'cancel');
      m.c.dispose();
    });

    test('copy and open use the panel link only', () async {
      final m = _make();
      addTearDown(m.c.dispose);
      await m.c.load();
      await m.c.unlockPressed();
      await m.c.tick();
      await m.c.copyLink();
      m.c.openBrowser();
      expect(m.f.copied, [_url]);
      expect(m.f.opened, [_url]);
      expect(m.c.message, 'Bağlantı kopyalandı.');
    });
  });

  group('page', () {
    testWidgets('fields: hidden, no selection; Kaydet calls set',
        (tester) async {
      final m = _make();
      await tester.runAsync(() => _unlock(m.c));
      await _pump(
          tester,
          SingleChildScrollView(
              child: SizedBox(
                  width: 440, child: SensePasswordPanel(controller: m.c))),
          const Size(600, 700));
      for (final key in ['sense-pw-new', 'sense-pw-repeat']) {
        final field = tester.widget<TextField>(find.byKey(Key(key)));
        expect(field.obscureText, isTrue, reason: key);
        expect(field.enableInteractiveSelection, isFalse, reason: key);
        expect(field.enableSuggestions, isFalse, reason: key);
        expect(field.autocorrect, isFalse, reason: key);
      }
      expect(find.text('Doğrulandı: Ayşe · 5:00 içinde kilitlenir'),
          findsOneWidget);
      await tester.enterText(find.byKey(const Key('sense-pw-new')), 'deneme-Sifre-42');
      await tester.enterText(
          find.byKey(const Key('sense-pw-repeat')), 'deneme-Sifre-42');
      await tester.tap(find.byKey(const Key('sense-pw-save')));
      await tester.pump();
      await tester.pump();
      expect(m.f.setPasswords, ['deneme-Sifre-42']);
      expect(find.textContaining('Kalıcı şifre değiştirildi.'), findsOneWidget);
      expect(find.byKey(const Key('sense-pw-ok')), findsOneWidget);
      m.c.dispose();
    });
  });

  group('golden images (Windows + macOS)', () {
    // Rendered on the Linux CI runner (`PR kontrolu`) with the bundled Poppins.
    setUpAll(_loadFonts);

    SensePasswordController panel(SensePasswordStage stage,
        {Map<String, Object?> status = const {},
        String? message,
        bool waiting = true}) {
      final c = SensePasswordController(_Fake(),
          interval: const Duration(days: 1), now: () => _now);
      c.status = _s(status);
      c.stage = stage;
      c.message = message;
      if (stage == SensePasswordStage.verifying && waiting) {
        c.login = const SenseLoginStatus('waiting',
            url: _url, pairingCode: '482913');
      }
      if (stage == SensePasswordStage.unlocked) {
        c.until = _now + 263;
        c.user = 'Ayşe Demir';
      }
      return c;
    }

    Widget box(SensePasswordController c, {double width = 440}) => Container(
          width: width,
          margin: const EdgeInsets.all(10),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: Colors.black,
              border: Border.all(color: const Color(0xFF33333D)),
              borderRadius: BorderRadius.circular(14)),
          child: SensePasswordPanel(controller: c, onClose: () {}),
        );

    testWidgets('every state', (tester) async {
      final changed = DateTime(2026, 11, 21, 14, 5).millisecondsSinceEpoch ~/ 1000;
      final cs = [
        panel(SensePasswordStage.locked, status: {'changed_at': changed}),
        panel(SensePasswordStage.locked, status: {'perm_set': false}),
        panel(SensePasswordStage.verifying),
        panel(SensePasswordStage.verifying, status: {'role': 'both'}),
        panel(SensePasswordStage.unlocked, message: 'İki şifre aynı değil.'),
        panel(SensePasswordStage.done),
        panel(SensePasswordStage.expired),
        panel(SensePasswordStage.locked,
            status: {'perm_set': false},
            message: sensePasswordErrorText('panel_outdated')),
        panel(SensePasswordStage.controller, status: {'role': 'controller'}),
        panel(SensePasswordStage.unsupported, status: {'supported': false}),
      ];
      await _pump(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: const Key('golden'),
              child: Container(
                color: Colors.black,
                width: 1440,
                padding: const EdgeInsets.all(10),
                child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.start,
                    children: [for (final c in cs) box(c)]),
              ),
            ),
          ),
          const Size(1440, 1800));
      expect(tester.takeException(), isNull);
      await expectLater(find.byKey(const Key('golden')),
          matchesGoldenFile('goldens/sense_password_states.png'));
      for (final c in cs) {
        c.dispose();
      }
    });

    Widget host() => SizedBox(
          width: 280,
          child: SenseHostHomeView(
            name: 'Galeri kioskı',
            location: 'Galeri 1',
            deviceId: '',
            state: SenseHostState.ready,
            versionChip: SenseVersionChip(version: 3, onTap: () {}),
            passwordLine: SensePasswordHostLine(
                text: sensePasswordHostLine(_s({'perm_set': false}))!,
                onTap: () {}),
          ),
        );

    testWidgets('Host home, Windows', (tester) async {
      await _pump(
          tester,
          Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(key: const Key('golden'), child: host())),
          const Size(280, 460));
      expect(find.text('Kalıcı şifre: yok'), findsOneWidget);
      await expectLater(find.byKey(const Key('golden')),
          matchesGoldenFile('goldens/sense_password_host_windows.png'));
    });

    testWidgets('Host, macOS: home line and the narrow verifying page',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final c = panel(SensePasswordStage.verifying);
      try {
        await _pump(
            tester,
            Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                    key: const Key('golden'),
                    child: Container(
                      color: Colors.black,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [host(), box(c, width: 256)],
                      ),
                    ))),
            const Size(560, 640));
        expect(tester.takeException(), isNull);
        await expectLater(find.byKey(const Key('golden')),
            matchesGoldenFile('goldens/sense_password_host_mac.png'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        c.dispose();
      }
    });

    testWidgets('About › Güvenlik', (tester) async {
      await _pump(
          tester,
          RepaintBoundary(
            key: const Key('golden'),
            child: SenseAboutView(
              version: 3,
              role: SenseHomeRole.host,
              account: '',
              year: 2026,
              onOpenUrl: (_) {},
              passwordSection: SensePasswordAboutView(
                  summary: sensePasswordSummary(
                      _s({}), DateTime(2026, 11, 21, 14, 5)),
                  onOpen: () {}),
            ),
          ),
          const Size(600, 600));
      expect(find.text('Ayarlı · 21.11.2026 14:05'), findsOneWidget);
      await expectLater(find.byKey(const Key('golden')),
          matchesGoldenFile('goldens/sense_password_about.png'));
    });
    // Sense Remote: goldens are rendered on the Linux runner; text rasterises
    // differently on macOS/Windows, so compare them only on Linux.
  }, skip: !Platform.isLinux);
}
