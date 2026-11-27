// Sense Remote: the small menu of the secondary windows (files, terminal, tunnel):
// tab menu, a file panel's "⋯" and right-click menu. Same look as the computer
// tile "⋯" menu (prototype `.pcmenu`): surface, line, 12 px corners, 8×10 rows.
// One menu at a time; a tap outside or Escape closes it.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../diag_log.dart';
import '../../../sense.dart';

/// One row of the menu. [onTap] null = drawn faded, not tappable.
class SenseAuxMenuItem {
  const SenseAuxMenuItem({required this.label, required this.onTap, this.danger = false, this.key});

  final String label;
  final VoidCallback? onTap;

  /// Red text (Sil).
  final bool danger;
  final Key? key;
}

const double _kMenuWidth = 210, _kPad = 6, _kItemV = 8, _kItemH = 10;

/// The menu box itself; also used by the goldens.
class SenseAuxMenuBox extends StatelessWidget {
  const SenseAuxMenuBox({super.key, required this.items, required this.onPicked});

  final List<SenseAuxMenuItem> items;

  /// Called before the item's own action (closes the menu).
  final VoidCallback onPicked;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _kMenuWidth,
      padding: const EdgeInsets.all(_kPad),
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.popup),
        boxShadow: [BoxShadow(color: SenseColors.bg.withOpacity(0.75), blurRadius: 50, offset: const Offset(0, 18))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            Opacity(
              opacity: item.onTap == null ? SenseUi.disabledOpacity : 1,
              child: SenseInteractive(
                key: item.key,
                onTap: item.onTap == null
                    ? null
                    : () {
                        onPicked();
                        senseUiButton(item.label, where: 'aux-menu');
                        item.onTap!();
                      },
                builder: (context, s) => Container(
                  padding: const EdgeInsets.symmetric(vertical: _kItemV, horizontal: _kItemH),
                  decoration: BoxDecoration(
                    color: s.hovered || s.focused ? SenseColors.hover : null,
                    borderRadius: BorderRadius.circular(SenseRadii.button),
                  ),
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SenseTextStyles.of(
                      size: SenseFontSize.bodySmall,
                      weight: SenseFontWeight.medium,
                      color: item.danger ? SenseColors.dangerText : SenseColors.text,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

OverlayEntry? _open;

/// Closes the open menu, if any.
void senseAuxMenuClose() {
  _open?.remove();
  _open = null;
}

/// Opens the menu at [globalPosition] (right click) inside the nearest overlay.
/// The menu stays inside the window: it opens left / up when there is no room.
void senseAuxMenuShow(BuildContext context, Offset globalPosition, List<SenseAuxMenuItem> items) {
  senseAuxMenuClose();
  if (items.isEmpty) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  final box = overlay.context.findRenderObject() as RenderBox?;
  final local = box == null ? globalPosition : box.globalToLocal(globalPosition);
  final size = box?.size ?? Size.infinite;
  final estHeight = items.length * (_kItemV * 2 + SenseFontSize.bodySmall * 1.5) + _kPad * 2;
  final left = local.dx + _kMenuWidth > size.width ? local.dx - _kMenuWidth : local.dx;
  final top = local.dy + estHeight > size.height ? local.dy - estHeight : local.dy;
  final entry = OverlayEntry(
    builder: (_) => _SenseAuxMenuLayer(
      left: left < 0 ? 0 : left,
      top: top < 0 ? 0 : top,
      items: items,
    ),
  );
  _open = entry;
  overlay.insert(entry);
}

/// Opens the menu under [anchor] (a "⋯" button), right edges aligned.
void senseAuxMenuShowBelow(BuildContext anchor, List<SenseAuxMenuItem> items) {
  final box = anchor.findRenderObject() as RenderBox?;
  if (box == null) return;
  final bottomRight = box.localToGlobal(box.size.bottomRight(Offset.zero));
  senseAuxMenuShow(anchor, bottomRight.translate(-_kMenuWidth, 4), items);
}

class _SenseAuxMenuLayer extends StatelessWidget {
  const _SenseAuxMenuLayer({required this.left, required this.top, required this.items});

  final double left;
  final double top;
  final List<SenseAuxMenuItem> items;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          senseAuxMenuClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: senseAuxMenuClose,
            onSecondaryTap: senseAuxMenuClose,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: SenseAuxMenuBox(items: items, onPicked: senseAuxMenuClose),
        ),
      ]),
    );
  }
}
