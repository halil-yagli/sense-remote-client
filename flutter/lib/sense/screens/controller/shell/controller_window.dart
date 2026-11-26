// Sense Remote (Y2; yol haritası T3, T9): the Controller main window opens at
// 1180 × 720 (SenseSizes.window*), like the Host window (#36), and never bigger
// than the visible part of the screen it opens on. The Host and setup windows
// keep their own sizing.
import 'dart:ui' show Size;

import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

import '../../../tokens/sense_tokens.dart' show SenseSizes;
import '../sense_home_strings.dart' show SenseHomeRole;

/// Only Controller windows ("giden" and "çift yönlü") get this size; Host, the
/// stock home (no Sense role) and everything else are left alone.
bool senseControllerWindowApplies(SenseHomeRole role) =>
    role == SenseHomeRole.controller || role == SenseHomeRole.both;

/// 1180 × 720 trimmed to the visible area ([visibleWidth] × [visibleHeight], in
/// logical pixels; 0 or less = unknown, ignored). A tiny sliver of screen never
/// makes the window smaller than 1024 × 600.
Size senseControllerWindowSize({double visibleWidth = 0, double visibleHeight = 0}) {
  var w = SenseSizes.windowWidth, h = SenseSizes.windowHeight;
  if (visibleWidth > 0 && visibleWidth < w) w = visibleWidth;
  if (visibleHeight > 0 && visibleHeight < h) h = visibleHeight;
  return Size(w < 1024 ? 1024 : w, h < 600 ? 600 : h);
}

/// Sets the size and centres the window. The visible frame is divided by the
/// screen's scale factor, so mixed-DPI setups get logical pixels of the screen
/// the window is on (same as the Host window).
Future<void> senseSizeControllerWindow() async {
  double vw = 0, vh = 0;
  try {
    final screen = await window_size.getCurrentScreen();
    if (screen != null && screen.scaleFactor > 0) {
      vw = screen.visibleFrame.width / screen.scaleFactor;
      vh = screen.visibleFrame.height / screen.scaleFactor;
    }
  } catch (_) {}
  await windowManager.setSize(senseControllerWindowSize(visibleWidth: vw, visibleHeight: vh));
  await windowManager.center();
}
