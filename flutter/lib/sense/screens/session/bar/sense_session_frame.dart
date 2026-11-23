// Sense Remote: the session window frame (YH O1, O2, O7). The 46 px bar on top, the remote
// screen under it (the bar never covers it), the Sense island hanging from the bar's
// bottom edge, the 3 px navy → purple ghost line on top of the screen while ghost mode is
// on, and the open list hanging under its button. A tap outside the list closes it; a
// choice keeps it open and shows a short notification.
import 'package:flutter/material.dart';

import '../../../components/toast.dart';
import '../../../tokens/sense_tokens.dart';
import '../data/session_state.dart';
import '../island/sense_island.dart';
import '../lists/backend.dart';
import '../lists/list_specs.dart';
import '../lists/session_list.dart';
import 'sense_session_bar.dart';

/// Ghost mode line on top of the remote screen (prototype `.ghostline`).
const double kSenseGhostLineHeight = 3;

/// Space kept under an open list (T3 popup bottom gap is for popups; lists go further).
const double kSenseListBottomGap = 12;

class SenseSessionFrame extends StatefulWidget {
  const SenseSessionFrame({
    super.key,
    this.backend,
    this.popups,
    required this.child,
    this.menus,
    this.onDragStart,
    this.onDoubleTap,
  });

  /// Null while the selected tab's session is not built yet: the frame is drawn with an
  /// empty bar, in the same layout, so the remote page is never moved or rebuilt.
  final SenseSessionBackend? backend;
  final SenseBarPopups? popups;

  /// The remote screen.
  final Widget child;
  final SenseBarController? menus;
  final VoidCallback? onDragStart;
  final VoidCallback? onDoubleTap;

  @override
  State<SenseSessionFrame> createState() => _SenseSessionFrameState();
}

class _SenseSessionFrameState extends State<SenseSessionFrame> {
  SenseBarController? _own;
  SenseBarController get _menus => widget.menus ?? (_own ??= SenseBarController());
  final Map<SenseBarMenu, GlobalKey> _links = {for (final m in SenseBarMenu.values) m: GlobalKey()};
  final GlobalKey _area = GlobalKey();

  /// Left edge of [m]'s button in the frame, kept so the list stays on screen.
  double _anchorX(SenseBarMenu m, double width) {
    final button = _links[m]?.currentContext?.findRenderObject();
    final area = _area.currentContext?.findRenderObject();
    if (button is! RenderBox || area is! RenderBox || !button.attached || !area.attached) return 0;
    final x = button.localToGlobal(Offset.zero, ancestor: area).dx;
    return x.clamp(0.0, (width - kSenseListWidth).clamp(0.0, width)).toDouble();
  }
  SenseBarMenu? _lastOpen;

  @override
  void initState() {
    super.initState();
    _menus.addListener(_onMenus);
    widget.popups?.addListener(_onPopups);
  }

  @override
  void didUpdateWidget(SenseSessionFrame old) {
    super.didUpdateWidget(old);
    if (old.backend != widget.backend) _menus.close();
    if (old.popups != widget.popups) {
      old.popups?.removeListener(_onPopups);
      widget.popups?.addListener(_onPopups);
    }
  }

  @override
  void dispose() {
    _menus.removeListener(_onMenus);
    widget.popups?.removeListener(_onPopups);
    _own?.dispose();
    super.dispose();
  }

  void _onMenus() {
    final open = _menus.openMenu;
    if (open != null && open != _lastOpen) widget.backend?.refresh();
    if ((open == null) != (_lastOpen == null)) widget.popups?.onMenu(open != null);
    _lastOpen = open;
  }

  /// Another popup (chat, status) took the one place: the list closes (T7).
  void _onPopups() {
    final popups = widget.popups;
    if (popups != null && !popups.menuAllowed && _menus.openMenu != null) _menus.close();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.backend;
    final popups = widget.popups;
    return SenseToastHost(
      child: Builder(builder: (context) {
        return ListenableBuilder(
          listenable: Listenable.merge([if (b != null) b, _menus]),
          builder: (context, _) {
            final hidden = b?.barHidden ?? false;
            final motion = SenseMotion.toolbarHide;
            final open = _menus.openMenu;
            final Widget bar = b == null || popups == null
                ? const ColoredBox(key: ValueKey('sense-bar-empty'), color: SenseColors.bg)
                : SenseSessionBar(
                    backend: b,
                    menus: _menus,
                    popups: popups,
                    links: _links,
                    onDragStart: widget.onDragStart,
                    onDoubleTap: widget.onDoubleTap,
                  );
            return Stack(key: _area, children: [
              Column(children: [
                AnimatedContainer(
                  key: const ValueKey('sense-bar-slot'),
                  duration: motion.duration,
                  curve: motion.curve,
                  height: hidden ? 0 : SenseSizes.sessionToolbarHeight,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.bottomCenter,
                      minHeight: SenseSizes.sessionToolbarHeight,
                      maxHeight: SenseSizes.sessionToolbarHeight,
                      child: bar,
                    ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(builder: (context, c) {
                    return Stack(children: [
                      Positioned.fill(child: widget.child),
                      if (b != null && b.ghostOn)
                        const Positioned(
                          key: ValueKey('sense-ghost-line'),
                          top: 0,
                          left: 0,
                          right: 0,
                          height: kSenseGhostLineHeight,
                          child: IgnorePointer(
                            child: DecoratedBox(decoration: BoxDecoration(gradient: SenseGradients.glow)),
                          ),
                        ),
                      if (open != null && !hidden && b != null) ...[
                        Positioned.fill(
                          child: GestureDetector(
                            key: const ValueKey('sense-list-barrier'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _menus.close,
                          ),
                        ),
                        Positioned(
                          left: _anchorX(open, c.maxWidth),
                          top: 0,
                          child: SenseSessionList(
                              key: ValueKey('sense-list-${open.name}'),
                              spec: senseBuildList(open, b),
                              maxHeight: (c.maxHeight - kSenseListBottomGap).clamp(120.0, double.infinity),
                              onNotify: (m) => SenseToast.show(context, m),
                            ),
                        ),
                      ],
                    ]);
                  }),
                ),
              ]),
              AnimatedPositioned(
                duration: motion.duration,
                curve: motion.curve,
                top: hidden ? 0 : SenseSizes.sessionToolbarHeight - 1,
                left: 0,
                right: 0,
                // Prototype: the handle is not drawn while a list is open (it would sit on
                // the list's first rows).
                child: b == null || (open != null && !hidden)
                    ? const SizedBox.shrink(key: ValueKey('sense-island-gone'))
                    : Center(
                  child: SenseIsland(
                    barHidden: hidden,
                    onTap: () {
                      _menus.close();
                      b.toggleBar();
                    },
                  ),
                ),
              ),
            ]);
          },
        );
      }),
    );
  }
}
