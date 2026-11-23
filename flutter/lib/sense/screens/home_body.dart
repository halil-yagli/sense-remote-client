// Sense Remote: the body of the main window's home tab for a Sense role (Host,
// Controller, Host + Controller): the Sense shell over the whole tab, the stock
// status widget mounted but hidden (it refreshes `stateGlobal.svcStatus`).
//
// The Stack fills its space (`StackFit.expand`): its only non-positioned child
// is the Offstage status widget, which is 0 × 0 under the loose constraints of
// `buildRemoteBlock`'s Stack. A loose Stack would size itself to that 0 × 0 and
// `Positioned.fill` would give the shell no room: the body stayed black
// (Sürüm 4, Windows and macOS).
import 'package:flutter/widgets.dart';

Widget senseHomeBody({required Widget status, required Widget shell}) => Stack(
      fit: StackFit.expand,
      children: [
        Offstage(child: status),
        Positioned.fill(child: shell),
      ],
    );
