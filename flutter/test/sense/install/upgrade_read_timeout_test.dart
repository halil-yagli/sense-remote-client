// Sense Remote: the setup page's upgrade check never keeps the window on its
// black frame: a hanging or failing check gives the normal wizard (null).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_page.dart'
    show kSenseUpgradeReadTimeout, senseReadUpgradeOrNull;

void main() {
  test('a check that never answers ends after the time limit', () async {
    final watch = Stopwatch()..start();
    final result = await senseReadUpgradeOrNull(() => Completer<Never>().future,
        timeout: const Duration(milliseconds: 50));
    expect(result, isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('a failing check gives the wizard', () async {
    expect(await senseReadUpgradeOrNull(() => Future.error(StateError('x'))), isNull);
  });

  test('an answer in time is kept', () async {
    expect(await senseReadUpgradeOrNull(() async => null), isNull);
  });

  test('the time limit is short', () {
    expect(kSenseUpgradeReadTimeout, lessThanOrEqualTo(const Duration(seconds: 15)));
  });
}
