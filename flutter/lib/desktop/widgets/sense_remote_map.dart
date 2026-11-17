// Sense Remote: mini map of the remote computer's real display arrangement
// (the Windows/macOS layout, from PeerInfo.displays x/y/width/height). Click a
// display to view it, "Tümü" to view all of them in their arrangement.
// Prototype: Calisma/prototip/uygulama.html, screen 4 (.dmap).

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../consts.dart' show kAllDisplayValue;
import '../pages/sense_cm_style.dart';
import 'sense_remote_strings.dart';

/// One display as RustDesk reports it (DisplayInfo, desktop coordinates).
class SenseMapDisplay {
  const SenseMapDisplay({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.primary = false,
  });

  final int index;
  final double x;
  final double y;
  final int width;
  final int height;
  final bool primary;
}

/// Fits the arrangement into [box] keeping its proportions and centres it.
/// Pure; returns one rect per display in input order. Displays with a zero or
/// negative size get an empty rect at the origin (never seen in practice).
List<Rect> senseMapLayout(List<SenseMapDisplay> displays, Size box,
    {double pad = 3, double gap = 1}) {
  final valid = displays.where((d) => d.width > 0 && d.height > 0).toList();
  if (valid.isEmpty) return displays.map((_) => Rect.zero).toList();
  final x0 = valid.map((d) => d.x).reduce(math.min);
  final y0 = valid.map((d) => d.y).reduce(math.min);
  final x1 = valid.map((d) => d.x + d.width).reduce(math.max);
  final y1 = valid.map((d) => d.y + d.height).reduce(math.max);
  final bw = x1 - x0;
  final bh = y1 - y0;
  final k = math.min((box.width - pad * 2) / bw, (box.height - pad * 2) / bh);
  final ox = (box.width - bw * k) / 2;
  final oy = (box.height - bh * k) / 2;
  return displays.map((d) {
    if (d.width <= 0 || d.height <= 0) return Rect.zero;
    final w = math.max(2.0, d.width * k - gap * 2);
    final h = math.max(2.0, d.height * k - gap * 2);
    return Rect.fromLTWH(ox + (d.x - x0) * k + gap, oy + (d.y - y0) * k + gap, w, h);
  }).toList();
}

/// "Ekran 1 · ana" — RustDesk index 0 is "Ekran 1".
String senseDisplayTitle(SenseMapDisplay d) {
  final base = '${senseRemoteText('display')} ${d.index + 1}';
  return d.primary ? '$base · ${senseRemoteText('primary')}' : base;
}

class SenseRemoteMap extends StatelessWidget {
  const SenseRemoteMap({
    super.key,
    required this.displays,
    required this.current,
    required this.onPick,
    this.size = const Size(112, 30),
  });

  final List<SenseMapDisplay> displays;

  /// RustDesk display index, or kAllDisplayValue.
  final int current;
  final ValueChanged<int> onPick;
  final Size size;

  @override
  Widget build(BuildContext context) {
    // The 1 px frame takes 2 px of each side length.
    final rects = senseMapLayout(
        displays, Size(size.width - 2, size.height - 2));
    final all = current == kAllDisplayValue;
    return Tooltip(
      message: senseRemoteText('map_tooltip'),
      child: Container(
        key: const ValueKey('sense-remote-map'),
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          color: SenseCmTokens.field,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFF23232C)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            for (var i = 0; i < displays.length; i++)
              Positioned.fromRect(
                rect: rects[i],
                child: _MapCell(
                  key: ValueKey('sense-remote-map-${displays[i].index}'),
                  display: displays[i],
                  selected: displays[i].index == current,
                  dim: all,
                  onTap: () => onPick(displays[i].index),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MapCell extends StatelessWidget {
  const _MapCell({
    super.key,
    required this.display,
    required this.selected,
    required this.dim,
    required this.onTap,
  });

  final SenseMapDisplay display;
  final bool selected;
  final bool dim;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? SenseCmTokens.white : SenseRemoteTokens.mapText;
    return Semantics(
      button: true,
      selected: selected,
      label: senseDisplayTitle(display),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? null
                  : dim
                      ? SenseRemoteTokens.mapText.withOpacity(0.35)
                      : SenseRemoteTokens.mapCell,
              gradient: selected ? SenseCmTokens.gradient : null,
              borderRadius: BorderRadius.circular(3),
              border: selected ? Border.all(color: SenseCmTokens.white) : null,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.all(1),
                child: Text('${display.index + 1}',
                    style: SenseCmTokens.text(
                        size: 9, weight: FontWeight.w600, color: fg)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Map + "Tümü" for the toolbar. "Tümü" only when there is more than one
/// display. [vertical] stacks them for a toolbar docked on the left/right.
class SenseRemoteMapBar extends StatelessWidget {
  const SenseRemoteMapBar({
    super.key,
    required this.displays,
    required this.current,
    required this.onPick,
    this.vertical = false,
    this.allowAll = true,
  });

  final List<SenseMapDisplay> displays;
  final int current;
  final ValueChanged<int> onPick;
  final bool vertical;

  /// The peer can show all displays at once (RustDesk multi-display support).
  final bool allowAll;

  @override
  Widget build(BuildContext context) {
    final map = SenseRemoteMap(
      displays: displays,
      current: current,
      onPick: onPick,
      size: vertical ? const Size(44, 44) : const Size(112, 30),
    );
    final children = <Widget>[
      map,
      if (allowAll && displays.length > 1)
        SenseRemoteChip(
          key: const ValueKey('sense-remote-all'),
          label: senseRemoteText('all'),
          selected: current == kAllDisplayValue,
          onTap: () => onPick(kAllDisplayValue),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Flex(
        direction: vertical ? Axis.vertical : Axis.horizontal,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 6, height: 6),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// Small text button in the toolbar ("Tümü").
class SenseRemoteChip extends StatelessWidget {
  const SenseRemoteChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? SenseCmTokens.white : SenseCmTokens.black,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
            color: selected ? SenseCmTokens.white : SenseCmTokens.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text(label,
              style: SenseCmTokens.text(
                  size: 11,
                  weight: FontWeight.w600,
                  color: selected ? SenseCmTokens.black : SenseCmTokens.white)),
        ),
      ),
    );
  }
}
