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
    required this.backend,
    required this.popups,
    required this.child,
    this.menus,
    this.onDragStart,
    this.onDoubleTap,
  });

  final SenseSessionBackend backend;
  final SenseBarPopups popups;

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
  final Map<SenseBarMenu, LayerLink> _links = {for (final m in SenseBarMenu.values) m: LayerLink()};
  SenseBarMenu? _lastOpen;

  @override
  void initState() {
    super.initState();
    _menus.addListener(_onMenus);
    widget.popups.addListener(_onPopups);
  }

  @override
  void didUpdateWidget(SenseSessionFrame old) {
    super.didUpdateWidget(old);
    if (old.popups != widget.popups) {
      old.popups.removeListener(_onPopups);
      widget.popups.addListener(_onPopups);
    }
  }

  @override
  void dispose() {
    _menus.removeListener(_onMenus);
    widget.popups.removeListener(_onPopups);
    _own?.dispose();
    super.dispose();
  }

  void _onMenus() {
    final open = _menus.openMenu;
    if (open != null && open != _lastOpen) widget.backend.refresh();
    if ((open == null) != (_lastOpen == null)) widget.popups.onMenu(open != null);
    _lastOpen = open;
  }

  /// Another popup (chat, status) took the one place: the list closes (T7).
  void _onPopups() {
    if (!widget.popups.menuAllowed && _menus.openMenu != null) _menus.close();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.backend;
    return SenseToastHost(
      child: Builder(builder: (context) {
        return ListenableBuilder(
          listenable: Listenable.merge([b, _menus]),
          builder: (context, _) {
            final hidden = b.barHidden;
            final motion = SenseMotion.toolbarHide;
            final open = _menus.openMenu;
            final bar = SenseSessionBar(
              backend: b,
              menus: _menus,
              popups: widget.popups,
              links: _links,
              onDragStart: widget.onDragStart,
              onDoubleTap: widget.onDoubleTap,
            );
            return Stack(children: [
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
                      if (b.ghostOn)
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
                      if (open != null && !hidden) ...[
                        Positioned.fill(
                          child: GestureDetector(
                            key: const ValueKey('sense-list-barrier'),
                            behavior: HitTestBehavior.opaque,
                            onTap: _menus.close,
                          ),
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          child: CompositedTransformFollower(
                            link: _links[open]!,
                            showWhenUnlinked: false,
                            targetAnchor: Alignment.bottomLeft,
                            followerAnchor: Alignment.topLeft,
                            offset: const Offset(0, -1),
                            child: SenseSessionList(
                              key: ValueKey('sense-list-${open.name}'),
                              spec: senseBuildList(open, b),
                              maxHeight: (c.maxHeight - kSenseListBottomGap).clamp(120.0, double.infinity),
                              onNotify: (m) => SenseToast.show(context, m),
                            ),
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
                child: Center(
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
