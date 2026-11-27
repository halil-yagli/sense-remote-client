// Sense Remote: one connection window's layers — connection problem (O13), connection
// ended (O14), idle warning (O15). Owns the one-second tick; the two state machines
// are pure Dart (link_machine.dart, idle_watch.dart). Everything that touches the
// RustDesk session goes through [SenseLayerHost] (data/session_bridge.dart), so the
// controller is tested with a fake host and a fake clock.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'data/link_meter.dart';
import 'idle_watch.dart';
import 'layer_spec.dart';
import 'link_machine.dart';
import 'session_end.dart';

/// The raw quality values of the session at one moment (`QualityMonitorData`).
class SenseLinkRaw {
  const SenseLinkRaw({
    this.delay,
    this.fps,
    this.lossEst,
    this.lastFrameMs,
    this.lastFrameAt,
    this.probeAt,
    this.direct,
    this.speed,
    this.waitingImage = false,
  });

  final String? delay;
  final String? fps;
  final double? lossEst;
  final int? lastFrameMs;
  final DateTime? lastFrameAt;
  final DateTime? probeAt;

  /// Sürüm 10 (#110): true = direct, false = through the relay, null = not known yet
  /// (the good-link card shows the connection type).
  final bool? direct;

  /// RustDesk `speed` ("123.45kB/s"): with a good link, little data means a still screen (K44).
  final String? speed;

  /// Sürüm 11 (#121): logged in (peer info came) but no picture yet.
  final bool waitingImage;
}

/// What the layers need from the RustDesk session.
abstract class SenseLayerHost {
  SenseLinkRaw readLink();

  /// Chat messages of this connection (both sides) and files sent in the chat.
  int chatMessages();
  int chatFiles();

  /// Close this connection window; the main window shows Bilgisayarlar.
  void goHome();

  /// Connect again to the same computer, in this window.
  void reconnect();

  /// Sürüm 11 (O1): one silent reconnect attempt while the transport is lost (no RustDesk
  /// dialog; the lost card shows the attempts).
  void retry();

  /// Sürüm 11 (O2): "Bağlantıyı bitir": the connection ends in every window that shows it,
  /// and this window closes.
  void endConnection();

  /// Sürüm 11 (O3): input in this window, shared by every window of the connection.
  void shareActivity();

  /// Sürüm 11 (O3): time since the last input in any window of the connection (null = none).
  Duration? sharedIdle();

  /// Tell the Host someone is still here (its idle timer starts over).
  void keepAlive();

  /// Close open lists, popups and RustDesk dialogs (O14 "açık liste ve popup kapanır").
  void closePopups();
}

enum SenseReconnectState { idle, connecting, busy }

class SenseLayerController extends ChangeNotifier {
  SenseLayerController({
    required this.host,
    Duration? idleLimit,
    Duration Function()? clock,
    DateTime Function()? wall,
    bool autoStart = true,
  })  : _clock = clock ?? _stopwatchClock(),
        _wall = wall ?? DateTime.now {
    _startedAt = _clock();
    _watchingSince = _wall();
    _idle = SenseIdleWatch(limit: idleLimit, start: _startedAt);
    if (autoStart) start();
  }

  static Duration Function() _stopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  static final Map<String, SenseLayerController> _byId = {};

  /// The controller of a connection window (the tab key is the peer id), if it is up.
  /// The top bar reads [wavy] from here ("Dalgalı").
  static SenseLayerController? find(String id) => _byId[id];

  static void attach(String id, SenseLayerController c) => _byId[id] = c;

  static void detach(String id, SenseLayerController c) {
    if (identical(_byId[id], c)) _byId.remove(id);
  }

  final SenseLayerHost host;
  final Duration Function() _clock;
  final DateTime Function() _wall;

  late Duration _startedAt;
  late DateTime _watchingSince;
  late final SenseIdleWatch _idle;
  final SenseLinkMachine _link = SenseLinkMachine();
  // Sürüm 11 (O1): real reconnect attempts while the transport is lost.
  final SenseRetryPlan _retry = SenseRetryPlan();
  // A delay probe came since watching began: the link was up once (no retries before that,
  // e.g. while the Host still has to accept).
  bool _everUp = false;
  // Sürüm 11 (#121): since when the picture is awaited after login.
  Duration? _waitingSince;
  // Sürüm 11 (O7): when "Yeniden bağlan" was pressed.
  Duration? _reconnectAt;
  bool _reconnectFailed = false;
  // Sürüm 11 (O3): last time this window's input was handed to the shared count.
  Duration? _sharedAt;

