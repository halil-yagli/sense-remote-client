// Sense Remote (A2b): Sense drop-down list (#43), in-place second step and the
// toast (T7). No OS / Material menu, no confirm window, no "success" window.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/components/components_b.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'support.dart';

const _options = [
  SenseSelectOption(value: 'auto', label: 'Otomatik', description: 'önerilen'),
  SenseSelectOption(value: 'h264', label: 'H.264'),
  SenseSelectOption(value: 'off', label: 'Kapalı', danger: true),
];

class _SelectHarness extends StatefulWidget {
  const _SelectHarness({this.enabled = true, this.onChanged});

  final bool enabled;
  final ValueChanged<String>? onChanged;

  @override
  State<_SelectHarness> createState() => _SelectHarnessState();
}

class _SelectHarnessState extends State<_SelectHarness> {
  String value = 'auto';

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(
        width: 300,
        child: SenseSelect<String>(
          label: 'Kodek',
          header: 'Görüntü kodeği',
          options: _options,
          value: value,
          enabled: widget.enabled,
          onChanged: (v) {
            setState(() => value = v);
            widget.onChanged?.call(v);
          },
        ),
      ),
      const SizedBox(key: Key('outside'), width: 300, height: 300),
    ]);
  }
}

void main() {
  group('SenseSelect (#43)', () {
    testWidgets('opens a Sense list under the button, picks, closes', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(app(Align(
          alignment: Alignment.topLeft, child: _SelectHarness(onChanged: picked.add))));
      expect(find.text('Otomatik'), findsOneWidget);
      expect(find.byKey(const Key('sense-select-menu')), findsNothing);

      await tester.tap(find.byKey(const Key('sense-select-button')));
      await tester.pump();
      expect(find.byKey(const Key('sense-select-menu')), findsOneWidget);
      expect(find.text('GÖRÜNTÜ KODEĞİ'), findsOneWidget, reason: 'Turkish capitals');
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      final button = tester.getRect(find.byKey(const Key('sense-select-button')));
      final menu = tester.getRect(find.byKey(const Key('sense-select-menu')));
      expect(menu.top, closeTo(button.bottom + SenseSelect.menuGap, 0.5));
      expect(menu.left, button.left);
      expect(menu.width, greaterThanOrEqualTo(button.width));

      await tester.tap(find.text('H.264'));
      await tester.pump();
      expect(picked, ['h264']);
      expect(find.byKey(const Key('sense-select-menu')), findsNothing);
      expect(find.text('H.264'), findsOneWidget);
    });

    testWidgets('a tap outside and Esc close the list without choosing', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(app(Align(
          alignment: Alignment.topLeft, child: _SelectHarness(onChanged: picked.add))));
      await tester.tap(find.byKey(const Key('sense-select-button')));
      await tester.pump();
      await tester.tapAt(tester.getCenter(find.byKey(const Key('outside'))));
      await tester.pump();
      expect(find.byKey(const Key('sense-select-menu')), findsNothing);

      await tester.tap(find.byKey(const Key('sense-select-button')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const Key('sense-select-menu')), findsNothing);
      expect(picked, isEmpty);
    });

    testWidgets('selected item has the filled radio; danger item is red', (tester) async {
      await tester.pumpWidget(app(const Align(alignment: Alignment.topLeft, child: _SelectHarness())));
      await tester.tap(find.byKey(const Key('sense-select-button')));
      await tester.pump();
      final off = tester.widget<Text>(find.descendant(
          of: find.byKey(const Key('sense-select-item-2')), matching: find.text('Kapalı')));
      expect(off.style!.color, SenseColors.dangerTextSoft);
      final sel = tester.widget<Semantics>(find
          .descendant(of: find.byKey(const Key('sense-select-item-0')), matching: find.byType(Semantics))
          .first);
      expect(sel.properties.selected, isTrue);
    });

    testWidgets('disabled: does not open', (tester) async {
      await tester.pumpWidget(app(const Align(alignment: Alignment.topLeft, child: _SelectHarness(enabled: false))));
      await tester.tap(find.byKey(const Key('sense-select-button')));
      await tester.pump();
      expect(find.byKey(const Key('sense-select-menu')), findsNothing);
    });

    testWidgets('golden: open list', (tester) async {
      setWindow(tester, const Size(360, 260));
      await tester.pumpWidget(app(const RepaintBoundary(
        key: Key('golden'),
        child: Padding(padding: EdgeInsets.all(16), child: Align(alignment: Alignment.topLeft, child: _SelectHarness())),
      )));
      await tester.tap(find.byKey(const Key('sense-select-button')));
      await tester.pump();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(goldenFile('sense_select_open')));
    }, skip: goldenSkip('sense_select_open'), tags: const ['golden']);
  });

  group('SenseInlineConfirm (T7)', () {
    Widget confirm({required VoidCallback onConfirm, VoidCallback? onCancel}) => SenseInlineConfirm(
          question: 'Çıkış yapılsın mı? Açık bağlantı yok.',
          confirmLabel: 'Çıkış yap',
          onConfirm: onConfirm,
          onCancel: onCancel,
          builder: (context, ask) => TextButton(onPressed: ask, child: const Text('Çıkış yap')),
        );

    testWidgets('asks in place; Vazgeç goes back; red button confirms', (tester) async {
      var done = 0;
      var cancelled = 0;
      await tester.pumpWidget(app(Center(child: confirm(onConfirm: () => done++, onCancel: () => cancelled++))));
      await tester.tap(find.text('Çıkış yap'));
      await tester.pump();
      expect(find.text('Çıkış yapılsın mı? Açık bağlantı yok.'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text(SenseCommonStrings.cancel));
      await tester.pump();
      expect(cancelled, 1);
      expect(done, 0);
      expect(find.text('Çıkış yapılsın mı? Açık bağlantı yok.'), findsNothing);

      await tester.tap(find.text('Çıkış yap'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-confirm-ok')));
      await tester.pump();
      expect(done, 1);
      expect(find.byType(Dialog), findsNothing, reason: 'no success window');
    });

    testWidgets('Esc cancels', (tester) async {
      var cancelled = 0;
      await tester.pumpWidget(app(Center(child: confirm(onConfirm: () {}, onCancel: () => cancelled++))));
      await tester.tap(find.text('Çıkış yap'));
      await tester.pump();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(cancelled, 1);
    });

    testWidgets('confirm button is the red one', (tester) async {
      await tester.pumpWidget(app(Center(
          child: SenseConfirmStrip(question: 'Kaldırılsın mı?', confirmLabel: 'Kaldır', onConfirm: () {}, onCancel: () {}))));
      final ok = tester.widget<SenseSmallButton>(find.byKey(const Key('sense-confirm-ok')));
      expect(ok.danger, isTrue);
      final box = tester.widget<Container>(find.descendant(
          of: find.byKey(const Key('sense-confirm-ok')), matching: find.byType(Container)));
      expect((box.decoration! as BoxDecoration).color, SenseColors.danger);
    });

    testWidgets('golden: second step', (tester) async {
      await tester.pumpWidget(app(sample(SenseConfirmStrip(
          question: '3 bilgisayar Projesiz kalacak · emin misin?',
          confirmLabel: 'Sil',
          onConfirm: () {},
          onCancel: () {}))));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('inline_confirm')));
    }, skip: goldenSkip('inline_confirm'), tags: const ['golden']);
  });

  group('SenseToast (T7)', () {
    test('stays 1.5–1.8 s', () {
      expect(SenseToastController.holdDuration.inMilliseconds, inInclusiveRange(1500, 1800));
    });

    testWidgets('white pill at the bottom centre, gone after the hold', (tester) async {
      setWindow(tester, const Size(800, 600));
      await tester.pumpWidget(app(SenseToastHost(
        child: Builder(
          builder: (context) => Center(
            child: TextButton(onPressed: () => SenseToast.show(context, 'Kaydedildi'), child: const Text('göster')),
          ),
        ),
      )));
      await tester.tap(find.text('göster'));
      await tester.pump();
      await tester.pump(SenseToastController.fadeDuration);
      expect(find.text('Kaydedildi'), findsOneWidget);
      final pill = tester.getRect(find.byKey(const Key('sense-toast')));
      expect(pill.center.dx, closeTo(400, 0.5));
      expect(pill.bottom, 600 - SenseToast.bottomGap);
      final box = tester.widget<Container>(find.byKey(const Key('sense-toast')));
      expect((box.decoration! as BoxDecoration).color, SenseColors.text);

      AnimatedOpacity fade() => tester.widget<AnimatedOpacity>(find.ancestor(
          of: find.byKey(const Key('sense-toast')), matching: find.byType(AnimatedOpacity)));
      expect(fade().opacity, 1);
      await tester.pump(SenseToastController.holdDuration);
      await tester.pump(SenseToastController.fadeDuration);
      expect(fade().opacity, 0);
    });

    testWidgets('a new message replaces the old one and restarts the hold', (tester) async {
      final c = SenseToastController();
      addTearDown(c.dispose);
      await tester.pumpWidget(app(SenseToastHost(controller: c, child: const SizedBox.expand())));
      c.show('Bir');
      await tester.pump(const Duration(milliseconds: 1000));
      c.show('İki');
      await tester.pump();
      expect(find.text('Bir'), findsNothing);
      expect(find.text('İki'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(c.visible, isTrue, reason: 'hold restarted');
      await tester.pump(SenseToastController.holdDuration);
      expect(c.visible, isFalse);
    });

    testWidgets('golden: toast', (tester) async {
      await tester.pumpWidget(app(sample(width: 300, const Center(child: SenseToast(message: 'Bilgisayar kaldırıldı')))));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(goldenFile('toast')));
    }, skip: goldenSkip('toast'), tags: const ['golden']);
  });
}
