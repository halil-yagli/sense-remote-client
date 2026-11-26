import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/diag_log.dart';
import 'package:flutter_hbb/sense/diag_text.dart';
import 'package:flutter_test/flutter_test.dart';

// Sense Remote (karar #103): interface events in the connection record. Names only, never
// content; secret looking fields and e-mail addresses masked.
void main() {
  group('line format', () {
    test('kind and fields on one line with the [ui] prefix', () {
      expect(senseUiLine('button', {'name': 'Bağlantıyı bitir', 'where': 'host.card'}),
          '[ui] button name="Bağlantıyı bitir" where=host.card');
      expect(senseUiLine('cm.ended'), '[ui] cm.ended');
      expect(senseUiLine('x', {'a': null, 'b': ''}), '[ui] x a=- b=""');
    });

    test('new lines, quotes and long values cannot break the line', () {
      final line = senseUiLine('popup', {'name': 'a\nb"c', 'long': 'x' * 500});
      expect(line.contains('\n'), isFalse);
      expect(line, contains('name="a b\'c"'));
      expect(line.length, lessThan(200));
    });

    test('secret fields and e-mail addresses are masked', () {
      final line = senseUiLine('setting', {
        'password': 'hunter2',
        'apiKey': 'abc',
        'user_email': 'a@b.com',
        'note': 'from ali@example.com today',
        'keyboard': 'on',
      });
      expect(line, isNot(contains('hunter2')));
      expect(line, isNot(contains('abc')));
      expect(line, isNot(contains('a@b.com')));
      expect(line, isNot(contains('ali@example.com')));
      expect(line, contains('password=***'));
      expect(line, contains('keyboard=on'), reason: '"key" alone is not a secret');
    });

    test('PIN, 2FA, salt, auth and cookie / session token names are masked, ids are not', () {
      for (final key in [
        'pin', 'user_pin', 'devicePin', '2fa', 'totp_2fa', 'otp', 'salt', 'pwSalt',
        'auth', 'auth_code', 'basicAuth', 'secret', 'cookie', 'sessionCookie', 'session_token',
        'sessionToken', 'sessionKey', 'session-secret',
      ]) {
        expect(senseUiSecretKey(key), isTrue, reason: key);
        expect(senseUiLine('x', {key: 'v4lue'}), '[ui] x $key=***', reason: key);
      }
      for (final key in [
        'sessionId', 'session_id', 'session', 'typing', 'mapping', 'author', 'pinned', 'spinner',
        'authority', 'saltwater', 'keyboard', 'name', 'where',
      ]) {
        expect(senseUiSecretKey(key), isFalse, reason: key);
      }
      expect(senseUiLine('x', {'sessionId': 'abc'}), '[ui] x sessionId=abc');
    });

    test('a setting change is old -> new, a secret setting writes neither', () {
      expect(senseUiSettingLine('view_style', 'original', 'adaptive', where: 'session'),
          '[ui] setting key=view_style where=session from=original to=adaptive');
      expect(senseUiSettingLine('permanent-password', 'a', 'b'),
          '[ui] setting key=permanent-password from=*** to=***');
    });

    test('rectangles and sizes in whole pixels', () {
      expect(senseUiRect(1200.4, -8, 660, 1020.6), '1200,-8 660x1021');
      expect(senseUiSize(644, 1012), '644x1012');
    });
  });

  group('events go to the log', () {
    final lines = <String>[];
    setUp(() {
      lines.clear();
      senseDiagTestSink = (level, line) => lines.add('$level $line');
    });
    tearDown(() => senseDiagTestSink = null);

    test('screen, list, popup, button, setting, ghost, display', () {
      senseUiScreen('controller.computers');
      senseUiList('displays', open: true);
      senseUiPopup('host.card', open: false);
      senseUiButton('Ara', where: 'session.chat');
      senseUiSetting('image_quality', 'balanced', 'best');
      senseUiGhost(true, reason: 'session_start');
      senseUiDisplay(from: 1, to: 'all');
      expect(lines, [
        'info [ui] screen name=controller.computers',
        'info [ui] list name=displays open=true',
        'info [ui] popup name=host.card open=false',
        'info [ui] button name=Ara where=session.chat',
        'info [ui] setting key=image_quality from=balanced to=best',
        'info [ui] ghost on=true reason=session_start',
        'info [ui] display from=1 to=all',
      ]);
    });

    testWidgets('the navigator observer records pushes and pops', (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        navigatorObservers: [SenseDiagNavigatorObserver()],
        home: const SizedBox(),
      ));
      key.currentState!.push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'settings'), builder: (_) => const SizedBox()));
      await tester.pumpAndSettle();
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(lines, contains('info [ui] route op=push name=settings from=/'));
      expect(lines, contains('info [ui] route op=pop name=settings to=/'));
    });
  });
}