  /// Sürüm 11 (O5): the connection came back (after "Yeniden bağlan" or a reconnect attempt);
  /// the window reads the panel's idle limit again.
  VoidCallback? onReconnected;
  Timer? _timer;
  bool _disposed = false;

  SenseSessionSummary? _ended;
  Duration? _endedAt;
  SenseReconnectState _reconnect = SenseReconnectState.idle;
  int _recoveredSerial = 0;

  // Karar #94: "×" on the weak card shrinks it into the bar's logo area.
  bool _dismissed = false;
  Duration? _dismissedAt;
  SenseLinkPhase _prevPhase = SenseLinkPhase.normal;

  /// Bad values without a layer: the top bar says "Dalgalı".
  final ValueNotifier<bool> wavy = ValueNotifier(false);

  SenseLinkView get link => _link.view;

  // Sürüm 10 (#110): the link card opened from the bar's logo area while the link is good.
  bool _infoOpen = false;
  bool? _direct;

  /// Connection type of the last reading (null = not known yet).
  bool? get direct => _direct;

  /// The good-link card (O13 layout, current values) is up. It gives way to the weak /
  /// lost card when trouble starts and to the ended card.
  bool get infoOpen => _infoOpen && _ended == null && _link.view.phase == SenseLinkPhase.normal;

  /// Click on the bar's logo / status area (karar #94, #110): the minimized weak card
  /// comes back; with a good link the same card opens with the current values.
  void openCard() {
    if (_ended != null) return;
    if (_dismissed) {
      restoreCard();
      return;
    }
    if (_link.view.phase != SenseLinkPhase.normal || _infoOpen) return;
    _infoOpen = true;
    _notify();
  }

  /// "×" / Kapat on the good-link card.
  void closeInfo() {
    if (!_infoOpen) return;
    _infoOpen = false;
    _notify();
  }

  /// The weak card was closed with "×" and sits in the bar's logo area. Never true
  /// for the lost card (it stays).
  bool get minimized => _dismissed && _link.view.phase == SenseLinkPhase.weak && !_link.view.dropped;

  /// "×" on the weak card (not offered once the link is lost).
  void minimize() {
    if (_ended != null || _link.view.phase != SenseLinkPhase.weak || _link.view.dropped) return;
    _dismissed = true;
    _dismissedAt = _clock();
    _notify();
  }

  /// Click on the bar's logo / status area: the card opens again.
  void restoreCard() {
    if (!_dismissed) return;
    _dismissed = false;
    _notify();
  }

  SenseIdleView get idle => _idle.view;
  SenseSessionSummary? get ended => _ended;
  SenseReconnectState get reconnectState => _reconnect;

  /// Sürüm 11 (O7): the last "Yeniden bağlan" got no answer in time.
  bool get reconnectFailed => _reconnectFailed;

  /// Sürüm 11 (#121): logged in and no picture for [SenseLinkTiming.noImageAfter]: the
  /// "Görüntü bekleniyor" card instead of a black screen.
  bool get waitingImage {
    final since = _waitingSince;
    return _ended == null && since != null && _clock() - since >= SenseLinkTiming.noImageAfter;
  }

  /// Goes up by one each time the layer leaves ("Bağlantı düzeldi").
  int get recoveredSerial => _recoveredSerial;

  Duration? get idleLimit => _idle.limit;
  set idleLimit(Duration? v) {
    _idle.limit = v;
    tick();
  }

  /// Seconds until the ended card returns to Bilgisayarlar (paused while reconnecting).
  int get backHomeIn {
    final at = _endedAt;
    if (at == null) return 0;
    final left = SenseEndTiming.backHome - (_clock() - at);
    final s = (left.inMilliseconds / 1000).ceil();
    return s < 0 ? 0 : s;
  }

  void start() {
    _timer ??= Timer.periodic(SenseLinkTiming.tick, (_) => tick());
  }

