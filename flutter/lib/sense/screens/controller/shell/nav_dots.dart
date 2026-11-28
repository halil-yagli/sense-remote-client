// Sense Remote (Sürüm 12, FU-A3; prototype `.anv .d`): the dots in the left menu of the
// Controller and Host windows.
//   - Hakkında: yellow while a verified newer release waits ("güncelleme var").
//   - Bu bilgisayar: red while the Host is not ready ("Host hazır değil").
// Pure rules and the small watcher both shells use, so they cannot drift apart.
import 'dart:async';

import 'package:get/get.dart';

import '../../../../models/state_model.dart' show SvcStatus, stateGlobal;
import '../../../sense.dart' show SenseLevel;
import '../../host/data/host_status.dart' show SenseHostPhase, senseHostPhase;
import '../update/sense_update_model.dart' show SenseUpdateStatus;

/// The dot next to "Hakkında": yellow while a verified newer release waits.
SenseLevel? senseAboutNavLevel(SenseUpdateStatus s) => s.hasReadyRelease ? SenseLevel.warn : null;

/// The dot next to "Bu bilgisayar": red while the Host is not ready (connection server
/// unreachable or the service stopped). "Bağlanıyor" is no problem yet.
SenseLevel? senseHostNavLevel({required SvcStatus svc, required bool stopped}) {
  final phase = senseHostPhase(svc: svc, stopped: stopped, macBlocked: false, connections: 0);
  return phase == SenseHostPhase.down || phase == SenseHostPhase.stopped ? SenseLevel.hot : null;
}

/// How long the Host must stay not ready before the dot shows (the state is "not ready" for a
/// moment at every start; the dot is not a flash).
const Duration kSenseHostDotDelay = Duration(seconds: 6);

/// Looks at the Host state every [every] and tells [onChanged] when the dot appears or goes.
/// The sources are injectable for tests; the defaults are the app's own state.
class SenseHostDotWatch {
  SenseHostDotWatch({
    required this.onChanged,
    this.delay = kSenseHostDotDelay,
    this.every = const Duration(seconds: 2),
    SvcStatus Function()? svc,
    bool Function()? stopped,
    DateTime Function()? now,
  })  : _svc = svc ?? (() => stateGlobal.svcStatus.value),
        _stopped = stopped ?? _serviceStopped,
        _now = now ?? DateTime.now;

  final void Function(SenseLevel? level) onChanged;
  final Duration delay;
  final Duration every;
  final SvcStatus Function() _svc;
  final bool Function() _stopped;
  final DateTime Function() _now;

  SenseLevel? _level;
  DateTime? _badSince;
  Timer? _timer;

  /// The dot now (null = none).
  SenseLevel? get level => _level;

  static bool _serviceStopped() =>
      Get.isRegistered<RxBool>(tag: 'stop-service') ? Get.find<RxBool>(tag: 'stop-service').value : false;

  void start() {
    _timer ??= Timer.periodic(every, (_) => check());
  }

  /// One look. The dot shows after [delay] of "not ready" and goes at the first good look.
  void check() {
    final bad = senseHostNavLevel(svc: _svc(), stopped: _stopped()) != null;
    if (!bad) {
      _badSince = null;
      _set(null);
      return;
    }
    final since = _badSince ??= _now();
    if (_now().difference(since) >= delay) _set(SenseLevel.hot);
  }

  void _set(SenseLevel? level) {
    if (level == _level) return;
    _level = level;
    onChanged(level);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
