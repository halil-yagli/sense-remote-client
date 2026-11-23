// Sense Remote (P3, B7): the connecting state ends with the window call, a failure is told.

import 'package:flutter_hbb/sense/screens/controller/computers/computers_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('open succeeds → true', () async {
    var opened = 0;
    expect(await senseOpenConnection(() async => opened++), isTrue);
    expect(opened, 1);
  });

  test('open throws → false (not swallowed silently by the page)', () async {
    expect(await senseOpenConnection(() async => throw StateError('no window')), isFalse);
  });

  test('the safety net is longer than the old 4 s guess', () {
    expect(kSenseConnectSafety > const Duration(seconds: 4), isTrue);
  });
}
