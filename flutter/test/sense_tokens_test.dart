// Sense Remote: design tokens (YH T1-T4, T6; İnşa planı §4.3). The generated Dart and CSS
// must match design/tokens.json, the JSON must keep the prototype's values, and the status
// helper must cut exactly at the YH T6 limits.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

// `flutter test` runs in flutter/; the source lives one level up.
final Map<String, dynamic> _json =
    jsonDecode(File('../design/tokens.json').readAsStringSync()) as Map<String, dynamic>;
final String _css = File('../design/tokens.css').readAsStringSync();

Map<String, dynamic> _group(String name) => _json[name] as Map<String, dynamic>;

double _value(dynamic item) => ((item as Map<String, dynamic>)['value'] as num).toDouble();

Color _hex(String hex) => Color(int.parse('FF${hex.substring(1)}', radix: 16));

String _kebab(String name) =>
    name.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}');

void _sameKeys(String group, Iterable<String> generated) {
  expect(generated.toSet(), _group(group).keys.toSet(), reason: '$group: run the generator');
}

void _sameDoubles(String group, Map<String, double> generated) {
  _sameKeys(group, generated.keys);
  _group(group).forEach((key, item) {
    expect(generated[key], _value(item), reason: '$group.$key');
  });
}

void main() {
  group('generated Dart matches tokens.json', () {
    test('version and digest', () {
      expect(SenseTokensMeta.version, _json['version']);
      expect(_css, contains('sha256:${SenseTokensMeta.digest}'));
    });

    test('colours', () {
      _sameKeys('color', SenseColors.all.keys);
      _group('color').forEach((key, item) {
        expect(SenseColors.all[key], _hex(item['value'] as String), reason: 'color.$key');
      });
    });

    test('glow gradient', () {
      final glow = _group('gradient')['glow'] as Map<String, dynamic>;
      final colors = (glow['colors'] as List).map((c) => SenseColors.all[c]).toList();
      expect(SenseGradients.glow.colors, colors);
      expect(SenseGradients.glow.begin, Alignment.centerLeft);
      expect(SenseGradients.glow.end, Alignment.centerRight);
    });

    test('font', () {
      expect(SenseFont.family, (_json['font'] as Map)['family']);
      _sameKeys('fontWeight', SenseFontWeight.all.keys);
      _group('fontWeight').forEach((key, item) {
        expect(SenseFontWeight.all[key]!.value, item['value'], reason: 'fontWeight.$key');
      });
    });

    test('numbers', () {
      _sameDoubles('fontSize', SenseFontSize.all);
      _sameDoubles('letterSpacing', SenseLetterSpacing.all);
      _sameDoubles('size', SenseSizes.all);
      _sameDoubles('radius', SenseRadii.all);
      _sameDoubles('breakpoint', SenseBreakpoints.all);
      _sameDoubles('motionParam', SenseMotionParams.all);
    });

    test('curves', () {
      _sameKeys('curve', SenseCurves.all.keys);
      _group('curve').forEach((key, item) {
        final b = (item['bezier'] as List).map((x) => (x as num).toDouble()).toList();
        final c = SenseCurves.all[key]!;
        expect([c.a, c.b, c.c, c.d], b, reason: 'curve.$key');
      });
    });

    test('motion', () {
      _sameKeys('motion', SenseMotion.all.keys);
      _group('motion').forEach((key, item) {
        final m = SenseMotion.all[key]!;
        expect(m.duration, Duration(milliseconds: item['ms'] as int), reason: 'motion.$key');
        expect(m.curve, same(SenseCurves.all[item['curve']]), reason: 'motion.$key');
        expect(m.repeat, item['repeat'], reason: 'motion.$key');
      });
    });

    test('thresholds', () {
      _sameKeys('threshold', SenseThresholds.all.keys);
      _group('threshold').forEach((key, item) {
        final t = SenseThresholds.all[key]!;
        expect(t.warn, (item['warn'] as num).toDouble(), reason: 'threshold.$key');
        expect(t.hot, (item['hot'] as num).toDouble(), reason: 'threshold.$key');
        expect(t.direction.name, item['direction'], reason: 'threshold.$key');
        expect(t.unit, item['unit'], reason: 'threshold.$key');
      });
    });
  });

  test('generated CSS matches tokens.json', () {
    _group('color').forEach((key, item) {
      expect(_css, contains('--sr-color-${_kebab(key)}: ${(item['value'] as String).toLowerCase()};'));
    });
    _group('motion').forEach((key, item) {
      expect(_css, contains('--sr-motion-${_kebab(key)}: ${item['ms']}ms;'));
    });
    _group('threshold').forEach((key, item) {
      expect(_css, contains('--sr-threshold-${_kebab(key)}-warn: ${item['warn']};'));
      expect(_css, contains('--sr-threshold-${_kebab(key)}-hot: ${item['hot']};'));
    });
  });

  // Values copied from the prototype CSS (:root, keyframes, media queries) and YH T6.
  // If one of these fails, the JSON drifted from the visual target: fix the JSON,
  // or change the prototype first (İnşa planı §4.3).
  test('tokens keep the prototype values', () {
    expect(SenseColors.bg, const Color(0xFF000000));
    expect(SenseColors.surface, const Color(0xFF0A0A0E));
    expect(SenseColors.raised, const Color(0xFF15151B));
    expect(SenseColors.line, const Color(0xFF26262F));
    expect(SenseColors.hover, const Color(0xFF1D1D25));
    expect(SenseColors.textMuted, const Color(0xFF8E8E98));
    // Sürüm 11 (TS-2): AA için açıldı (#5D5D68 kartta 2,8:1 idi).
    expect(SenseColors.textDim, const Color(0xFF80808A));
    expect(SenseColors.ok, const Color(0xFF00FFB6));
    expect(SenseColors.warn, const Color(0xFFFF9700));
    expect(SenseColors.hot, const Color(0xFFFF2D3D));
    expect(SenseColors.danger, const Color(0xFFD81E30));
    expect(SenseColors.all.values, isNot(contains(const Color(0xFF0071FF))),
        reason: 'no RustDesk blue (YH T1)');
    expect(SenseMotion.popupOpen.duration.inMilliseconds, 140);
    final island = SenseMotion.islandExpand.curve;
    expect([island.a, island.b, island.c, island.d], [0.3, 1.45, 0.45, 1.0]);
    expect(SenseMotion.islandExpand.duration.inMilliseconds, 420);
    expect(SenseMotion.callRing.duration.inMilliseconds, 1600);
    expect(SenseMotion.groupPulse.duration.inMilliseconds, 4500);
    expect(SenseMotionParams.popupScaleFrom, 0.985);
    expect(SenseMotionParams.breatheOpacityMin, 0.55);
    expect(SenseSizes.popupWidth, 440);
    expect(SenseBreakpoints.medium, 1500);
    expect(SenseBreakpoints.narrow, 1300);
  });

  // Sürüm 11 (TS-2, YH T1): yazı renkleri her yüzeyde AA (4,5:1). textDim en kötü yüzey
  // olan kartta (raised) da geçer; süs çizgisi olarak kullanımı bundan etkilenmez.
  test('text colours keep AA contrast on the surfaces', () {
    double lin(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    double lum(Color c) => 0.2126 * lin(c.red / 255) + 0.7152 * lin(c.green / 255) + 0.0722 * lin(c.blue / 255);
    double ratio(Color a, Color b) {
      final x = lum(a), y = lum(b);
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }

    for (final text in [SenseColors.textMuted, SenseColors.textDim]) {
      for (final bg in [SenseColors.bg, SenseColors.surface, SenseColors.raised]) {
        expect(ratio(text, bg), greaterThanOrEqualTo(4.5), reason: '$text on $bg');
      }
    }
  });

  group('status levels (YH T6)', () {
    void cut(SenseThreshold t, Map<num, SenseLevel> cases) {
      cases.forEach((value, level) {
        expect(t.levelOf(value), level, reason: '$value ${t.unit}');
      });
    }

    test('usage and disk fullness: 85 orange, 95 red', () {
      cut(SenseThresholds.usage, {
        0: SenseLevel.ok,
        84.9: SenseLevel.ok,
        85: SenseLevel.warn,
        94.99: SenseLevel.warn,
        95: SenseLevel.hot,
        100: SenseLevel.hot,
      });
    });

    test('CPU / GPU temperature: 80 °C, 90 °C', () {
      cut(SenseThresholds.chipTemp,
          {79: SenseLevel.ok, 80: SenseLevel.warn, 89.5: SenseLevel.warn, 90: SenseLevel.hot});
    });

    test('disk temperature: 55 °C, 65 °C', () {
      cut(SenseThresholds.diskTemp,
          {54: SenseLevel.ok, 55: SenseLevel.warn, 64: SenseLevel.warn, 65: SenseLevel.hot});
    });

    test('latency: 150 ms, 300 ms', () {
      cut(SenseThresholds.latency,
          {18: SenseLevel.ok, 149: SenseLevel.ok, 150: SenseLevel.warn, 300: SenseLevel.hot});
    });

    test('packet loss: 2 %, 5 %', () {
      cut(SenseThresholds.packetLoss,
          {1.99: SenseLevel.ok, 2: SenseLevel.warn, 4.9: SenseLevel.warn, 5: SenseLevel.hot});
    });

    test('frame rate: under 15 orange, under 8 red', () {
      cut(SenseThresholds.frameRate, {
        60: SenseLevel.ok,
        15: SenseLevel.ok,
        14.9: SenseLevel.warn,
        8: SenseLevel.warn,
        7.9: SenseLevel.hot,
        0: SenseLevel.hot,
      });
    });

    test('an unreadable value is unknown, never guessed', () {
      for (final t in SenseThresholds.all.values) {
        expect(t.levelOf(null), SenseLevel.unknown);
        expect(t.levelOf(double.nan), SenseLevel.unknown);
      }
      expect(SenseLevel.unknown.color, SenseColors.textMuted);
    });

    test('level colours', () {
      expect(SenseLevel.ok.color, SenseColors.ok);
      expect(SenseLevel.warn.color, SenseColors.warn);
      expect(SenseLevel.hot.color, SenseColors.hot);
    });

    test('closed category takes the worst level', () {
      expect(senseWorstLevel([SenseLevel.ok, SenseLevel.hot, SenseLevel.warn]), SenseLevel.hot);
      expect(senseWorstLevel([SenseLevel.ok, SenseLevel.unknown, SenseLevel.warn]),
          SenseLevel.warn);
      expect(senseWorstLevel([SenseLevel.unknown, SenseLevel.ok]), SenseLevel.ok);
      expect(senseWorstLevel([SenseLevel.unknown]), SenseLevel.unknown);
      expect(senseWorstLevel(const []), SenseLevel.unknown);
    });
  });

  test('widths follow the 1500 / 1300 px breakpoints (max-width, inclusive) (YH T3, T9)', () {
    expect(SenseLayout.popupWidth(1920), 440);
    expect(SenseLayout.popupWidth(1501), 440);
    expect(SenseLayout.popupWidth(1500), 400);
    expect(SenseLayout.popupWidth(1366), 400);
    expect(SenseLayout.popupWidth(1301), 400);
    expect(SenseLayout.popupWidth(1300), 370);
    expect(SenseLayout.popupWidth(1280), 370);
    expect(SenseLayout.sideMenu(1366), 212);
    expect(SenseLayout.sideMenu(1280), 180);
    expect(SenseLayout.tileMin(1280), 180);
    expect(senseLetterSpacing(SenseLetterSpacing.code, 20), closeTo(2.4, 1e-9));
  });
}
