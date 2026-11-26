// Sense Remote (S7, #88, #89): pure size rules for windows that move between monitors with
// different scales. Windows resizes a window to the new monitor's scale when it crosses
// monitors (WM_DPICHANGED), so a size set in one call can end up scaled twice; callers set the
// bounds, read them back and set them again until [senseBoundsMatch] holds.

import 'dart:ui';

/// Largest number of times a window's bounds are set again after a scale change.
const int kSenseBoundsRetries = 3;

/// The window frame [got] is the asked-for frame [want] (a pixel of rounding is allowed).
bool senseBoundsMatch(Rect want, Rect got, {double tolerance = 2}) {
  return (want.left - got.left).abs() <= tolerance &&
      (want.top - got.top).abs() <= tolerance &&
      (want.width - got.width).abs() <= tolerance &&
      (want.height - got.height).abs() <= tolerance;
}

/// Logical size [logical] on a monitor with [scale] (physical pixels per logical pixel).
Size senseScaledSize(Size logical, double scale) =>
    scale > 0 ? logical * scale : logical;

/// Visible area of a monitor (physical pixels) in logical pixels; null for an unknown scale.
Size? senseLogicalVisible(Rect visibleFrame, double scale) =>
    scale > 0 ? Size(visibleFrame.width / scale, visibleFrame.height / scale) : null;

/// Sense Remote (#99): the window is where it was asked to be, and the Flutter view draws at
/// the size of the window's client area (frameless: the whole window). Physical pixels.
bool senseViewMatches(
    {required Rect want, required Rect window, required Size client, required Size flutter}) {
  return senseBoundsMatch(want, window) &&
      (client.width - window.width).abs() <= 2 &&
      (client.height - window.height).abs() <= 2 &&
      (flutter.width - client.width).abs() <= 2 &&
      (flutter.height - client.height).abs() <= 2;
}
