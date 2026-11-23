// Sense Remote: helpers for the session bar tests (plan C1). Golden images live in
// test/goldens/session_bar/ and are made on CI (sense-golden.yml); until an image exists
// its test is skipped, then the comparison is enforced.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/bar/sense_session_frame.dart';
import 'package:flutter_hbb/sense/screens/session/chat_icon/chat_layer.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/components/components_b.dart' show SenseGlowScene, SenseGlowStyle;
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import '../chat/support.dart' show makeController;
import 'fake_backend.dart';

const String kGoldenDir = 'test/goldens/session_bar';

String goldenFile(String name) => '../../goldens/session_bar/$name.png';

bool goldenSkip(String name) => !autoUpdateGoldenFiles && !File('$kGoldenDir/$name.png').existsSync();

void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Stand-in for the remote screen (prototype `.rdesk .wall`): the library's dark glow scene
/// and the placeholder label.
class FakeRemoteScreen extends StatelessWidget {
  const FakeRemoteScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SenseGlowScene(
      key: const ValueKey('fake-remote'),
      style: SenseGlowStyle.scene,
      child: Center(
        child: Text(
          'uzak bilgisayarın ekranı · 3840×2160 · %38 ölçekte',
          style: TextStyle(
            fontFamily: SenseFont.family,
            fontSize: SenseFontSize.bodySmall,
            color: SenseColors.textDim,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

/// [chatIcon]: also draw the Sense chat icon in the remote screen's corner, as in the
/// real window (prototype c10 shows it bottom right).
Widget frameApp(FakeBackend b,
    {FakePopups? popups, SenseBarController? menus, bool chatIcon = false, bool still = false}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    // Golden images: pulses stand still at full brightness, so the recording dot reads (Y4).
    builder: still
        ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
        : null,
    home: Scaffold(
      backgroundColor: SenseColors.bg,
      body: RepaintBoundary(
        key: const Key('golden'),
        child: SenseSessionFrame(
          backend: b,
          popups: popups ?? FakePopups(),
          menus: menus,
          child: chatIcon
              ? Stack(children: [
                  const Positioned.fill(child: FakeRemoteScreen()),
                  Positioned.fill(
                    child: SenseChatLayer(
                      controller: makeController(),
                      computerName: 'Giriş Salonu PC-2',
                      animate: false,
                    ),
                  ),
                ])
              : const FakeRemoteScreen(),
        ),
      ),
    ),
  );
}

/// Lets the toast and ghost note timers run out so no timer is left at the end.
Future<void> drain(WidgetTester tester) => tester.pump(const Duration(seconds: 6));