  void tick() {
    if (_disposed) return;
    final now = _clock();
    if (_ended != null) {
      if (_reconnect == SenseReconnectState.connecting) {
        final probe = host.readLink().probeAt;
        if (probe != null && probe.isAfter(_watchingSince)) {
          _connectedAgain(now);
        } else if (_reconnectAt != null && now - _reconnectAt! >= SenseEndTiming.reconnectTimeout) {
          // Sürüm 11 (O7): no answer: the buttons come back, the count starts again.
          _reconnect = SenseReconnectState.idle;
          _reconnectFailed = true;
          _endedAt = now;
        }
      } else if (backHomeIn <= 0) {
        _finishHome();
        return;
      }
      _notify();
      return;
    }
    final raw = host.readLink();
    _direct = raw.direct ?? _direct;
    final probe = raw.probeAt;
    if (probe != null && probe.isAfter(_watchingSince)) _everUp = true;
    // Sürüm 11 (#121): logged in, no picture yet.
    if (raw.waitingImage) {
      _waitingSince ??= now;
    } else {
      _waitingSince = null;
    }
    // Sürüm 11 (O3): input in another window of the connection counts here too.
    final shared = host.sharedIdle();
    if (shared != null) _idle.seen(now - shared);
    final view = _link.tick(
      now,
      senseLinkSample(
        now: _wall(),
        delay: raw.delay,
        fps: raw.fps,
        lossEst: raw.lossEst,
        lastFrameMs: raw.lastFrameMs,
        lastFrameAt: raw.lastFrameAt,
        probeAt: raw.probeAt,
        watchingSince: _watchingSince,
        speed: raw.speed,
      ),
    );
    _trackDismissal(now, view.phase);
    _runRetries(now, view);
    // The bar keeps the warning colour while the card is up or minimized.
    wavy.value = view.wavy || view.phase != SenseLinkPhase.normal;
    if (_link.lastEvent == SenseLinkEvent.recovered) _recoveredSerial++;
    if (_link.lastEvent == SenseLinkEvent.dropped) {
      _end(SenseEndReason.peerGone);
      return;
    }
    if (_idle.tick(now).expired) {
      _end(SenseEndReason.idle);
      return;
    }
    _notify();
  }

  /// Sürüm 11 (O1): while the transport is lost, connect again for real (1, 2, 4, 8 s apart)
  /// until it comes back or the session closes; a link that was up and went silent for
  /// [SenseLinkTiming.lostAfter] (TCP says nothing by itself) counts as lost.
  void _runRetries(Duration now, SenseLinkView view) {
    if (_everUp && !_link.transportDown && !view.dropped && view.stall >= SenseLinkTiming.lostAfter) {
      _link.transportLost(now);
    }
    if (_link.transportDown) {
      _retry.begin(now);
      if (_retry.due(now)) host.retry();
      _link.retries = _retry.attempts;
    } else if (_retry.active) {
      final hadAttempts = _retry.attempts > 0;
      _retry.stop();
      _link.retries = 0;
      if (hadAttempts) onReconnected?.call();
    }
  }

  /// Card state across phase changes: a card closed with "×" stays closed while the
  /// same trouble lasts; after it cleared and came back it opens again, at most
  /// every [SenseLinkTiming.reopenEvery]. The lost card ignores all this.
  void _trackDismissal(Duration now, SenseLinkPhase phase) {
    final was = _prevPhase;
    _prevPhase = phase;
    if (phase == was) return;
    // Trouble took the place of the good-link card: it does not come back by itself.
    if (phase != SenseLinkPhase.normal) _infoOpen = false;
    if (phase == SenseLinkPhase.normal || phase == SenseLinkPhase.lost) {
      _dismissed = false;
    } else if (phase == SenseLinkPhase.weak) {
      final at = _dismissedAt;
      _dismissed = at != null && now - at < SenseLinkTiming.reopenEvery;
    }
  }

  /// Mouse or keyboard input in this window.
  void activity() {
    if (_ended != null) return;
    final now = _clock();
    final was = _idle.view.warning;
    _idle.activity(now);
    // Sürüm 11 (O3): at most once a second to the shared count.
    final at = _sharedAt;
    if (at == null || now - at >= SenseLinkTiming.tick) {
      _sharedAt = now;
      host.shareActivity();
    }
    if (was) _notify();
  }

  /// "Devam et" on the idle strip.
  void keepGoing() {
    if (_ended != null) return;
    _idle.activity(_clock());
    host.keepAlive();
    _notify();
  }

