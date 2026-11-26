import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/components/button.dart';
import 'package:flutter_hbb/sense/components/popup_host.dart';
import 'package:flutter_hbb/sense/components/toggle.dart';
import 'package:flutter_hbb/sense/diag_log.dart';
import 'package:flutter_hbb/sense/screens/camera/sense_camera_bar.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_model.dart';
import 'package:flutter_hbb/sense/screens/session/lists/session_list.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

// Sense Remote (karar #103, Sürüm 9 Paket X): the interface record calls are wired into the
// shared parts (button, popup holder, list rows). Names and values only, never content.
Widget _app(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: SenseColors.bg, body: Center(child: child)),
    );

void main() {
  final lines = <String>[];
  setUp(() {
    lines.clear();
    senseDiagTestSink = (level, line) => lines.add(line);
  });
  tearDown(() => senseDiagTestSink = null);

  testWidgets('a library button records its label once per press; a disabled one nothing', (tester) async {
    var n = 0;
    await tester.pumpWidget(_app(Column(mainAxisSize: MainAxisSize.min, children: [
      SenseButton(label: 'Baglan', onPressed: () => n++),
      const SenseButton(label: 'Pasif', onPressed: null),
    ])));
    await tester.tap(find.text('Baglan'));
    await tester.tap(find.text('Pasif'), warnIfMissed: false);
    expect(n, 1);
    expect(lines, ['[ui] button name=Baglan']);
  });

  test('the popup holder records open, switch and close', () {
    final c = SensePopupController();
    c.open('a', (_) => const SizedBox());
    c.open('a', (_) => const SizedBox()); // same popup again: nothing new
    c.open('b', (_) => const SizedBox());
    c.close('a'); // not the open one: nothing
    c.close();
    c.close(); // nothing open: nothing
    expect(lines, [
      '[ui] popup name=a open=true',
      '[ui] popup name=a open=false',
      '[ui] popup name=b open=true',
      '[ui] popup name=b open=false',
    ]);
    c.dispose();
  });

  testWidgets('list rows record the old and the new value; a slider only when released', (tester) async {
    var toggled = false;
    await tester.pumpWidget(_app(SizedBox(
      width: 360,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SenseListEntryView(
          notify: (_) {},
          entry: SenseToggleEntry(
              id: 'mute', label: 'Sesi kapat', rustdesk: 'Mute', value: false, onChanged: (v) => toggled = v),
        ),
        SenseListEntryView(
          notify: (_) {},
          entry: SenseSliderEntry(
              id: 'fps',
              label: 'FPS',
              rustdesk: 'Custom fps',
              min: 5,
              max: 60,
              value: 30,
              format: (v) => v.round().toString(),
              onChanged: (_) {}),
        ),
      ]),
    )));
    final toggle = find.byKey(const ValueKey('sense-entry-mute'));
    expect(toggle, findsOneWidget);
    // Toggle: tap its switch through the row.
    await tester.tap(find.descendant(of: toggle, matching: find.byType(SenseToggle)));
    await tester.pump();
    expect(toggled, isTrue);
    expect(lines, contains('[ui] setting key=mute where=session.list from=false to=true'));

    lines.clear();
    final slider = find.byType(Slider);
    final center = tester.getCenter(slider);
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(lines, isEmpty, reason: 'nothing while dragging');
    await gesture.up();
    await tester.pump();
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('[ui] setting key=fps where=session.list from=30'));
  });

  testWidgets('the camera choice is as tall as a normal button, not the whole bar', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: SenseColors.bg,
        body: Column(children: [
          SenseCameraBar(
            state: const SenseCameraBarState(name: 'PC', ready: true, cameras: 2, relay: false),
            onPick: (_) {},
            onEnd: () {},
          ),
        ]),
      ),
    ));
    final bar = tester.getSize(find.byKey(const ValueKey('sense-camera-bar')));
    final choice = tester.getSize(find.byKey(const ValueKey('sense-camera-choice')));
    final end = tester.getSize(find.byKey(const ValueKey('sense-camera-end')));
    expect(choice.height, lessThan(bar.height - 8));
    expect((choice.height - end.height).abs(), lessThan(8));
  });
}
