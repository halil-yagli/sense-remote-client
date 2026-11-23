// Sense Remote: idle warning (YH O15, #55). Pure Dart, driven by the same tick.
//
// The Host closes a connection that had no input for the panel's "Hareketsiz
// bağlantıyı kes" time. One minute before that the Controller shows the orange strip
// with a countdown; "Devam et" or any mouse / keyboard input starts the time over.
// When the count reaches zero the session ends with the "idle" reason (O14).
import 'layer_spec.dart';

enum SenseIdlePhase { active, warning, expired }

class SenseIdleView {
  const SenseIdleView(this.phase, [this.secondsLeft = 0]);

  static const SenseIdleView active = SenseIdleView(SenseIdlePhase.active);

  final SenseIdlePhase phase;

  /// Seconds until the connection is cut (warning only).
  final int secondsLeft;

  bool get warning => phase == SenseIdlePhase.warning;
  bool get expired => phase == SenseIdlePhase.expired;
}

class SenseIdleWatch {
  SenseIdleWatch({this.limit, Duration start = Duration.zero}) : _lastActivity = start;

  /// Null = this computer is never cut for being idle (no strip).
  Duration? limit;

  Duration _lastActivity;
  SenseIdleView _view = SenseIdleView.active;

  SenseIdleView get view => _view;

  /// Mouse, keyboard or "Devam et": the time starts over.
  SenseIdleView activity(Duration now) {
    if (_view.expired) return _view;
    _lastActivity = now;
    _view = SenseIdleView.active;
    return _view;
  }

  SenseIdleView tick(Duration now) {
    final l = limit;
    if (l == null || _view.expired) return _view;
    final left = l - (now - _lastActivity);
    if (left <= Duration.zero) {
      _view = const SenseIdleView(SenseIdlePhase.expired);
    } else if (left <= SenseIdleTiming.warnBefore) {
      // Round up: the strip shows 60 the moment it appears.
      _view = SenseIdleView(SenseIdlePhase.warning, (left.inMilliseconds / 1000).ceil());
    } else {
      _view = SenseIdleView.active;
    }
    return _view;
  }
}
