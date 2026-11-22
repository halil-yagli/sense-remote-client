// Sense Remote: notification pill (YH T7 "Bildirim (toast)"; prototype `.toast`).
// White pill, black 12/500 text, bottom centre (22 px up), shown 1.5–1.8 s,
// information only (no buttons). A new message replaces the one on screen.
import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';

class SenseToastController extends ChangeNotifier {
  String? _message;
  int _serial = 0;
  Timer? _timer;

  /// Visible time (T7: 1.5–1.8 s; prototype 1.5 s).
  static const Duration holdDuration = Duration(milliseconds: 1600);

  /// Fade in / out (prototype `transition:.2s`).
  static const Duration fadeDuration = Duration(milliseconds: 200);

  String? get message => _message;
  bool get visible => _message != null;
  int get serial => _serial;

  void show(String message, {Duration hold = holdDuration}) {
    _timer?.cancel();
    _message = message;
    _serial++;
    notifyListeners();
    _timer = Timer(hold, hide);
  }

  void hide() {
    _timer?.cancel();
    _timer = null;
    if (_message == null) return;
    _message = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Puts the toast over [child]. Screens call `SenseToast.show(context, '…')`.
class SenseToastHost extends StatefulWidget {
  const SenseToastHost({super.key, required this.child, this.controller});

  final Widget child;

  /// Optional outside controller (tests, or a screen that shows toasts from a model).
  final SenseToastController? controller;

  @override
  State<SenseToastHost> createState() => _SenseToastHostState();
}

class _SenseToastHostState extends State<SenseToastHost> {
  SenseToastController? _own;
  String _last = '';

  SenseToastController get _c => widget.controller ?? (_own ??= SenseToastController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return _SenseToastScope(
      controller: c,
      child: Stack(children: [
        Positioned.fill(child: widget.child),
        Positioned(
          left: 0,
          right: 0,
          bottom: SenseToast.bottomGap,
          child: IgnorePointer(
            child: ListenableBuilder(
              listenable: c,
              builder: (context, _) {
                if (c.message != null) _last = c.message!;
                return Center(
                  child: AnimatedOpacity(
                    opacity: c.visible ? 1 : 0,
                    duration: SenseToastController.fadeDuration,
                    child: _last.isEmpty ? const SizedBox.shrink() : SenseToast(message: _last),
                  ),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }
}

class _SenseToastScope extends InheritedWidget {
  const _SenseToastScope({required this.controller, required super.child});

  final SenseToastController controller;

  @override
  bool updateShouldNotify(_SenseToastScope old) => old.controller != controller;
}

/// The pill itself.
class SenseToast extends StatelessWidget {
  const SenseToast({super.key, required this.message});

  final String message;

  static const double bottomGap = 22;

  /// Shows [message] in the nearest [SenseToastHost]; also read out by screen readers.
  static void show(BuildContext context, String message) {
    final scope = context.getInheritedWidgetOfExactType<_SenseToastScope>();
    assert(scope != null, 'SenseToast.show() called outside a SenseToastHost');
    scope?.controller.show(message);
    SemanticsService.announce(message, Directionality.maybeOf(context) ?? TextDirection.ltr);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('sense-toast'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: SenseColors.text,
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
      ),
      child: Text(
        message,
        style: const TextStyle(
          fontFamily: SenseFont.family,
          fontSize: SenseFontSize.bodySmall,
          fontWeight: SenseFontWeight.medium,
          color: SenseColors.bg,
        ),
      ),
    );
  }
}
