// Sense Remote: app theme of an installed Sense computer (design review T3-2,
// T3-7). Once a role is installed (Host, Controller, Host + Controller) the
// app is always dark: black surfaces, white accent instead of RustDesk's blue,
// Poppins (bundled, see pubspec.yaml). Not installed (portable run) keeps the
// stock theme and the user's theme choice.

import 'package:flutter/material.dart';

import '../common.dart' show MyTheme;
import '../models/platform_model.dart';
import '../sense/tokens/sense_tokens.dart';

/// Bundled font family (flutter/assets/fonts, SIL OFL 1.1).
const kSenseFont = 'Poppins';

/// Pure: an installed Sense role is applied as hard settings at start
/// (`src/sense.rs` role settings): Host = incoming only, Controller = outgoing
/// only, Host + Controller = locked settings.
bool senseRoleInstalledFrom(
        {required bool incomingOnly,
        required bool outgoingOnly,
        required bool settingsDisabled}) =>
    incomingOnly || outgoingOnly || settingsDisabled;

/// Reads the role settings of this computer.
bool senseRoleInstalled() {
  try {
    return senseRoleInstalledFrom(
        incomingOnly: bind.isIncomingOnly(),
        outgoingOnly: bind.isOutgoingOnly(),
        settingsDisabled: bind.isDisableSettings());
  } catch (_) {
    // Before the native side is ready: keep the stock behaviour.
    return false;
  }
}

/// Pure: the Sense dark theme on top of RustDesk's dark theme (keeps its
/// extensions and component sizes, swaps colors and the font).
ThemeData senseDarkTheme(ThemeData base) {
  return base.copyWith(
    scaffoldBackgroundColor: SenseColors.bg,
    canvasColor: SenseColors.bg,
    cardColor: SenseColors.surface,
    dialogBackgroundColor: SenseColors.surface,
    hoverColor: SenseColors.hover,
    dividerColor: SenseColors.line,
    colorScheme: base.colorScheme.copyWith(
      primary: SenseColors.text,
      onPrimary: SenseColors.bg,
      secondary: SenseColors.text,
      onSecondary: SenseColors.bg,
      // Many stock pages paint `colorScheme.background` (deprecated, still read).
      // ignore: deprecated_member_use
      background: SenseColors.bg,
    ),
    textTheme: base.textTheme.apply(fontFamily: kSenseFont),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: kSenseFont),
    textSelectionTheme: const TextSelectionThemeData(
        cursorColor: SenseColors.text, selectionColor: SenseColors.glowEnd),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: SenseColors.text,
        foregroundColor: SenseColors.bg,
        disabledForegroundColor: Colors.white38,
        disabledBackgroundColor: Colors.white10,
        textStyle: const TextStyle(
            fontFamily: kSenseFont, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: SenseColors.bg,
        foregroundColor: SenseColors.text,
        side: const BorderSide(color: SenseColors.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    menuBarTheme: const MenuBarThemeData(
        style: MenuStyle(backgroundColor: MaterialStatePropertyAll(SenseColors.bg))),
    // Sürüm 12 (#162, ST 0): stock boxes that still open (fallback) wear the Sense frame —
    // surface, 1 px line, 12 px corners, Poppins 13/600 title, white accent, no blue.
    dialogTheme: DialogTheme(
      backgroundColor: SenseColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SenseRadii.popup),
        side: const BorderSide(color: SenseColors.line),
      ),
      titleTextStyle: const TextStyle(
          fontFamily: kSenseFont,
          fontSize: SenseFontSize.popupTitle,
          fontWeight: SenseFontWeight.bold,
          color: SenseColors.text),
      contentTextStyle: const TextStyle(
          fontFamily: kSenseFont,
          fontSize: SenseFontSize.bodySmall,
          color: SenseColors.textSecondary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: SenseColors.bg,
      hintStyle: const TextStyle(
          fontFamily: kSenseFont,
          fontSize: SenseFontSize.bodySmall,
          color: SenseColors.textMuted),
      labelStyle: const TextStyle(
          fontFamily: kSenseFont, color: SenseColors.textMuted),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SenseRadii.button),
          borderSide: const BorderSide(color: SenseColors.line)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SenseRadii.button),
          borderSide: const BorderSide(color: SenseColors.textDim)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SenseRadii.button),
          borderSide: const BorderSide(color: SenseColors.dangerText)),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SenseRadii.button),
          borderSide: const BorderSide(color: SenseColors.line)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: SenseColors.text,
        textStyle: const TextStyle(
            fontFamily: kSenseFont, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SenseRadii.button)),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: MaterialStateProperty.resolveWith((s) =>
          s.contains(MaterialState.selected) ? SenseColors.text : SenseColors.bg),
      checkColor: const MaterialStatePropertyAll(SenseColors.bg),
      side: const BorderSide(color: SenseColors.lineStrong),
    ),
    radioTheme: RadioThemeData(
      fillColor: MaterialStateProperty.resolveWith((s) =>
          s.contains(MaterialState.selected)
              ? SenseColors.text
              : SenseColors.lineStrong),
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: SenseColors.text),
  );
}

/// Dark theme of the app windows: the Sense theme on an installed computer,
/// RustDesk's dark theme otherwise.
ThemeData senseAppDarkTheme() => senseRoleInstalled()
    ? senseDarkTheme(MyTheme.darkTheme)
    : MyTheme.darkTheme;

/// Sense Remote: the stock RustDesk lines and links ("Powered by RustDesk",
/// "set up your own server") stay hidden (decision 2026-11-16: no RustDesk
/// emphasis; the AGPL notice is behind Hakkında → Açık kaynak lisansları).
const kSenseHideStockBranding = true;
