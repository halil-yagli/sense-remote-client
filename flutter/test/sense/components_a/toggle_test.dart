// Sense Remote: switch, setting row and the panel lock (YH T7; C3 kabul; A2a).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/sense/components/button.dart';
import 'package:flutter_hbb/sense/components/toggle.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_hbb/sense/tokens/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Stateful host so the switch really flips.
class _Host extends StatefulWidget {
  const _Host({this.locked = false});

  final bool locked;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool value = false;
  int changes = 0;

  @override
  Widget build(BuildContext context) => SenseToggle(
        value: value,
        locked: widget.locked,
        semanticLabel: 'Pano eşitle',
        onChanged: (v) => setState(() {
          value = v;
          changes++;
        }),
      );
}

Color _track(WidgetTester tester) {
  final c = tester.widget<AnimatedContainer>(
      find.descendant(of: find.byType(SenseToggle), matching: find.byType(AnimatedContainer)).first);
  return (c.decoration! as BoxDecoration).color!;
}

void main() {
  testWidgets('click flips it: off dark, on white', (tester) async {
    await pumpSense(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    expect(_track(tester), SenseColors.line);
    await tester.tap(find.byType(SenseToggle));
    await tester.pump();
    expect(state.value, isTrue);
    expect(_track(tester), SenseColors.text);
  });

  testWidgets('keyboard: Tab focuses (ring visible), Space flips', (tester) async {
    await pumpSense(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
        tester.widget<SenseFocusRing>(find.descendant(
            of: find.byType(SenseToggle), matching: find.byType(SenseFocusRing))).visible,
        isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.value, isTrue);
  });

  testWidgets('hover lightens the off track', (tester) async {
    await pumpSense(tester, const _Host());
    await hover(tester, find.byType(SenseToggle));
    expect(_track(tester), SenseColors.lineStrong);
  });

  testWidgets('locked: cannot be pressed or focused, faded, "Panelden yönetilir"', (tester) async {
    await pumpSense(tester, const _Host(locked: true));
    final state = tester.state<_HostState>(find.byType(_Host));
    await tester.tap(find.byType(SenseToggle), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.changes, 0);
    expect(find.byTooltip(kSensePanelManaged), findsOneWidget);
    final opacity = tester.widget<Opacity>(
        find.descendant(of: find.byType(SenseToggle), matching: find.byType(Opacity)).first);
    expect(opacity.opacity, SenseUi.disabledOpacity);
  });

  testWidgets('semantics: a labelled, toggled switch', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpSense(tester, const _Host());
    expect(
        tester.getSemantics(find.bySemanticsLabel('Pano eşitle')),
        containsSemantics(
            label: 'Pano eşitle',
            isButton: true,
            hasToggledState: true,
            isToggled: false,
            isEnabled: true,
            hasTapAction: true));
    handle.dispose();
  });

  testWidgets('locked row shows the lock line; open row does not', (tester) async {
    await pumpSense(
        tester,
        SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SenseToggleRow(label: 'Hareketsiz kes', value: true, onChanged: (_) {}, locked: true),
            SenseToggleRow(label: 'Pano eşitle', value: false, onChanged: (_) {}, last: true),
          ]),
        ));
    expect(find.text(kSensePanelManaged), findsOneWidget);
    expect(find.byType(SenseLockIcon), findsOneWidget);
    expect(
        tester.widget<Text>(find.text('Hareketsiz kes')).style!.color, SenseColors.textSecondary);
  });

  testWidgets('"Kaydedildi" appears after a save and goes away', (tester) async {
    var trigger = 0;
    late StateSetter set;
    await pumpSense(
        tester,
        SizedBox(
          width: 400,
          child: StatefulBuilder(builder: (context, s) {
            set = s;
            return SenseToggleRow(
                label: 'Pano eşitle', value: false, onChanged: (_) {}, savedTrigger: trigger);
          }),
        ),
        animate: true);
    double opacity() => tester
        .widget<AnimatedOpacity>(find.ancestor(of: find.text(kSenseSaved), matching: find.byType(AnimatedOpacity)))
        .opacity;
    expect(opacity(), 0);
    set(() => trigger++);
    await tester.pump();
    expect(opacity(), 1);
    await tester.pump(SenseMotion.savedFadeIn.duration + SenseMotion.savedHold.duration);
    await tester.pump();
    expect(opacity(), 0);
    await tester.pumpAndSettle();
  });
}
