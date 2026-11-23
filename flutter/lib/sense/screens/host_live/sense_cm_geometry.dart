// Sense Remote: geometry of the Host-side Sense icon (YH H3, H4; prototype
// SENSE-REMOTE_PROTOTIP.html `#hico`, `.hedge`, `#hside`). Pure functions only,
// so the placement rules are covered by unit tests without a real window.
//
// All rectangles are in the same unit: physical pixels on Windows and points
// on macOS, which is what `window_size` reports for monitors there.

import 'dart:math' as math;
import 'dart:ui';

import '../../tokens/sense_tokens.dart';

/// Logical size of the collapsed icon window: the 64 × 64 area of the
/// transparent logo (`.chatico`), no plate, no frame (#4).
const Size kSenseCmIconSize = Size(SenseSizes.chatIcon, SenseSizes.chatIcon);

/// Logical size of the open card (H4): popup width, room for the strips, the
/// call row and a few messages. Smaller work areas clamp it.
const Size kSenseCmPanelSize = Size(SenseSizes.popupWidth, 680);

/// Logical gap between the icon and the edge of the work area (prototype 14).
const double kSenseCmMargin = 14;

/// Edge tab (H3 "Kenara saklı", `.hedge`): 18 × 52, 24 wide under the mouse.
/// The window is the hover width so the tab can grow inside it.
const double kSenseCmEdgeTabWidth = 18;
const Size kSenseCmEdgeSize = Size(24, 52);

/// An icon dropped this close to the left or right edge of its work area goes
/// to the edge as a tab.
const double kSenseCmEdgeSnap = 12;

/// The tab sits a little lower than the icon was (`HS.ey = HS.ico.y + 6`) and
/// the icon comes back this far from the edge (`HS.ico.x = 18`).
const double kSenseCmEdgeTopShift = 6;
const double kSenseCmEdgeInset = 18;

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

/// Corner radius of the Windows click region around the icon: the clear
/// corners of the 64 × 64 area outside it let clicks through; the unread badge
/// (top left) and the dots stay inside it.
const double kSenseCmIconRegionRadius = 16;

/// Which screen edge holds the tab.
enum SenseCmEdge { left, right }

/// The edge an icon at [icon] was dropped on, or null when it is not close to
/// one (H3: "ekran kenarına bırakınca saklanır").
SenseCmEdge? senseCmEdgeFor(Rect icon, Rect workArea, double snap) {
  if (icon.left <= workArea.left + snap) return SenseCmEdge.left;
  if (icon.right >= workArea.right - snap) return SenseCmEdge.right;
  return null;
}

/// Window rectangle of the edge tab for an icon dropped at [icon].
Rect senseCmEdgeRect(
    Rect icon, Rect workArea, SenseCmEdge edge, Size tab, double topShift) {
  final left =
      edge == SenseCmEdge.left ? workArea.left : workArea.right - tab.width;
  return clampSenseCmRect(
      Rect.fromLTWH(left, icon.top + topShift, tab.width, tab.height),
      workArea);
}

/// Icon rectangle when the tab at [tab] is pressed: back beside the edge, at
/// the height it was hidden from.
Rect senseCmIconFromEdge(Rect tab, Rect workArea, SenseCmEdge edge, Size icon,
    double inset, double topShift) {
  final left = edge == SenseCmEdge.left
      ? workArea.left + inset
      : workArea.right - inset - icon.width;
  return clampSenseCmRect(
      Rect.fromLTWH(left, tab.top - topShift, icon.width, icon.height),
      workArea);
}

/// Sense Remote: icon mode per platform. Win7 compatible mode keeps a normal
/// title bar, where a 64 px window would not fit, so it keeps the old window.
bool senseCmEnabledOn(
    {required bool windows, required bool macOS, required bool compatibleUi}) {
  return macOS || (windows && !compatibleUi);
}

/// Sense Remote: how many window units one logical pixel is. Windows places
/// windows in physical pixels; macOS in points, which already are logical
/// (a Retina screen reports scale 2 but a 64 pt window is still 64 wide).
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
