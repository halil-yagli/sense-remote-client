// Sense Remote (Sürüm 12, #157, plan 2026-11-28 §2.1–§2.4): the admin terminal without the
// Windows administrator name and password.
//
// The terminal opens on a normal connection. Before `TerminalAction::Open` the page asks
// `session_sense_term_admin_begin` (Rust fetches the panel ticket and sends it to the Host;
// the ticket never reaches Dart) and waits for the event `sense_term_admin_result {ok, err}`.
// ok → the terminal opens with the service's rights. Any error → a Turkish sentence and a
// choice; `unsupported` (no Windows session on the Host, or an older Host) offers RustDesk's
// own administrator sign-in box as the fallback (K9).
//
// Opening windows hand the request over with [senseRequestAdminTerminal]: the terminal window
// is a separate Flutter engine of the same process, so a process environment value carries
// "this computer, admin, now" (consumed once, valid [kSenseTermAdminRequestTtl]).
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../models/platform_model.dart';

/// Event name (Rust `peer_msg::EV_TERM_ADMIN_RESULT`).
const String kSenseTermAdminResultEvent = 'sense_term_admin_result';

/// Environment key of the hand-over ("<peer id>|<epoch ms>").
const String kSenseTermAdminRequestEnv = 'SENSE_TERM_ADMIN_REQUEST';

/// A request older than this is ignored (the window never opened).
const Duration kSenseTermAdminRequestTtl = Duration(seconds: 30);

/// Rust answers `unsupported` after 10 s without a Host answer; the panel request comes before.
const Duration kSenseTermAdminSafety = Duration(seconds: 40);

/// Pure parts of the hand-over (tests).
@visibleForTesting
String senseTermAdminRequestValue(String peerId, DateTime now) => '$peerId|${now.millisecondsSinceEpoch}';

@visibleForTesting
bool senseTermAdminRequestMatches(String value, String peerId, DateTime now) {
  final cut = value.lastIndexOf('|');
  if (cut <= 0 || value.substring(0, cut) != peerId) return false;
  final at = int.tryParse(value.substring(cut + 1));
  if (at == null) return false;
  final age = now.millisecondsSinceEpoch - at;
  return age >= 0 && age <= kSenseTermAdminRequestTtl.inMilliseconds;
}

/// Before `connect(isTerminal: true)`: the next terminal window of [peerId] asks for the
/// admin terminal (after the person confirmed it in place).
void senseRequestAdminTerminal(String peerId) {
  try {
    bind.mainSetEnv(key: kSenseTermAdminRequestEnv, value: senseTermAdminRequestValue(peerId, DateTime.now()));
  } catch (_) {}
}

/// In the terminal window: true once when an admin request for [peerId] is waiting.
bool senseTakeAdminRequest(String peerId) {
  try {
    final v = bind.mainGetEnv(key: kSenseTermAdminRequestEnv);
    if (!senseTermAdminRequestMatches(v, peerId, DateTime.now())) return false;
    bind.mainSetEnv(key: kSenseTermAdminRequestEnv, value: null);
    return true;
  } catch (_) {
    return false;
  }
}

/// `{ok, err}` of the event; ok may come as a JSON bool or text.
({bool ok, String? err}) senseTermAdminResultOf(Map<String, dynamic> evt) {
  final raw = evt['ok'];
  final ok = raw == true || raw?.toString() == 'true';
  final e = evt['err'];
  final err = e == null || e.toString().isEmpty || e.toString() == 'null' ? null : e.toString();
  return (ok: ok, err: ok ? null : (err ?? 'unknown'));
}

enum SenseTermAdminPhase { idle, requesting, granted, failed }

/// One admin request of a terminal connection.
class SenseTermAdminController extends ChangeNotifier {
  SenseTermAdminController({required this.peerId, required this.begin, this.safety = kSenseTermAdminSafety});

  final String peerId;

  /// `session_sense_term_admin_begin`: "" = started, otherwise a code.
  final Future<String> Function() begin;
  final Duration safety;

  SenseTermAdminPhase _phase = SenseTermAdminPhase.idle;
  String? _error;
  Completer<bool>? _waiting;
  Timer? _timer;
  bool _disposed = false;

  SenseTermAdminPhase get phase => _phase;

  /// Code of the last failure.
  String? get error => _error;
  bool get busy => _waiting != null;

  /// Asks once; true = the Host accepted the ticket.
  Future<bool> run() async {
    final pending = _waiting;
    if (pending != null) return pending.future;
    final c = _waiting = Completer<bool>();
    _phase = SenseTermAdminPhase.requesting;
    _error = null;
    _notify();
    SenseTermAdminEvents._listen(peerId, this);
    String code;
    try {
      code = await begin();
    } catch (_) {
      code = 'no_session';
    }
    if (c.isCompleted || !identical(_waiting, c)) return c.future;
    if (code.isNotEmpty) {
      _finish(false, code);
    } else {
      _timer = Timer(safety, () => _finish(false, 'timeout'));
    }
    return c.future;
  }

  /// The event of this connection.
  void onResult(bool ok, String? err) {
    if (_waiting == null) return;
    _finish(ok, ok ? null : (err ?? 'unknown'));
  }

  /// Back to the start (the person chose the normal terminal).
  void reset() {
    if (_waiting != null) return;
    _phase = SenseTermAdminPhase.idle;
    _error = null;
    _notify();
  }

  void _finish(bool ok, String? err) {
    _timer?.cancel();
    _timer = null;
    final c = _waiting;
    _waiting = null;
    SenseTermAdminEvents._forget(peerId, this);
    _phase = ok ? SenseTermAdminPhase.granted : SenseTermAdminPhase.failed;
    _error = err;
    if (ok) SenseTermAdminEvents.setGranted(peerId, true);
    _notify();
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    final c = _waiting;
    _waiting = null;
    SenseTermAdminEvents._forget(peerId, this);
    if (c != null && !c.isCompleted) c.complete(false);
    super.dispose();
  }
}

/// Where `sense_term_admin_result` reaches the controller of its connection (one terminal
/// connection per computer in a terminal window), and which connections run as admin.
abstract final class SenseTermAdminEvents {
  static final Map<String, SenseTermAdminController> _waiting = {};
  static final Map<String, ValueNotifier<bool>> _granted = {};

  static void _listen(String peerId, SenseTermAdminController c) => _waiting[peerId] = c;

  static void _forget(String peerId, SenseTermAdminController c) {
    if (identical(_waiting[peerId], c)) _waiting.remove(peerId);
  }

  /// Handles the Sense event; false when [evt] is not one (models/model.dart chain).
  static bool handle(String peerId, Map<String, dynamic> evt) {
    if (evt['name'] != kSenseTermAdminResultEvent) return false;
    final r = senseTermAdminResultOf(evt);
    _waiting[peerId]?.onResult(r.ok, r.err);
    return true;
  }

  /// The terminal connection of [peerId] runs with admin rights (badge, footer).
  static ValueListenable<bool> grantedOf(String peerId) =>
      _granted.putIfAbsent(peerId, () => ValueNotifier(false));

  static bool isGranted(String peerId) => _granted[peerId]?.value ?? false;

  /// Bumps on every change (the window's title chip listens without knowing the computer).
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static void setGranted(String peerId, bool v) {
    final n = _granted[peerId];
    if (n == null) {
      if (!v) return;
      _granted[peerId] = ValueNotifier(true);
    } else {
      if (n.value == v) return;
      n.value = v;
    }
    changes.value++;
  }
}
