// Sense Remote: wave 3 interface fixes — Sense theme, bundled Poppins and
// WCAG AA contrast of the small texts and the "end" button (design review
// T3-3, T3-5, T3-6, T3-7).

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/sense_theme.dart';
import 'package:flutter_hbb/sense/screens/host_live/sense_cm_style.dart';
import 'package:flutter_hbb/sense/screens/install/sense_install_wizard.dart';
import 'package:flutter_test/flutter_test.dart';

double _channel(int value) {
  final c = value / 255;
  return c <= 0.03928
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color c) =>
    0.2126 * _channel(c.red) +
    0.7152 * _channel(c.green) +
    0.0722 * _channel(c.blue);

/// WCAG 2.x contrast ratio.
double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('contrast (WCAG AA, 4.5:1 for small text)', () {
    test('small setup texts on black', () {
      expect(contrast(SenseTokens.dim, SenseTokens.black),
          greaterThanOrEqualTo(4.5));
      expect(contrast(SenseTokens.muted, SenseTokens.black),
          greaterThanOrEqualTo(4.5));
    });

    test('white text on the "end" button', () {
      expect(contrast(SenseCmTokens.white, SenseCmTokens.danger),
          greaterThanOrEqualTo(4.5));
    });

    test('Host card small texts on black', () {
      expect(contrast(SenseCmTokens.muted, SenseCmTokens.black),
          greaterThanOrEqualTo(4.5));
    });
  });

  group('Sense theme', () {
    test('only an installed role switches to it', () {
      expect(
          senseRoleInstalledFrom(
              incomingOnly: false, outgoingOnly: false, settingsDisabled: false),
          isFalse);
      expect(
          senseRoleInstalledFrom(
              incomingOnly: true, outgoingOnly: false, settingsDisabled: true),
          isTrue);
      expect(
          senseRoleInstalledFrom(
              incomingOnly: false, outgoingOnly: true, settingsDisabled: false),
          isTrue);
      expect(
          senseRoleInstalledFrom(
              incomingOnly: false, outgoingOnly: false, settingsDisabled: true),
          isTrue);
    });

    test('black surfaces, white accent, Poppins', () {
      final theme = senseDarkTheme(ThemeData.dark());
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, SenseThemeColors.black);
      expect(theme.colorScheme.primary, SenseThemeColors.white);
      expect(theme.colorScheme.secondary, SenseThemeColors.white);
      expect(theme.textTheme.bodyMedium?.fontFamily, kSenseFont);
      final button = theme.elevatedButtonTheme.style!;
      expect(button.backgroundColor?.resolve({}), SenseThemeColors.white);
      expect(button.foregroundColor?.resolve({}), SenseThemeColors.black);
    });

    test('no RustDesk branding lines', () {
      expect(kSenseHideStockBranding, isTrue);
    });
  });

  test('Poppins is bundled with its license (SIL OFL 1.1)', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('family: Poppins'));
    for (final name in const [
      'ExtraLight',
      'Light',
      'Regular',
      'Medium',
      'SemiBold',
      'Bold'
    ]) {
      final path = 'assets/fonts/Poppins-$name.ttf';
      expect(pubspec, contains(path));
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(File('assets/fonts/Poppins-OFL.txt').readAsStringSync(),
        contains('SIL Open Font License'));
    expect(kSenseFont, SenseCmTokens.font);
    expect(kSenseFont, SenseTokens.font);
  });
}
