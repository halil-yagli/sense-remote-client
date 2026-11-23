// Sense Remote: Controller sign-in (plan B3; YH C1): "Sense hesabınla gir",
// Google in the browser, pairing code, Vazgeç, failure, success; connecting
// by ID without signing in.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/controller/login/login_controller.dart';
import 'package:flutter_hbb/sense/screens/controller/login/login_page.dart';
import 'package:flutter_hbb/sense/strings/controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  group('controller', () {
    test('start → waiting with the pairing code; the browser opens once', () async {
      final fake = FakeLogin();
      final c = SenseLoginController(fake, interval: const Duration(hours: 1));
      await c.start();
      await pumpEventQueue();
      expect(c.stage, SenseLoginStage.waiting);
      expect(c.code, '731054');
      expect(c.url, 'https://panel.example/oidc');
      expect(fake.calls, ['start:google', 'open:https://panel.example/oidc']);
      c.dispose();
      expect(fake.calls.last, 'cancel', reason: 'leaving the page stops the attempt');
    });

    test('approved: auth body signs in', () async {
      final fake = FakeLogin()
        ..results = [
          jsonEncode({'state_msg': '', 'failed_msg': '', 'auth_body': {'access_token': 'x', 'type': 'access_token'}}),
        ];
      final c = SenseLoginController(fake, interval: const Duration(hours: 1));
      await c.start();
      await pumpEventQueue();
      expect(c.stage, SenseLoginStage.done);
      expect(fake.completed, isNotNull);
      c.dispose();
    });

    test('failure from the panel and no provider are shown', () async {
      final fake = FakeLogin()
        ..results = [jsonEncode({'state_msg': '', 'failed_msg': 'Login failed'})];
      final c = SenseLoginController(fake, interval: const Duration(hours: 1));
      await c.start();
      await pumpEventQueue();
      expect(c.stage, SenseLoginStage.failed);
      expect(c.error, SenseLoginError.failed);
      fake.op = null;
      await c.start();
      expect(c.error, SenseLoginError.noProvider);
      c.dispose();
    });

    test('Vazgeç cancels on the native side and returns to the start', () async {
      final fake = FakeLogin();
      final c = SenseLoginController(fake, interval: const Duration(hours: 1));
      await c.start();
      await pumpEventQueue();
      await c.cancel();
      expect(c.stage, SenseLoginStage.idle);
      expect(c.code, isEmpty);
      expect(fake.calls.last, 'cancel');
      await c.copyLink();
      expect(fake.calls.where((s) => s.startsWith('copy')), isEmpty, reason: 'no link after Vazgeç');
      c.dispose();
    });

    test('pairing code is shown 3 + 3', () {
      expect(SenseControllerStrings.pairingCode('731054'), '731 · 054');
    });
  });

  group('page', () {
    testWidgets('a05: title, lead, Google button, hints', (tester) async {
      final c = SenseLoginController(FakeLogin(), interval: const Duration(hours: 1));
      await tester.pumpWidget(app(page(SenseLoginPage(controller: c, onConnect: (_) {}))));
      expect(find.text('Google ile giriş yap'), findsOneWidget);
      expect(find.textContaining('Listede yalnız o kişinin panelde üyesi olduğu projeler görünür'), findsOneWidget);
      expect(find.text('Tarayıcıda açılır · eşleştirme kodu karşılaştırılır · iki adımlı doğrulama'), findsOneWidget);
      expect(find.textContaining('RustDesk'), findsNothing);
      await tester.tap(find.byKey(const Key('sense-login-google')));
      await _settle(tester);
      expect(find.text('731 · 054'), findsOneWidget);
      expect(find.text('Onay bekleniyor'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-login-copy')));
      await _settle(tester);
      expect(find.text('Giriş bağlantısı kopyalandı'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-login-cancel')));
      await _settle(tester);
      expect(find.text('Google ile giriş yap'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('without an account: connect by ID in place', (tester) async {
      final c = SenseLoginController(FakeLogin(), interval: const Duration(hours: 1));
      final ids = <String>[];
      await tester.pumpWidget(app(page(SenseLoginPage(controller: c, onConnect: ids.add))));
      expect(find.byKey(const Key('sense-id-box')), findsNothing);
      await tester.tap(find.byKey(const Key('sense-login-id')));
      await tester.pump();
      final field = find.descendant(of: find.byKey(const Key('sense-id-field')), matching: find.byType(TextField));
      await tester.enterText(field, '482913207');
      await tester.tap(find.byKey(const Key('sense-id-connect')));
      expect(ids, ['482913207']);
      c.dispose();
    });
  });
}
