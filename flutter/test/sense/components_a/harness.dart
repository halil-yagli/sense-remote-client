// Sense Remote: shared setup of the A2a component tests (İnşa planı §5).
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/tokens/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smallest target screen (YH T9).
const Size kSenseMinScreen = Size(1280, 720);

/// Pumps [child] in the Sense app shell: dark theme, Poppins, window [size],
/// keyboard focus drawn like on a desktop. Animations are off unless [animate].
Future<void> pumpSense(
  WidgetTester tester,
  Widget child, {
  Size size = kSenseMinScreen,
  bool animate = false,
  bool center = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: senseTheme(),
    darkTheme: senseTheme(),
    themeMode: kSenseThemeMode,
    builder: (context, w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: !animate),
      child: w!,
    ),
    home: Scaffold(body: center ? Center(child: child) : child),
  ));
  await tester.pump();
}

/// A mouse that hovers [finder]; removed at the end of the test.
Future<TestGesture> hover(WidgetTester tester, Finder finder) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await g.moveTo(tester.getCenter(finder));
  await tester.pump();
  return g;
}

/// Golden images are rendered on the Linux CI runner (no local Flutter). An image that
/// was not generated yet is skipped instead of failing `PR kontrolu`; the golden job
/// (`--update-goldens`) creates it, and from then on it is compared.
const String kGoldenDir = 'test/goldens/components_a';

bool goldenSkip(String name) =>
    !autoUpdateGoldenFiles && !File('$kGoldenDir/$name.png').existsSync();

/// Path for matchesGoldenFile, relative to the test files in this folder.
String goldenPath(String name) => '../../goldens/components_a/$name.png';
