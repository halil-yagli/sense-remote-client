// Sense Remote (S7, #88, #89, #91): window size at every monitor scale, and the Ctrl/Cmd default.

import 'package:flutter/material.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/sense/screens/host_live/data/overlay.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_geometry.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_page.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_wizard.dart';
import 'package:flutter_hbb/sense/screens/session/sense_swap_key_default.dart';
import 'package:flutter_hbb/sense/window/sense_window_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support.dart' show app, c08Controller;
import '../install/sense_install_upgrade_test.dart' show FakeUpgrade;
import '../install/sense_install_wizard_test.dart' show FakeBackend, frames;

void main() {
  group('senseViewMatches (#99)', () {
    const want = Rect.fromLTWH(1200, 300, 660, 1020);
    test('frameless window, view as large as the window: match', () {
      expect(
          senseViewMatches(
              want: want, window: want, client: want.size, flutter: want.size),
          isTrue);
    });
    test('the hidden title bar border (16 x 8 px) is caught', () {
      expect(
          senseViewMatches(
              want: want,
              window: want,
              client: const Size(644, 1012),
              flutter: const Size(644, 1012)),
          isFalse);
    });
    test('a Flutter view left at another size is caught', () {
      expect(
          senseViewMatches(
              want: want, window: want, client: want.size, flutter: const Size(990, 1530)),
          isFalse);
    });
    test('a window the system scaled again is caught', () {
      expect(
          senseViewMatches(
              want: want,
              window: const Rect.fromLTWH(1200, 300, 990, 1530),
              client: const Size(990, 1530),
              flutter: const Size(990, 1530)),
          isFalse);
    });
  });

  group('senseBoundsMatch', () {
    const want = Rect.fromLTWH(100, 50, 660, 1020);
    test('same frame and a pixel off match', () {
      expect(senseBoundsMatch(want, want), isTrue);
      expect(senseBoundsMatch(want, want.shift(const Offset(1, -1))), isTrue);
    });
    test('a window scaled again by the system does not match', () {
      expect(senseBoundsMatch(want, Rect.fromLTWH(100, 50, 660 * 1.5, 1020 * 1.5)), isFalse);
      expect(senseBoundsMatch(want, Rect.fromLTWH(100, 50, 440, 680)), isFalse);
    });
  });

  group('senseScaledSize / senseLogicalVisible', () {
    for (final scale in [1.0, 1.5, 2.0]) {
      test('scale $scale', () {
        final px = senseScaledSize(kSenseCmPanelSize, scale);
        expect(px.width, kSenseCmPanelSize.width * scale);
        final vis = senseLogicalVisible(Rect.fromLTWH(0, 0, 2560 * scale / 1.0, 1400 * scale), scale)!;
        expect(vis, const Size(2560, 1400));
      });
    }
    test('unknown scale', () {
      expect(senseLogicalVisible(const Rect.fromLTWH(0, 0, 100, 100), 0), isNull);
      expect(senseScaledSize(const Size(10, 10), 0), const Size(10, 10));
    });
  });

  group('the card window at every scale', () {
    for (final scale in [1.0, 1.5, 2.0]) {
      test('panel rect is the logical panel times $scale, inside the work area', () {
        final work = Rect.fromLTWH(0, 0, 2560 * scale, 1400 * scale);
        final icon = senseCmDefaultIconRect(
            work, kSenseCmIconSize * scale, kSenseCmMargin * scale);
        final anchor = senseCmAnchorFor(icon, work);
        final panel = senseCmPanelRect(icon, kSenseCmPanelSize * scale, work, anchor);
        expect(panel.size, kSenseCmPanelSize * scale);
        expect(work.contains(panel.topLeft) && work.contains(panel.bottomRight), isTrue);
        final back = senseCmIconRectFromPanel(panel, kSenseCmIconSize * scale, work, anchor);
        expect(back, icon);
      });

      testWidgets('card fills the window at devicePixelRatio $scale', (tester) async {
        final window = kSenseCmPanelSize * scale;
        tester.view.physicalSize = window;
        tester.view.devicePixelRatio = scale;
        addTearDown(tester.view.reset);
        final client = Client(1, true, false, false, 'Halil Y.', '123456789', true, false, false);
        await tester.pumpWidget(app(
          SenseHostCard(
            client: client,
            chat: c08Controller(),
            whoLine: senseHostWhoLine(client, const Duration(minutes: 3)),
            animateIn: false,
            actions: SenseHostCardActions(
              onMinimize: () {},
              onEnd: () {},
              onAccept: () {},
              onReject: () {},
              onCloseEnded: () {},
              onAnswerCall: (_) {},
            ),
          ),
          still: true,
        ));
        await tester.pump(const Duration(milliseconds: 400));
        // Logical size equals the panel size at every ratio: the card is the whole window.
        expect(tester.getSize(find.byType(SenseHostCard)), kSenseCmPanelSize);
        expect(tester.takeException(), isNull);
      });

      testWidgets('install wizard fits its window at devicePixelRatio $scale', (tester) async {
        final f = senseInstallWindowFor(const Size(1280, 720));
        tester.view.physicalSize = f.size * scale;
        tester.view.devicePixelRatio = scale;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(Theme(
          data: senseTheme(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: senseTheme(),
            home: Scaffold(
              backgroundColor: SenseColors.bg,
              body: SenseInstallWizard(
                initialPath: r'C:\Program Files\Sense Remote',
                backend: FakeBackend(),
                upgrade: FakeUpgrade().make(),
                version: '7',
              ),
            ),
          ),
        ));
        await frames(tester);
        expect(tester.getSize(find.byType(SenseInstallWizard)), f.size);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('senseApplySwapKeyDefault (#91)', () {
    Future<(bool, int)> run({
      required bool mac,
      required String? peer,
      bool win = false,
      bool decided = false,
      bool on = false,
    }) async {
      var turned = 0;
      final did = await senseApplySwapKeyDefault(
        controllerIsMac: mac,
        controllerIsWindows: win,
        peerPlatform: peer,
        readDecided: () async => decided,
        isOn: () => on,
        turnOn: () async => turned++,
      );
      return (did, turned);
    }

    test('Mac to Windows, no choice yet: turned on', () async {
      expect(await run(mac: true, peer: kPeerPlatformWindows), (true, 1));
    });
    test('the user turned it off: stays off', () async {
      expect(await run(mac: true, peer: kPeerPlatformWindows, decided: true), (false, 0));
    });
    test('already on: nothing to do', () async {
      expect(await run(mac: true, peer: kPeerPlatformWindows, on: true), (false, 0));
    });
    test('Windows Controller to a Mac peer (#135): turned on, a choice is kept', () async {
      expect(await run(mac: false, win: true, peer: kPeerPlatformMacOS), (true, 1));
      expect(await run(mac: false, win: true, peer: kPeerPlatformMacOS, decided: true), (false, 0));
      expect(await run(mac: false, win: true, peer: kPeerPlatformMacOS, on: true), (false, 0));
    });
    test('Windows to Windows, Mac to Mac, Linux: untouched', () async {
      expect(await run(mac: false, win: true, peer: kPeerPlatformWindows), (false, 0));
      expect(await run(mac: false, win: true, peer: kPeerPlatformLinux), (false, 0));
    });
    test('Windows Controller (not told), or Mac peer, or Linux peer: untouched', () async {
      expect(await run(mac: false, peer: kPeerPlatformWindows), (false, 0));
      expect(await run(mac: true, peer: kPeerPlatformMacOS), (false, 0));
      expect(await run(mac: true, peer: kPeerPlatformLinux), (false, 0));
      expect(await run(mac: true, peer: null), (false, 0));
    });
  });
}
