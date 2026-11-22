// Sense Remote: the one app theme (YH T1, T2; İnşa planı §4.1, §4.3).
// Dark only: there is no light theme and no theme choice (#38). The app passes the
// same theme as `theme` and `darkTheme` with [kSenseThemeMode], so a system in light
// mode still gets the dark app. Every value comes from the design tokens.
import 'package:flutter/material.dart';

import 'sense_tokens.dart';

/// Always dark, whatever the system says (YH T1 kabul: "sistem açık temadayken de koyu").
const ThemeMode kSenseThemeMode = ThemeMode.dark;

/// Small values the components share that are derived from the prototype, not from
/// design/tokens.json (token candidates; see the A2a report).
abstract final class SenseUi {
  /// Disabled / locked control (prototype `.tgl[disabled]`, `.btn[disabled]`).
  static const double disabledOpacity = 0.45;

  /// Keyboard focus ring: line width and gap outside the control.
  static const double focusRingWidth = 1.5;
  static const double focusRingGap = 2.0;

  /// Window height at or under which spacing tightens (prototype `max-height:800px`, T9).
  static const double shortWindowHeight = 800.0;

  /// Scrollbar thumb: gap to the ends and shortest length (prototype `::-webkit-scrollbar`).
  static const double scrollbarMainMargin = 6.0;
  static const double scrollbarMinThumb = 36.0;

  /// Regular button side padding at or under 1500 px (prototype `@media (max-width:1500px) .btn`).
  static const double buttonPadHMedium = 9.0;

  /// Gap between an icon / dot and its text.
  static const double iconGap = 6.0;

  /// Setting row (`.srow`): vertical padding and the gap before the control.
  static const double rowPadV = 9.0;
  static const double rowGap = 12.0;
}

/// Text styles of the library (YH T2). Screens use these or `SenseTextStyles.of(...)`;
/// no screen writes a font size.
abstract final class SenseTextStyles {
  static TextStyle of({
    double size = SenseFontSize.body,
    FontWeight weight = SenseFontWeight.regular,
    Color color = SenseColors.text,
    double? letterSpacingEm,
    FontStyle? fontStyle,
    double? height,
  }) =>
      TextStyle(
        fontFamily: SenseFont.family,
        fontSize: size,
        fontWeight: weight,
        color: color,
        fontStyle: fontStyle,
        height: height,
        letterSpacing: letterSpacingEm == null ? null : senseLetterSpacing(letterSpacingEm, size),
        decoration: TextDecoration.none,
      );

  /// Gövde, 400.
  static final TextStyle body = of();

  /// Gövde, sıkışık.
  static final TextStyle bodySmall = of(size: SenseFontSize.bodySmall);

  /// Düğme yazısı (12 · 500).
  static final TextStyle button = of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.medium);

  /// Küçük düğme yazısı (11,5 · 500).
  static final TextStyle buttonSmall = of(size: SenseFontSize.hintLarge, weight: SenseFontWeight.medium);

  /// Açıklama / ipucu (soluk; okunması gereken metin en az textMuted — karar TK9-1).
  static final TextStyle hint = of(size: SenseFontSize.hint, color: SenseColors.textMuted);

  /// Büyük harf etiket ("SIK KULLANILAN"): süs niteliğinde, textDim.
  static final TextStyle caps = of(
      size: SenseFontSize.caps,
      weight: SenseFontWeight.bold,
      color: SenseColors.textDim,
      letterSpacingEm: SenseLetterSpacing.capsWide);

  /// Kategori / kart başlığı (13 · 600).
  static final TextStyle categoryTitle = of(size: SenseFontSize.categoryTitle, weight: SenseFontWeight.bold);

  /// Sayfa başlığı, ince bölüm (18 · 300).
  static final TextStyle pageTitleThin = of(size: SenseFontSize.pageTitle, weight: SenseFontWeight.thin);

  /// Sayfa başlığı, kalın vurgu (18 · 600).
  static final TextStyle pageTitleBold = of(size: SenseFontSize.pageTitle, weight: SenseFontWeight.bold);
}

/// Scrollbar (YH T3, T7): thin, no track; 10 px area, 4 px thumb, 6 px on hover.
ScrollbarThemeData senseScrollbarTheme() {
  const margin = (SenseSizes.scrollbarArea - SenseSizes.scrollbarThumb) / 2;
  return ScrollbarThemeData(
    thickness: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.hovered) || states.contains(WidgetState.dragged)
            ? SenseSizes.scrollbarThumbHover
            : SenseSizes.scrollbarThumb),
    // Token gap: the prototype thumb is #2A2A33 / #4A4A56; nearest tokens are used.
    thumbColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.hovered) || states.contains(WidgetState.dragged)
            ? SenseColors.lineStrong
            : SenseColors.line),
    trackVisibility: const WidgetStatePropertyAll(false),
    trackColor: const WidgetStatePropertyAll(Colors.transparent),
    trackBorderColor: const WidgetStatePropertyAll(Colors.transparent),
    radius: const Radius.circular(SenseSizes.scrollbarArea),
    crossAxisMargin: margin,
    mainAxisMargin: SenseUi.scrollbarMainMargin,
    minThumbLength: SenseUi.scrollbarMinThumb,
    interactive: true,
  );
}

/// The Sense theme. Pass it as both `theme` and `darkTheme`, with [kSenseThemeMode].
ThemeData senseTheme() {
  const scheme = ColorScheme.dark(
    primary: SenseColors.text,
    onPrimary: SenseColors.bg,
    secondary: SenseColors.text,
    onSecondary: SenseColors.bg,
    surface: SenseColors.surface,
    onSurface: SenseColors.text,
    error: SenseColors.hot,
    onError: SenseColors.text,
    outline: SenseColors.line,
    outlineVariant: SenseColors.line,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: SenseFont.family,
  );
  return base.copyWith(
    scaffoldBackgroundColor: SenseColors.bg,
    canvasColor: SenseColors.bg,
    cardColor: SenseColors.surface,
    dialogBackgroundColor: SenseColors.surface,
    hoverColor: SenseColors.hover,
    focusColor: SenseColors.hover,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
    dividerColor: SenseColors.line,
    disabledColor: SenseColors.textDim,
    textTheme: base.textTheme.apply(
      fontFamily: SenseFont.family,
      bodyColor: SenseColors.text,
      displayColor: SenseColors.text,
    ),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: SenseFont.family),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: SenseColors.text,
      selectionColor: SenseColors.glowEnd,
      selectionHandleColor: SenseColors.text,
    ),
    scrollbarTheme: senseScrollbarTheme(),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.button),
      ),
      textStyle: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textSecondary),
      waitDuration: SenseMotion.layerFadeLong.duration,
    ),
    dividerTheme: const DividerThemeData(color: SenseColors.line, thickness: 1, space: 1),
  );
}
