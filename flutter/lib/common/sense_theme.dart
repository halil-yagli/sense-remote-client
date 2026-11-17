// Sense Remote: app theme of an installed Sense computer (design review T3-2,
// T3-7). Once a role is installed (Host, Controller, Host + Controller) the
// app is always dark: black surfaces, white accent instead of RustDesk's blue,
// Poppins (bundled, see pubspec.yaml). Not installed (portable run) keeps the
// stock theme and the user's theme choice.

import 'package:flutter/material.dart';

import '../common.dart' show MyTheme;
import '../models/platform_model.dart';

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

typedef _C = SenseThemeColors;

class SenseThemeColors {
  static const black = Color(0xFF000000);
  static const white = Color(0xFFFFFFFF);
  static const surface = Color(0xFF0A0A0E);
  static const raised = Color(0xFF15151B);
  static const line = Color(0xFF26262F);
  static const hover = Color(0xFF1D1D25);
  static const selection = Color(0xFF640164);
}

/// Pure: the Sense dark theme on top of RustDesk's dark theme (keeps its
/// extensions and component sizes, swaps colors and the font).
ThemeData senseDarkTheme(ThemeData base) {
  return base.copyWith(
    scaffoldBackgroundColor: _C.black,
    canvasColor: _C.black,
    cardColor: _C.surface,
    dialogBackgroundColor: _C.surface,
    hoverColor: _C.hover,
    dividerColor: _C.line,
    colorScheme: base.colorScheme.copyWith(
      primary: _C.white,
      onPrimary: _C.black,
      secondary: _C.white,
      onSecondary: _C.black,
      // Many stock pages paint `colorScheme.background` (deprecated, still read).
      // ignore: deprecated_member_use
      background: _C.black,
    ),
    textTheme: base.textTheme.apply(fontFamily: kSenseFont),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: kSenseFont),
    textSelectionTheme: const TextSelectionThemeData(
        cursorColor: _C.white, selectionColor: _C.selection),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: _C.white,
        foregroundColor: _C.black,
        disabledForegroundColor: Colors.white38,
        disabledBackgroundColor: Colors.white10,
        textStyle: const TextStyle(
            fontFamily: kSenseFont, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: _C.black,
        foregroundColor: _C.white,
        side: const BorderSide(color: _C.line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    menuBarTheme: const MenuBarThemeData(
        style: MenuStyle(backgroundColor: MaterialStatePropertyAll(_C.black))),
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
