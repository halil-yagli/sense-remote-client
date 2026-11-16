// Sense Remote: geometry of the Host-side connection icon (prototype
// Calisma/prototip/uygulama.html, screen 5). Pure functions only, so the
// placement rules are covered by unit tests without a real window.
//
// All rectangles are in the same unit (physical pixels on Windows, which is
// what `window_size` reports for monitors).

import 'dart:math' as math;
import 'dart:ui';

/// Logical size of the collapsed icon window.
const Size kSenseCmIconSize = Size(52, 52);

/// Logical size of the open card (who is connected, permissions, chat, end).
const Size kSenseCmPanelSize = Size(328, 500);

/// Logical gap between the icon and the edge of the work area.
const double kSenseCmMargin = 16;

/// Local option that remembers where the user left the icon ("x,y", physical).
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
