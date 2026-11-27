// Sense Remote (Sürüm 12, #162): the Sense dialog pattern that replaces the stock boxes —
// levels from msgbox types, keys, buttons, choices, the notice, and golden images.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/sense/components/sense_dialog.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/strings/connect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const String _goldenDir = 'test/goldens/connect_cards';
String _golden(String name) => '../../goldens/connect_cards/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_goldenDir/$name.png').existsSync();

Widget _centred(Widget w) => Center(child: w);

void main() {
  group('msgbox type → level (ST 0: icon colours from the tokens)', () {
    const cases = <(String, SenseLevel?)>[
      ('error', SenseLevel.hot),
      ('custom-nook-nocancel-hasclose-error', SenseLevel.hot),
      ('re-input-password', SenseLevel.hot),
      ('success', SenseLevel.ok),
      ('wait-uac', SenseLevel.warn),
      ('on-uac', SenseLevel.warn),
      ('on-foreground-elevated', SenseLevel.warn),
      ('wait-remote-accept-nook', SenseLevel.warn),
      ('input-password', null),
      ('info', null),
    ];
    for (final (type, level) in cases) {
      test('$type → $level', () => expect(senseMsgBoxLevel(type), level));
    }
  });

  group('SenseDialog', () {
    testWidgets('title, live line, box, fields and buttons; Esc cancels, Enter submits', (tester) async {
      final calls = <String>[];
      await pumpCard(
          tester,
          _centred(SenseDialog(
            title: 'Yönetici onayı bekleniyor',
            live: 'Uzak masaüstü',
            level: SenseLevel.warn,
            headline: 'Yönetici onayı bekleniyor',
            message: 'Sahadaki kişi onaylayana kadar bekle.',
            onCancel: () => calls.add('cancel'),
            onSubmit: () => calls.add('submit'),
            actions: [
              SenseDialogAction('Bekle', () => calls.add('wait')),
              SenseDialogAction('Yetki yükselt', () => calls.add('elevate'),
                  kind: SenseButtonKind.primary, key: const Key('elevate')),
            ],
          )));
      expect(find.text('Uzak masaüstü'), findsOneWidget);
      expect(find.byType(SenseStatusBox), findsOneWidget);
      await tester.tap(find.byKey(const Key('elevate')));
      expect(calls, ['elevate']);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, ['elevate', 'cancel', 'submit']);
      await tester.tap(find.byKey(const Key('sense-popup-close')));
      expect(calls.last, 'cancel');
    });

    testWidgets('choices: the tapped row is chosen', (tester) async {
      var chosen = 0;
      await pumpCard(
          tester,
          StatefulBuilder(
              builder: (context, setState) => _centred(SizedBox(
                    width: 320,
                    child: SenseDialogChoices(
                        labels: const ['Console', 'halil (RDP)'],
                        selected: chosen,
                        onSelected: (i) => setState(() => chosen = i)),
                  ))));
      await tester.tap(find.text('halil (RDP)'));
      await tester.pump();
      expect(chosen, 1);
    });

    testWidgets('check row toggles', (tester) async {
      var v = false;
      await pumpCard(
          tester,
          StatefulBuilder(
              builder: (context, setState) => _centred(SenseDialogCheck(
                  label: SenseConnectStrings.closeTabsAskAgain,
                  value: v,
                  onChanged: (x) => setState(() => v = x)))));
      await tester.tap(find.text(SenseConnectStrings.closeTabsAskAgain));
      await tester.pump();
      expect(v, isTrue);
    });

    testWidgets('golden: UAC box (ST 6)', (tester) async {
      await pumpCard(
          tester,
          _centred(SenseDialog(
            title: SenseConnectStrings.uacTitle,
            level: SenseLevel.warn,
            headline: SenseConnectStrings.uacTitle,
            message: '${SenseConnectStrings.uacBody} ${SenseConnectStrings.elevationTip}',
            animateIn: false,
            onCancel: () {},
            actions: [
              SenseDialogAction(SenseConnectStrings.wait, () {}),
              SenseDialogAction(SenseConnectStrings.requestElevation, () {}, kind: SenseButtonKind.primary),
            ],
          )));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('dialog_uac')));
    }, skip: _skip('dialog_uac'), tags: ['golden']);

    testWidgets('golden: close all tabs (ST 14)', (tester) async {
      await pumpCard(
          tester,
          _centred(SenseDialog(
            title: SenseConnectStrings.closeTabsTitle,
            level: SenseLevel.warn,
            headline: SenseConnectStrings.closeTabsTitle,
            message: SenseConnectStrings.closeTabsBody(3),
            animateIn: false,
            onCancel: () {},
            children: [
              SenseDialogCheck(label: SenseConnectStrings.closeTabsAskAgain, value: true, onChanged: (_) {}),
            ],
            actions: [
              SenseDialogAction(SenseCommonStrings.cancel, () {}),
              SenseDialogAction(SenseConnectStrings.closeAll, () {}, kind: SenseButtonKind.danger),
            ],
          )));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('dialog_close_tabs')));
    }, skip: _skip('dialog_close_tabs'), tags: ['golden']);

    testWidgets('golden: Windows session choice (ST 18)', (tester) async {
      await pumpCard(
          tester,
          _centred(SenseDialog(
            title: SenseConnectStrings.sessionsTitle,
            message: SenseConnectStrings.sessionsBody,
            animateIn: false,
            children: [
              SenseDialogChoices(labels: const ['Konsol · sergi', 'Uzak oturum · teknik'], selected: 0, onSelected: (_) {}),
            ],
            actions: [
              SenseDialogAction(SenseConnectStrings.connect, () {}, kind: SenseButtonKind.primary),
            ],
          )));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('dialog_sessions')));
    }, skip: _skip('dialog_sessions'), tags: ['golden']);
  });

  group('notice (#159)', () {
    testWidgets('"Bu bilgisayara kaydedildi · Klasörü aç" runs the action once and goes', (tester) async {
      var opened = 0;
      await pumpCard(tester, const SizedBox());
      final overlay = tester.state<OverlayState>(find.byType(Overlay).first);
      senseShowNotice(overlay, SenseConnectStrings.screenshotSaved,
          level: SenseLevel.ok, actionLabel: SenseConnectStrings.openFolder, onAction: () => opened++);
      await tester.pump();
      expect(find.text(SenseConnectStrings.screenshotSaved), findsOneWidget);
      expect(tester.widget<Text>(find.text(SenseConnectStrings.screenshotSaved)).style?.color, SenseColors.ok);
      await tester.tap(find.byKey(const Key('sense-notice-action')));
      await tester.pump();
      expect(opened, 1);
      expect(find.byKey(const Key('sense-notice')), findsNothing);
      await tester.pump(SenseNotice.hold);
    });

    testWidgets('a new notice replaces the old; it goes by itself', (tester) async {
      await pumpCard(tester, const SizedBox());
      final overlay = tester.state<OverlayState>(find.byType(Overlay).first);
      senseShowNotice(overlay, 'bir');
      senseShowNotice(overlay, 'iki', level: SenseLevel.hot);
      await tester.pump();
      expect(find.text('bir'), findsNothing);
      expect(find.text('iki'), findsOneWidget);
      await tester.pump(SenseNotice.holdError);
      await tester.pump();
      expect(find.byKey(const Key('sense-notice')), findsNothing);
    });

    testWidgets('golden: screenshot notice', (tester) async {
      await pumpCard(
          tester,
          const Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.only(top: SenseNotice.top),
              child: SenseNotice(
                  text: SenseConnectStrings.screenshotSaved,
                  level: SenseLevel.ok,
                  actionLabel: SenseConnectStrings.openFolder),
            ),
          ));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('notice_screenshot')));
    }, skip: _skip('notice_screenshot'), tags: ['golden']);
  });

  group('pill for core messages (ST 11)', () {
    testWidgets('BotToast text becomes the Sense pill; errors the red notice', (tester) async {
      await pumpCard(tester, const SizedBox());
      final overlay = tester.state<OverlayState>(find.byType(Overlay).first);
      senseShowOverlayToast(overlay, 'Panoya kopyalandı');
      await tester.pump();
      expect(find.byType(SenseToast), findsOneWidget);
      await tester.pump(SenseToastController.holdDuration);
      await tester.pump();
      expect(find.byType(SenseToast), findsNothing);
      senseShowOverlayToast(overlay, 'Engellendi', error: true);
      await tester.pump();
      expect(find.byKey(const Key('sense-notice')), findsOneWidget);
      await tester.pump(SenseNotice.holdError);
    });
  });
}
