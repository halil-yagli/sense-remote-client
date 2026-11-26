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

  group('structured events (main_sense_diag_event)', () {
    final events = <String>[];
    setUp(() {
      events.clear();
      senseDiagEventTestSink = (c, k, fields) => events.add('$c/$k $fields');
    });
    tearDown(() => senseDiagEventTestSink = null);

    test('interface events go as ui events with their fields', () {
      senseUiButton('Bağlantıyı bitir', where: 'host.card');
      senseUiPopup('durum', open: true);
      expect(events, [
        'ui/button {name: Bağlantıyı bitir, where: host.card}',
        'ui/popup {name: durum, open: true}',
      ]);
    });

    test('a setting is ad / eski / yeni; a secret setting writes neither value', () {
      senseUiSetting('view_style', 'original', 'adaptive', where: 'session');
      senseUiSetting('permanent-password', 'a', 'b');
      expect(events[0], 'ui/setting {ad: view_style, yer: session, eski: original, yeni: adaptive}');
      expect(events[1], 'ui/setting {ad: permanent-password, eski: ***, yeni: ***}');
    });

    test('fields are JSON safe and masked; bad kinds are dropped', () {
      final f = senseDiagEventFields({
        'n': 3,
        'b': false,
        'x': null,
        'token': 'abc',
        'note': 'from ali@example.com',
        'o': const Size(2, 3),
      });
      expect(f['n'], 3);
      expect(f['b'], false);
      expect(f['x'], isNull);
      expect(f['token'], '***');
      expect(f['note'], 'from ***');
      expect(f['o'], isA<String>());
      expect(senseDiagEventKind('display'), 'display');
      expect(senseDiagEventKind('a b'), isNull);
      expect(senseDiagEventKind(''), isNull);
      senseUiEvent('bad kind!', {'a': 1});
      expect(events, isEmpty);
    });
  });
}
