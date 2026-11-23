// Sense Remote: helpers for the session bar tests (plan C1). Golden images live in
// test/goldens/session_bar/ and are made on CI (sense-golden.yml); until an image exists
// its test is skipped, then the comparison is enforced.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/bar/sense_session_frame.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'fake_backend.dart';

const String kGoldenDir = 'test/goldens/session_bar';

String goldenFile(String name) => '../../goldens/session_bar/$name.png';

bool goldenSkip(String name) => !autoUpdateGoldenFiles && !File('$kGoldenDir/$name.png').existsSync();

void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Stand-in for the remote screen (prototype `.rdesk .wall`).
class FakeRemoteScreen extends StatelessWidget {
  const FakeRemoteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const ValueKey('fake-remote'),
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-0.4, -0.2),
          radius: 1.2,
          colors: [SenseColors.glowStart.withOpacity(0.75), SenseColors.glowEnd.withOpacity(0.35), SenseColors.bg],
        ),
      ),
      child: const SizedBox.expand(),
    );
  }
}

Widget frameApp(FakeBackend b, {FakePopups? popups, SenseBarController? menus}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: SenseColors.bg,
      body: RepaintBoundary(
        key: const Key('golden'),
        child: SenseSessionFrame(
          backend: b,
          popups: popups ?? FakePopups(),
          menus: menus,
          child: const FakeRemoteScreen(),
        ),
      ),
    ),
  );
}

/// Lets the toast and ghost note timers run out so no timer is left at the end.
Future<void> drain(WidgetTester tester) => tester.pump(const Duration(seconds: 6));
