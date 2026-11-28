import 'package:flutter/material.dart';

import '../../sense/tokens/sense_tokens.dart';

// Sense Remote (T1, ST 15): no stock blue; the Sense surfaces instead. The Sense
// secondary windows draw their own bar (sense/screens/shared/aux_window).
const sidebarColor = SenseColors.surface;
const backgroundStartColor = SenseColors.surface;
const backgroundEndColor = SenseColors.bg;

class DesktopTitleBar extends StatelessWidget {
  final Widget? child;

  const DesktopTitleBar({Key? key, this.child}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [backgroundStartColor, backgroundEndColor],
            stops: [0.0, 1.0]),
      ),
      child: Row(
        children: [
          Expanded(
            child: child ?? Offstage(),
          )
        ],
      ),
    );
  }
}