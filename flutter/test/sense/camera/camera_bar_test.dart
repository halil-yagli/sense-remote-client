// Sense Remote: the camera window bar (YH O6 "Kamerayı görüntüle", Paket L / Y1). Golden
// images live in test/goldens/camera/ and are made on CI (sense-golden.yml); until an image
// exists its test is skipped, then the comparison is enforced.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/camera/sense_camera_bar.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import '../session_bar/harness.dart' show FakeRemoteScreen;

String _golden(String name) => '../../goldens/camera/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('test/goldens/camera/$name.png').existsSync();

Widget _app(SenseCameraBarState state, {ValueChanged<int>? onPick, VoidCallback? onEnd}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: SenseColors.bg,
        body: RepaintBoundary(
          key: const Key('golden'),
          child: Column(children: [
            SenseCameraBar(state: state, onPick: onPick ?? (_) {}, onEnd: onEnd ?? () {}),
            const Expanded(child: FakeRemoteScreen()),
          ]),
        ),
      ),
    );

void _window(WidgetTester t, Size s) {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  group('status line', () {
    test('connecting, no camera, one camera with its path', () {
      expect(const SenseCameraBarState(name: 'PC').line, 'Kamera bağlanıyor…');
      expect(const SenseCameraBarState(name: 'PC', ready: true).line, 'Kamera bulunamadı');
      expect(const SenseCameraBarState(name: 'PC', ready: true, cameras: 1).line, 'Kamera 1');
      expect(const SenseCameraBarState(name: 'PC', ready: true, cameras: 2, current: 1, relay: false).line,
          'Kamera 2 · Doğrudan');
      expect(const SenseCameraBarState(name: 'PC', ready: true, cameras: 1, relay: true).line, 'Kamera 1 · Aktarmalı');
    });

    test('camera choice only with more than one camera', () {
      expect(const SenseCameraBarState(name: 'PC', ready: true, cameras: 1).showChoice, isFalse);
      expect(const SenseCameraBarState(name: 'PC', ready: true, cameras: 2).showChoice, isTrue);
      expect(const SenseCameraBarState(name: 'PC', cameras: 2).showChoice, isFalse);
    });
  });

  testWidgets('pick a camera, Bitir ends; the bar is 46 px and never says RustDesk', (tester) async {
    _window(tester, const Size(1280, 720));
    final picked = <int>[];
    var ended = false;
    await tester.pumpWidget(_app(
      const SenseCameraBarState(name: 'Giriş Salonu PC-2', ready: true, cameras: 2, relay: false),
      onPick: picked.add,
      onEnd: () => ended = true,
    ));
    expect(tester.getSize(find.byKey(const ValueKey('sense-camera-bar'))).height, SenseSizes.sessionToolbarHeight);
    await tester.tap(find.text('Kamera 2'));
    await tester.pump();
    expect(picked, [1]);
    await tester.tap(find.byKey(const ValueKey('sense-camera-end')));
    await tester.pump();
    expect(ended, isTrue);
    expect(find.textContaining('RustDesk'), findsNothing);
  });

  testWidgets('camera bar, two cameras (1280 × 720, T9)', (tester) async {
    _window(tester, const Size(1280, 720));
    await tester.pumpWidget(_app(const SenseCameraBarState(
        name: 'Giriş Salonu PC-2', ready: true, cameras: 2, relay: false)));
    await tester.pump();
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('camera_bar_two')));
  }, skip: _skip('camera_bar_two'), tags: const ['golden']);

  testWidgets('camera bar, connecting', (tester) async {
    _window(tester, const Size(1280, 720));
    await tester.pumpWidget(_app(const SenseCameraBarState(name: 'Giriş Salonu PC-2')));
    await tester.pump();
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('camera_bar_connecting')));
  }, skip: _skip('camera_bar_connecting'), tags: const ['golden']);
}
