// Sense Remote: helpers for the component tests of plan A2b.
//
// Golden images live in test/goldens/components_b/ (İnşa planı §5, plan §0.5) and
// are produced on CI by the golden workflow (`flutter test --update-goldens`);
// there is no Flutter on the developer machine. Until an image exists, its
// golden test is skipped (not failed) so "PR kontrolu" stays meaningful; once
// the image is committed the comparison is enforced. Every golden test carries
// the `golden` tag.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

const String kGoldenDir = 'test/goldens/components_b';

/// Path for matchesGoldenFile, relative to the test files in this folder.
String goldenFile(String name) => '../../goldens/components_b/$name.png';

/// Skip value for a golden test: true while the image has not been generated.
bool goldenSkip(String name) =>
    !autoUpdateGoldenFiles && !File('$kGoldenDir/$name.png').existsSync();

/// Sets the test window to [size] logical px at ratio 1.
void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Black app frame; [child] fills it.
Widget app(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
        child: ColoredBox(
          color: SenseColors.bg,
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: SenseFont.family, color: SenseColors.text),
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// A golden sample: [child] on black with padding, captured by key `golden`.
Widget sample(Widget child, {double width = 440, EdgeInsets padding = const EdgeInsets.all(16)}) {
  return Align(
    alignment: Alignment.topLeft,
    child: RepaintBoundary(
      key: const Key('golden'),
      child: Container(
        color: SenseColors.bg,
        padding: padding,
        width: width + padding.horizontal,
        child: child,
      ),
    ),
  );
}

/// No Transform in [tester]'s tree turns anything (YH T4: no rotation).
void expectNoRotation(WidgetTester tester) {
  expect(find.byType(RotationTransition), findsNothing);
  for (final t in tester.widgetList<Transform>(find.byType(Transform))) {
    final m = t.transform;
    expect(m.entry(0, 1).abs() < 1e-9 && m.entry(1, 0).abs() < 1e-9, isTrue,
        reason: 'a Transform rotates');
  }
}
