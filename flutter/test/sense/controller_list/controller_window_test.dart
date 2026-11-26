// Sense Remote (Paket C, Y2; T3, T9): the Controller main window is 1180 x 720,
// trimmed to the visible screen; Host and the stock home are left alone.
import 'dart:ui';

import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart';
import 'package:flutter_hbb/sense/screens/controller/shell/controller_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only Controller roles get the size', () {
    expect(senseControllerWindowApplies(SenseHomeRole.controller), isTrue);
    expect(senseControllerWindowApplies(SenseHomeRole.both), isTrue);
    expect(senseControllerWindowApplies(SenseHomeRole.host), isFalse);
    expect(senseControllerWindowApplies(SenseHomeRole.none), isFalse);
  });

  test('1180 x 720 on a big screen or an unknown one', () {
    expect(senseControllerWindowSize(), const Size(1180, 720));
    expect(senseControllerWindowSize(visibleWidth: 2560, visibleHeight: 1400), const Size(1180, 720));
  });

  test('a short screen shortens the window (1366x768 laptop, mixed DPI at 125%)', () {
    expect(senseControllerWindowSize(visibleWidth: 1366, visibleHeight: 728), const Size(1180, 720));
    expect(senseControllerWindowSize(visibleWidth: 1280, visibleHeight: 680), const Size(1180, 680));
    // 1920x1080 at 150%: visible 1280 x 680 logical.
    final s = senseControllerWindowSize(visibleWidth: 1920 / 1.5, visibleHeight: 1040 / 1.5);
    expect(s.width, 1180);
    expect(s.height, closeTo(693.33, 0.01));
  });

  test('never below 1024 x 600', () {
    expect(senseControllerWindowSize(visibleWidth: 900, visibleHeight: 500), const Size(1024, 600));
  });
}
