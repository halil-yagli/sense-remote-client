// Sense Remote: thin scrollbar without a track (YH T3, T7; prototype `::-webkit-scrollbar`).
// 10 px area, 4 px thumb (6 px on hover). Headers stay fixed: put only the body in it (#14).
import 'package:flutter/material.dart';

import '../tokens/theme.dart';

class SenseScrollbar extends StatelessWidget {
  const SenseScrollbar({super.key, required this.child, this.controller, this.thumbVisibility});

  final Widget child;
  final ScrollController? controller;

  /// Null = shown while scrolling or hovered (desktop default).
  final bool? thumbVisibility;

  @override
  Widget build(BuildContext context) => ScrollbarTheme(
        data: senseScrollbarTheme(),
        child: Scrollbar(
          controller: controller,
          thumbVisibility: thumbVisibility,
          trackVisibility: false,
          child: child,
        ),
      );
}

/// Scroll behaviour for the Sense app: the Sense scrollbar everywhere, no glow.
class SenseScrollBehavior extends MaterialScrollBehavior {
  const SenseScrollBehavior();

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    switch (axisDirectionToAxis(details.direction)) {
      case Axis.horizontal:
      case Axis.vertical:
        return SenseScrollbar(controller: details.controller, child: child);
    }
  }

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}
