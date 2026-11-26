// Sense Remote: the one place right-side popups are shown (YH T7: "aynı anda
// tek popup"). Opening a popup closes the one before; the popup sits 10 px from
// the top-right corner (the chat from the bottom-right), at the popup width of
// the window (T3: 440 / 400 / 370) and ends at least 32 px above the bottom.
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../diag_log.dart';
import '../tokens/sense_tokens.dart';
import 'popup_shell.dart';

/// Which corner a popup is pinned to.
enum SensePopupPlacement {
  /// Status, display, lists: under the toolbar on the right; grows down.
  topRight,

  /// Chat: bottom right, above the Sense icon; grows up.
  bottomRight,
}

/// Holds the one open popup. Screens call [open], [toggle] and [close].
class SensePopupController extends ChangeNotifier {
  String? _id;
  WidgetBuilder? _builder;
  SensePopupPlacement _placement = SensePopupPlacement.topRight;
  int _generation = 0;

  /// Id of the open popup, or null.
  String? get openId => _id;
  bool get isOpen => _id != null;
  bool isOpenWith(String id) => _id == id;
  SensePopupPlacement get placement => _placement;
  WidgetBuilder? get builder => _builder;

  /// Bumps every time a popup is opened, so the opening animation replays.
  int get generation => _generation;

  /// Shows [builder] as the only popup; any other popup closes first.
  void open(String id, WidgetBuilder builder,
      {SensePopupPlacement placement = SensePopupPlacement.topRight}) {
    final same = _id == id;
    // Sense Remote (karar #103): the one place popups open and close.
    if (!same) {
      if (_id != null) senseUiPopup(_id!, open: false);
      senseUiPopup(id, open: true);
    }
    _id = id;
    _builder = builder;
    _placement = placement;
    if (!same) _generation++;
    notifyListeners();
  }

  /// Opens [id], or closes it when it is already the open one (toolbar items).
  void toggle(String id, WidgetBuilder builder,
      {SensePopupPlacement placement = SensePopupPlacement.topRight}) {
    if (_id == id) {
      close();
    } else {
      open(id, builder, placement: placement);
    }
  }

  /// Closes the open popup; with [id], only when that one is open.
  void close([String? id]) {
    if (_id == null || (id != null && id != _id)) return;
    senseUiPopup(_id!, open: false);
    _id = null;
    _builder = null;
    notifyListeners();
  }
}

/// Lays [child] (the screen) and the open popup in one stack.
class SensePopupHost extends StatefulWidget {
  const SensePopupHost({
    super.key,
    required this.controller,
    required this.child,
    this.margin = defaultMargin,
    this.closeOnEscape = true,
    this.widthOverride,
  });

  final SensePopupController controller;
  final Widget child;

  /// Gap from the area's edges (prototype `.side{top:10px;right:10px}`).
  final double margin;
  final bool closeOnEscape;

  /// Fixed width (tests); otherwise [SenseLayout.popupWidth] of the window width.
  final double? widthOverride;

  static const double defaultMargin = 10;

  /// The nearest host's controller.
  static SensePopupController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_SensePopupScope>();
    assert(scope != null, 'SensePopupHost.of() called outside a SensePopupHost');
    return scope!.notifier!;
  }

  static SensePopupController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SensePopupScope>()?.notifier;

  @override
  State<SensePopupHost> createState() => _SensePopupHostState();
}

class _SensePopupHostState extends State<SensePopupHost> {
  @override
  Widget build(BuildContext context) {
    final windowWidth = MediaQuery.maybeSizeOf(context)?.width ?? SenseSizes.windowWidth;
    final popupWidth = widget.widthOverride ?? SenseLayout.popupWidth(windowWidth);
    return _SensePopupScope(
      notifier: widget.controller,
      child: CallbackShortcuts(
        bindings: {
          if (widget.closeOnEscape)
            const SingleActivator(LogicalKeyboardKey.escape): () => widget.controller.close(),
        },
        child: LayoutBuilder(builder: (context, constraints) {
          return Stack(fit: StackFit.expand, children: [
            Positioned.fill(child: widget.child),
            ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final c = widget.controller;
                final builder = c.builder;
                if (builder == null) return const SizedBox.shrink();
                final top = c.placement == SensePopupPlacement.topRight;
                final maxHeight = math.max(0.0, constraints.maxHeight -
                        widget.margin -
                        SenseSizes.popupBottomGap);
                final maxWidth = math.max(0.0, constraints.maxWidth - 2 * widget.margin);
                return Positioned(
                  key: const Key('sense-popup-slot'),
                  top: top ? widget.margin : null,
                  bottom: top ? null : SenseSizes.popupBottomGap,
                  right: widget.margin,
                  width: popupWidth < maxWidth ? popupWidth : maxWidth,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: KeyedSubtree(
                      key: ValueKey('sense-popup-${c.openId}-${c.generation}'),
                      child: _PopupDirection(
                        from: top ? SensePopupFrom.top : SensePopupFrom.bottom,
                        child: Builder(builder: builder),
                      ),
                    ),
                  ),
                );
              },
            ),
          ]);
        }),
      ),
    );
  }
}

class _SensePopupScope extends InheritedNotifier<SensePopupController> {
  const _SensePopupScope({required super.notifier, required super.child});
}

/// Tells a [SensePopupShell] inside the host which way to grow.
class _PopupDirection extends InheritedWidget {
  const _PopupDirection({required this.from, required super.child});

  final SensePopupFrom from;

  @override
  bool updateShouldNotify(_PopupDirection old) => old.from != from;
}

/// Growth direction of the host slot this context is in ([SensePopupFrom.top] outside a host).
SensePopupFrom sensePopupFromOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_PopupDirection>()?.from ?? SensePopupFrom.top;
