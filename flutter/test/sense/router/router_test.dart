// Sense Remote (A2c): main entry and routing — role → home screen, opening
// screen at start / after an update / after a role change (YH T8), only dark
// theme (T1) and the "Sense Remote" window name (T2).

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart' show WindowType;
import 'package:flutter_hbb/sense/router.dart';
import 'package:flutter_hbb/sense/screens/controller/sense_home_strings.dart';
import 'package:flutter_hbb/sense/screens/splash/sense_splash.dart';
import 'package:flutter_hbb/sense/strings/common.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(home: child);

/// One breath, then the fade out.
Future<void> _waitSplashOut(WidgetTester tester) async {
  await tester.pump(SenseMotion.breatheFast.duration);
  await tester.pump(SenseMotion.layerFade.duration);
  await tester.pump();
}

void main() {
  tearDown(() {
    senseClearEntries();
    senseSplashRequest.value = null;
  });

  group('role → home screen', () {
    test('Host → hostHome; Controller and Host + Controller → controllerHome',
        () {
      expect(senseHomeEntryFor(SenseHomeRole.host), SenseEntry.hostHome);
      expect(senseHomeEntryFor(SenseHomeRole.controller),
          SenseEntry.controllerHome);
      expect(senseHomeEntryFor(SenseHomeRole.both), SenseEntry.controllerHome);
      expect(senseHomeEntryFor(SenseHomeRole.none), isNull);
    });

    testWidgets('missing entry falls back to the existing screens',
        (tester) async {
      for (final role in SenseHomeRole.values) {
        await tester.pumpWidget(_app(senseHomeFor(role,
            fallback: () => const Text('stock'))));
        expect(find.text('stock'), findsOneWidget, reason: '$role');
      }
    });

    testWidgets('registered entry is used for its role only', (tester) async {
      senseRegisterEntry(SenseEntry.hostHome, () => const Text('host'));
      senseRegisterEntry(
          SenseEntry.controllerHome, () => const Text('controller'));
      Widget home(SenseHomeRole r) =>
          _app(senseHomeFor(r, fallback: () => const Text('stock')));

      await tester.pumpWidget(home(SenseHomeRole.host));
      expect(find.text('host'), findsOneWidget);
      await tester.pumpWidget(home(SenseHomeRole.controller));
      expect(find.text('controller'), findsOneWidget);
      await tester.pumpWidget(home(SenseHomeRole.both));
      expect(find.text('controller'), findsOneWidget);
      await tester.pumpWidget(home(SenseHomeRole.none));
      expect(find.text('stock'), findsOneWidget);
    });

    test('senseRegisterScreens can be called before any screen lands', () {
      senseRegisterScreens();
      expect(senseEntry(SenseEntry.about), isNull);
    });
  });

  group('opening screen (T8)', () {
    testWidgets('at start: "Sense Remote açılıyor", one breath, then gone',
        (tester) async {
      await tester.pumpWidget(_app(const SenseSplashGate(
          animate: false, child: Text('home'))));
      expect(find.byType(SenseSplash), findsOneWidget);
      expect(find.text(SenseCommonStrings.splashOpening), findsOneWidget);
      expect(find.text('home'), findsOneWidget); // built underneath

      await tester.pump(SenseMotion.breatheFast.duration -
          const Duration(milliseconds: 100));
      expect(find.byType(SenseSplash), findsOneWidget);
      await _waitSplashOut(tester);
      expect(find.byType(SenseSplash), findsNothing);
    });

    testWidgets('the window under the splash takes no clicks', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(SenseSplashGate(
          animate: false,
          child: Center(
              child: GestureDetector(
                  onTap: () => taps++, child: const Text('home'))))));
      await tester.tap(find.text('home'), warnIfMissed: false);
      expect(taps, 0);
      await _waitSplashOut(tester);
      await tester.tap(find.text('home'));
      expect(taps, 1);
    });

    testWidgets('after an update: "Sürüm N kuruluyor · ..."', (tester) async {
      await tester.pumpWidget(_app(const SenseSplashGate(
          animate: false, updatingToVersion: 5, child: SizedBox())));
      expect(find.text(SenseCommonStrings.splashUpdating(5)), findsOneWidget);
      await _waitSplashOut(tester);
    });

    testWidgets('no splash at start when not asked', (tester) async {
      await tester.pumpWidget(_app(const SenseSplashGate(
          animate: false, showAtStart: false, child: SizedBox())));
      expect(find.byType(SenseSplash), findsNothing);
    });

    testWidgets('role change: senseShowSplash with a message', (tester) async {
      await tester.pumpWidget(_app(const SenseSplashGate(
          animate: false, showAtStart: false, child: SizedBox())));
      senseShowSplash(message: SenseCommonStrings.splashRoleChange);
      await tester.pump();
      expect(find.text('Rol uygulanıyor · Sense Remote yeni rolle açılıyor'),
          findsOneWidget);
      await _waitSplashOut(tester);
      expect(find.byType(SenseSplash), findsNothing);
      expect(senseSplashRequest.value, isNull);
    });

    test('message wins over the update text; empty message is ignored', () {
      expect(SenseSplash.textFor(5, message: 'x'), 'x');
      expect(SenseSplash.textFor(null, message: ''),
          SenseCommonStrings.splashOpening);
      expect(SenseSplash.textFor(5), SenseCommonStrings.splashUpdating(5));
    });

    test('"right after an update" is an installed result within two minutes',
        () {
      const now = 1795000000;
      int? f({bool installed = true, int? to = 5, int? at = now}) =>
          senseJustUpdatedTo(
              installed: installed, to: to, atSeconds: at, nowSeconds: now);
      expect(f(), 5);
      expect(f(at: now - 120), 5);
      expect(f(at: now + 30), 5); // stamped when the new version is healthy
      expect(f(at: now - 121), isNull);
      expect(f(installed: false), isNull);
      expect(f(to: null), isNull);
      expect(f(at: null), isNull);
    });
  });

  group('only dark theme (T1)', () {
    testWidgets('dark also when the system is light; no theme choice',
        (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      expect(MyTheme.getThemeModePreference(), ThemeMode.dark);
      expect(MyTheme.currentThemeMode(), ThemeMode.dark);
    });
  });

  group('window name (T2)', () {
    test('"Sense Remote" with a space, never "SenseRemote"', () {
      final name = getWindowName(overrideType: WindowType.Main);
      expect(name, 'Sense Remote');
      for (final t in WindowType.values) {
        expect(getWindowName(overrideType: t), contains('Sense Remote'));
        expect(getWindowName(overrideType: t), isNot(contains('SenseRemote')));
      }
    });
  });
}