  /// A RustDesk message box of this session. True = taken (no RustDesk dialog).
  bool onMessage(String type, String title, String text) {
    if (_disposed) return false;
    final kind = senseClassifyMessage(type, title, text);
    // Sürüm 11 (O2): the connection was ended in another of its windows: this one closes too.
    if (kind == SenseMessageKind.endedHere) {
      _finishHome();
      return true;
    }
    if (_ended != null) {
      if (_reconnect == SenseReconnectState.connecting) {
        if (kind == SenseMessageKind.busy) {
          _reconnect = SenseReconnectState.busy;
          _endedAt = _clock();
          _notify();
          return true;
        }
        // Sürüm 11 (O7): any connection error ends the attempt (no endless "Bağlanıyor…",
        // no RustDesk dialog over the card).
        if (kind != null || _isError(type, title)) {
          _reconnect = SenseReconnectState.idle;
          _reconnectFailed = true;
          _endedAt = _clock();
          _notify();
          return true;
        }
        return false;
      }
      // The card is up: RustDesk's own retry / error dialogs stay away.
      return kind != null || type == 'restarting-show' || title == 'Connection Error';
    }
    // Sürüm 11 (O7): the first login to a busy computer: the Sense card, in Turkish.
    if (kind == SenseMessageKind.busy) {
      _end(SenseEndReason.busy);
      return true;
    }
    if (kind == SenseMessageKind.hostEnded || kind == SenseMessageKind.idle) {
      _end(senseEndReasonOf(kind!)!);
      return true;
    }
    // Sürüm 11 (O1): while reconnecting, the failed rounds' messages stay away; the lost card
    // says what happens.
    if (_link.transportDown && (type == 'restarting-show' || _isError(type, title))) {
      return true;
    }
    // A link that was up dropped (reset, timeout): connect again for real instead of ending.
    if (kind == SenseMessageKind.peerGone && _everUp) {
      _link.transportLost(_clock());
      tick();
      return true;
    }
    // Karar #94: the transport is gone: the "kesildi" card shows; the session closes
    // only when no frame and no delay measurement came for 30 s.
    // With data still coming (a restart on a working link) RustDesk keeps its way.
    if (type == 'restarting-show' &&
        (_link.view.phase == SenseLinkPhase.lost || _link.view.stall >= SenseLinkTiming.tick)) {
      _link.transportLost(_clock());
      tick();
      return true;
    }
    if (kind == null) return false;
    _end(senseEndReasonOf(kind)!);
    return true;
  }

  static bool _isError(String type, String title) =>
      title == 'Connection Error' || type == 'error' || type.contains('error');

  /// "Bağlantıyı bitir" (after the in-place second step).
  void endByUser() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    host.endConnection();
  }

  /// "Kapat" on the ended card.
  void closeEnded() => _finishHome();

  /// "Yeniden bağlan" on the ended card: same computer, same window.
  void reconnectEnded() {
    if (_ended == null || _reconnect == SenseReconnectState.connecting) return;
    _reconnect = SenseReconnectState.connecting;
    _reconnectFailed = false;
    _reconnectAt = _clock();
    _watchingSince = _wall();
    host.reconnect();
    _notify();
  }

  void _connectedAgain(Duration now) {
    _ended = null;
    _endedAt = null;
    _reconnect = SenseReconnectState.idle;
    _reconnectFailed = false;
    _link.reset();
    _retry.stop();
    _dismissed = false;
    _prevPhase = SenseLinkPhase.normal;
    _startedAt = now;
    _idle.activity(now);
    wavy.value = false;
    onReconnected?.call();
  }

  void _end(SenseEndReason reason) {
    final now = _clock();
    _ended = SenseSessionSummary(
      reason: reason,
      duration: now - _startedAt,
      messages: host.chatMessages(),
      files: host.chatFiles(),
      idleLimit: _idle.limit ?? SenseIdleTiming.defaultLimit,
    );
    _endedAt = now;
    _reconnect = SenseReconnectState.idle;
    _retry.stop();
    _waitingSince = null;
    _infoOpen = false;
    wavy.value = false;
    host.closePopups();
    _notify();
  }

  void _finishHome() {
    _timer?.cancel();
    _timer = null;
    host.goHome();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    wavy.dispose();
    super.dispose();
  }
}
