// Sense Remote: the bar of the camera window (YH O6 "Kamerayı görüntüle"). The same 46 px
// black bar as the session (O1): Sense mark, computer name and a status line on the left,
// the camera choice in the middle when the computer has more than one, Bitir on the right.
// The camera image stays under the bar; the bar never covers it. Pure widget: the window
// glue (sense_camera_frame.dart) gives the values.
import 'package:flutter/material.dart';

import '../../components/button.dart';
import '../../components/segment.dart';
import '../../components/sense_mark.dart';
import '../../strings/session.dart';
import '../../tokens/sense_tokens.dart';
import '../../tokens/theme.dart';

typedef _S = SenseSessionStrings;

/// What the camera bar shows.
@immutable
class SenseCameraBarState {
  const SenseCameraBarState({
    required this.name,
    this.ready = false,
    this.cameras = 0,
    this.current = 0,
    this.relay,
  });

  final String name;

  /// The computer answered (camera list known).
  final bool ready;
  final int cameras;
  final int current;

  /// True relay, false direct, null not known yet.
  final bool? relay;

  /// "Kamera 1 · Doğrudan", "Kamera bağlanıyor…", "Kamera bulunamadı".
  String get line {
    if (!ready) return _S.cameraConnecting;
    if (cameras <= 0) return _S.cameraNone;
    final path = relay == null ? null : (relay! ? _S.relay : _S.direct);
    final cam = _S.cameraN(current + 1);
    return path == null ? cam : '$cam · $path';
  }

  /// Camera choice only with more than one camera.
  bool get showChoice => ready && cameras > 1;
}

class SenseCameraBar extends StatelessWidget {
  const SenseCameraBar({
    super.key,
    required this.state,
    required this.onPick,
    required this.onEnd,
    this.onDragStart,
    this.onDoubleTap,
  });

  final SenseCameraBarState state;
  final ValueChanged<int>? onPick;
  final VoidCallback onEnd;
  final VoidCallback? onDragStart;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final left = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: SenseColors.line))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const SenseMark(width: 26, height: 24),
        const SizedBox(width: 10),
        Flexible(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SenseTextStyles.of(weight: SenseFontWeight.bold, height: 1.2)),
            Text(s.line,
                key: const ValueKey('sense-camera-line'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted, height: 1.2)),
          ]),
        ),
      ]),
    );
    final choice = s.showChoice
        ? ConstrainedBox(
            key: const ValueKey('sense-camera-choice'),
            constraints: const BoxConstraints(maxWidth: 420),
            child: SenseSegment<int>(
              expand: false,
              semanticLabel: _S.cameraWindow,
              options: [
                for (var i = 0; i < s.cameras; i++) SenseSegmentOption(value: i, label: _S.cameraN(i + 1)),
              ],
              value: s.current,
              onChanged: onPick,
            ),
          )
        : const SizedBox.shrink();
    final right = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(border: Border(left: BorderSide(color: SenseColors.line))),
      child: SenseButton(
        key: const ValueKey('sense-camera-end'),
        label: _S.end,
        tooltip: _S.cameraEndTooltip,
        kind: SenseButtonKind.danger,
        onPressed: onEnd,
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: onDragStart == null ? null : (_) => onDragStart!(),
      onDoubleTap: onDoubleTap,
      child: Container(
        key: const ValueKey('sense-camera-bar'),
        height: SenseSizes.sessionToolbarHeight,
        decoration: const BoxDecoration(
          color: SenseColors.bg,
          border: Border(bottom: BorderSide(color: SenseColors.line)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Flexible(child: left),
          Expanded(child: Center(child: choice)),
          right,
        ]),
      ),
    );
  }
}
