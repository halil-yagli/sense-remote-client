// Sense Remote: geometry of the Host-side connection icon (prototype
// Calisma/prototip/uygulama.html, screen 5). Pure functions only, so the
// placement rules are covered by unit tests without a real window.
//
// All rectangles are in the same unit: physical pixels on Windows and points
// on macOS, which is what `window_size` reports for monitors there.

import 'dart:math' as math;
import 'dart:ui';

/// Logical size of the collapsed icon window.
const Size kSenseCmIconSize = Size(52, 52);

/// Logical size of the open card (who is connected, permissions, chat, end).
const Size kSenseCmPanelSize = Size(328, 500);

/// Logical gap between the icon and the edge of the work area.
const double kSenseCmMargin = 16;

/// Local option that remembers where the user left the icon ("x,y", in the
/// window unit of the platform).
const String kSenseCmPositionOption = 'sense-cm-icon-pos';

/// Which corner of the icon the open card is pinned to. The card grows away
/// from the nearest screen corner, so it never leaves the work area.
class SenseCmAnchor {
  const SenseCmAnchor({required this.right, required this.bottom});

  final bool right;
  final bool bottom;

  static const bottomRight = SenseCmAnchor(right: true, bottom: true);

  @override
  bool operator ==(Object other) =>
      other is SenseCmAnchor && other.right == right && other.bottom == bottom;

  @override
  int get hashCode => Object.hash(right, bottom);

  @override
  String toString() => 'SenseCmAnchor(right: $right, bottom: $bottom)';
}

/// Default icon place: bottom right of the work area (above the task bar).
Rect senseCmDefaultIconRect(Rect workArea, Size icon, double margin) {
  return clampSenseCmRect(
      Rect.fromLTWH(workArea.right - margin - icon.width,
          workArea.bottom - margin - icon.height, icon.width, icon.height),
      workArea);
}

/// Moves [rect] inside [workArea] without resizing it (unless it is larger).
Rect clampSenseCmRect(Rect rect, Rect workArea) {
  final width = math.min(rect.width, workArea.width);
  final height = math.min(rect.height, workArea.height);
  final left =
      rect.left.clamp(workArea.left, workArea.right - width).toDouble();
  final top =
      rect.top.clamp(workArea.top, workArea.bottom - height).toDouble();
  return Rect.fromLTWH(left, top, width, height);
}

/// The corner the card is pinned to: the icon corner nearest the screen corner.
SenseCmAnchor senseCmAnchorFor(Rect icon, Rect workArea) {
  return SenseCmAnchor(
    right: icon.center.dx >= workArea.center.dx,
    bottom: icon.center.dy >= workArea.center.dy,
  );
}

/// Card rectangle opened from [icon]: shares the anchored corner with the
/// icon, so the card opens "out of" the icon and closes back into it.
Rect senseCmPanelRect(
    Rect icon, Size panel, Rect workArea, SenseCmAnchor anchor) {
  final left = anchor.right ? icon.right - panel.width : icon.left;
  final top = anchor.bottom ? icon.bottom - panel.height : icon.top;
  return clampSenseCmRect(
      Rect.fromLTWH(left, top, panel.width, panel.height), workArea);
}

/// Icon rectangle when the card at [panel] closes: back into the same corner.
Rect senseCmIconRectFromPanel(
    Rect panel, Size icon, Rect workArea, SenseCmAnchor anchor) {
  final left = anchor.right ? panel.right - icon.width : panel.left;
  final top = anchor.bottom ? panel.bottom - icon.height : panel.top;
  return clampSenseCmRect(
      Rect.fromLTWH(left, top, icon.width, icon.height), workArea);
}

/// Sense Remote: icon mode per platform. Win7 compatible mode keeps a normal
/// title bar, where a 52 px window would not fit, so it keeps the old window.
bool senseCmEnabledOn(
    {required bool windows, required bool macOS, required bool compatibleUi}) {
  return macOS || (windows && !compatibleUi);
}

/// Sense Remote: how many window units one logical pixel is. Windows places
/// windows in physical pixels; macOS in points, which already are logical
/// (a Retina screen reports scale 2 but a 52 pt window is still 52 wide).
double senseCmUnitScale(
    {required bool pointUnits, required double scaleFactor}) {
  return pointUnits ? 1.0 : scaleFactor;
}

/// Sense Remote (macOS): `window_size` measures y from the top of the highest
/// screen, `window_manager` from the top of the primary screen. They differ
/// when another screen is arranged above the primary one; the difference is
/// the `window_size` top of the primary screen (the first one in the list,
/// `NSScreen.screens[0]`).
double senseCmMacTopOffset(List<Rect> screenFrames) =>
    screenFrames.isEmpty ? 0 : screenFrames.first.top;

/// Sense Remote (macOS): a `window_size` rectangle in `window_manager`
/// coordinates (see [senseCmMacTopOffset]).
Rect senseCmMacRect(Rect rect, double topOffset) =>
    rect.shift(Offset(0, -topOffset));

/// Sense Remote: (work area, unit scale) of every monitor in the coordinates
/// `window_manager` places windows in, primary monitor first. [screens] is
/// what `window_size` reports: (frame, visible frame, scale factor). On macOS
/// the visible frame already leaves out the menu bar and the Dock.
List<(Rect, double)> senseCmWorkAreas(List<(Rect, Rect, double)> screens,
    {required bool macOS}) {
  final offset =
      macOS ? senseCmMacTopOffset(screens.map((s) => s.$1).toList()) : 0.0;
  final list = [
    for (final (frame, visible, scale) in screens)
      (
        macOS ? senseCmMacRect(frame, offset) : frame,
        macOS ? senseCmMacRect(visible, offset) : visible,
        senseCmUnitScale(pointUnits: macOS, scaleFactor: scale),
      )
  ];
  // The primary monitor is the one at the origin.
  list.sort((a, b) => (a.$1.topLeft == Offset.zero ? 0 : 1)
      .compareTo(b.$1.topLeft == Offset.zero ? 0 : 1));
  return list.map((s) => (s.$2, s.$3)).toList();
}

/// Parses the stored "x,y" position; null when missing or malformed.
Offset? parseSenseCmPosition(String? value) {
  if (value == null) return null;
  final parts = value.split(',');
  if (parts.length != 2) return null;
  final x = double.tryParse(parts[0].trim());
  final y = double.tryParse(parts[1].trim());
  if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
  return Offset(x, y);
}

String formatSenseCmPosition(Offset position) =>
    '${position.dx.round()},${position.dy.round()}';

/// Picks the work area that should hold the icon: the one containing the
/// remembered position if any, otherwise [fallback]. A remembered position on
/// a monitor that is gone falls back to the default corner.
Rect? senseCmWorkAreaFor(Offset? remembered, List<Rect> workAreas) {
  if (remembered == null) return null;
  for (final area in workAreas) {
    if (area.contains(remembered)) return area;
  }
  return null;
}

/// "03:42", or "1:03:42" past an hour.
String formatSenseCmDuration(Duration duration) {
  final total = duration.isNegative ? 0 : duration.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}
