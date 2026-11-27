// Sense Remote: the layers of one connection window, placed over everything in
// remote_page.dart (the top bar and popups included, YH O13 "her şeyin üstüne").
// While nothing is up the widget takes no clicks.
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import 'data/session_hub.dart';
import 'layer_controller.dart';
import 'layer_strings.dart';
import 'layer_spec.dart';
import 'layer_views.dart';
import 'link_machine.dart';

class SenseSessionLayers extends StatefulWidget {
  const SenseSessionLayers({
    super.key,
    required this.id,
    required this.controller,
    this.stripTop = SenseSizes.sessionToolbarHeight,
    this.listenToInput = true,
    this.shrinkTo,
  });

  /// Where the weak card shrinks to: the logo area of the bar (window coordinates).
  final Offset? shrinkTo;

  /// Connection tab key (peer id).
  final String id;
  final SenseLayerController controller;

  /// The idle strip sits right under the top bar.
  final double stripTop;

  /// Mouse and keyboard anywhere in the window count as activity (O15).
  final bool listenToInput;

  @override
  State<SenseSessionLayers> createState() => _SenseSessionLayersState();
}

class _SenseSessionLayersState extends State<SenseSessionLayers>
    with SingleTickerProviderStateMixin {
  // 0 = card open, 1 = shrunk into the bar (karar #94, ~250 ms, ease).
  late final AnimationController _shrink =
      AnimationController(vsync: this, duration: SenseLinkTiming.shrink);
  late final Animation<double> _shrinkCurve =
      CurvedAnimation(parent: _shrink, curve: SenseCurves.ease);
  bool _wasMinimized = false;

  final SenseToastController _toast = SenseToastController();
  int _recoveredSeen = 0;

  SenseLayerController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _recoveredSeen = _c.recoveredSerial;
    _wasMinimized = _c.minimized;
    _shrink.value = _wasMinimized ? 1 : 0;
    _shrink.addListener(_repaint);
    _c.addListener(_changed);
    SenseLayerController.attach(widget.id, _c);
    SenseSessionHub.register(widget.id, _c.onMessage);
    if (widget.listenToInput) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      HardwareKeyboard.instance.addHandler(_onKey);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    SenseLayerController.detach(widget.id, _c);
    SenseSessionHub.unregister(widget.id, _c.onMessage);
    if (widget.listenToInput) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    _shrink.dispose();
    _toast.dispose();
    super.dispose();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerMoveEvent ||
        e is PointerHoverEvent ||
        e is PointerDownEvent ||
        e is PointerScrollEvent) {
      _c.activity();
    }
  }

  bool _onKey(KeyEvent e) {
    _c.activity();
    return false;
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _syncShrink() {
    final now = _c.minimized;
    if (now == _wasMinimized) return;
    _wasMinimized = now;
    final off = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (off) {
      _shrink.value = now ? 1 : 0;
    } else if (now) {
      _shrink.forward();
    } else {
      _shrink.reverse();
    }
  }

  void _changed() {
    _syncShrink();
    if (_c.recoveredSerial != _recoveredSeen) {
      _recoveredSeen = _c.recoveredSerial;
      _toast.show(SenseLayerStrings.recovered);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ended = _c.ended;
    final link = _c.link;
    final idle = _c.idle;
    Widget Function(double appear)? layer;
    if (ended != null) {
      layer = (t) => SenseEndedLayer(
            summary: ended,
            backHomeIn: _c.backHomeIn,
            reconnect: _c.reconnectState,
            onClose: _c.closeEnded,
            onReconnect: _c.reconnectEnded,
            appear: t,
          );
    } else if (link.layerUp && (_shrink.value < 1 || !_c.minimized)) {
      final lost = link.phase == SenseLinkPhase.lost;
      layer = (t) => SenseLinkLayer(
            view: link,
            onEnd: _c.endByUser,
            onMinimize: lost ? null : _c.minimize,
            appear: t,
            shrink: lost ? 0 : _shrinkCurve.value,
            shrinkTo: widget.shrinkTo ?? Offset(40, widget.stripTop / 2),
          );
    } else if (_c.infoOpen) {
      // Sürüm 10 (#110): the card opened from the logo area while the link is good.
      layer = (t) => SenseLinkInfoLayer(view: link, direct: _c.direct, onClose: _c.closeInfo, appear: t);
    }
    return SenseToastHost(
      controller: _toast,
      child: Stack(
        children: [
          if (idle.warning && ended == null)
            Positioned(
              top: widget.stripTop,
              left: 0,
              right: 0,
              child: SenseIdleStrip(secondsLeft: idle.secondsLeft, onContinue: _c.keepGoing),
            ),
          if (layer != null)
            Positioned.fill(
              // Weak → lost keeps the layer (no second fade); ended fades in anew.
              child: _FadeIn(key: ValueKey(ended != null ? 'ended' : (_c.infoOpen ? 'info' : 'link')), builder: layer),
            ),
        ],
      ),
    );
  }
}

/// Layer appearance (YH T4 "Katman belirmesi").
class _FadeIn extends StatelessWidget {
  const _FadeIn({super.key, required this.builder});

  final Widget Function(double appear) builder;

  @override
  Widget build(BuildContext context) {
    final off = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (off) return builder(1);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: SenseMotion.layerFadeLong.duration,
      curve: SenseMotion.layerFadeLong.curve,
      builder: (context, v, _) => builder(v),
    );
  }
}
