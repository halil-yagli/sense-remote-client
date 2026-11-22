// Sense Remote: segmented choice (YH T7: "seçili beyaz zemin siyah yazı"; A2a).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/sense/components/segment.dart';
import 'package:flutter_hbb/sense/components/toggle.dart' show kSensePanelManaged;
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _opts = [
  SenseSegmentOption(value: 'q', label: 'Kalite'),
  SenseSegmentOption(value: 'b', label: 'Dengeli'),
  SenseSegmentOption(value: 's', label: 'Hız'),
];

class _Host extends StatefulWidget {
  const _Host({this.locked = false});

  final bool locked;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String value = 'b';
  int changes = 0;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 360,
        child: SenseSegment<String>(
          options: _opts,
          value: value,
          locked: widget.locked,
          onChanged: (v) => setState(() {
            value = v;
            changes++;
          }),
        ),
      );
}

BoxDecoration _item(WidgetTester tester, String label) => tester
    .widget<Container>(find.ancestor(of: find.text(label), matching: find.byType(Container)).first)
    .decoration! as BoxDecoration;

void main() {
  testWidgets('selected option is white with black text', (tester) async {
    await pumpSense(tester, const _Host());
    expect(_item(tester, 'Dengeli').color, SenseColors.text);
    expect(tester.widget<Text>(find.text('Dengeli')).style!.color, SenseColors.bg);
    expect(_item(tester, 'Hız').color, isNull);
    expect(tester.widget<Text>(find.text('Hız')).style!.color, SenseColors.textSecondary);
  });

  testWidgets('click selects; hover lightens an unselected option', (tester) async {
    await pumpSense(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    await hover(tester, find.text('Kalite'));
    expect(_item(tester, 'Kalite').color, SenseColors.hover);
    expect(tester.widget<Text>(find.text('Kalite')).style!.color, SenseColors.text);
    await tester.tap(find.text('Hız'));
    await tester.pump();
    expect(state.value, 's');
    expect(_item(tester, 'Hız').color, SenseColors.text);
  });

  testWidgets('keyboard: Tab to an option, Enter selects it', (tester) async {
    await pumpSense(tester, const _Host());
    final state = tester.state<_HostState>(find.byType(_Host));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(state.value, 'q');
  });

  testWidgets('locked: no change, "Panelden yönetilir"', (tester) async {
    await pumpSense(tester, const _Host(locked: true));
    final state = tester.state<_HostState>(find.byType(_Host));
    await tester.tap(find.text('Hız'), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(state.changes, 0);
    expect(find.byTooltip(kSensePanelManaged), findsOneWidget);
  });

  testWidgets('a disabled option cannot be chosen', (tester) async {
    String? picked;
    await pumpSense(
        tester,
        SizedBox(
          width: 300,
          child: SenseSegment<int>(
            options: const [
              SenseSegmentOption(value: 1, label: 'Bir'),
              SenseSegmentOption(value: 2, label: 'İki', enabled: false),
            ],
            value: 1,
            onChanged: (v) => picked = '$v',
          ),
        ));
    await tester.tap(find.text('İki'), warnIfMissed: false);
    expect(picked, isNull);
  });
}
