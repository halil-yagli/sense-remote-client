// Sense Remote (Sürüm 12, plan 2026-11-28 §2.1, §2.4): what the "Sık kullanılanlar" list
// asks of the core. One method per bridge function, answers kept as the raw strings the
// core gives, so the tests feed the list the core's real answers (`{"error":"unsupported"}`,
// `[]`, a result event). The real one is `favorites_ffi.dart`.
//
// The core answers "not supported" until FAV-Ç fills the bodies; an older Host never
// answers a run at all. The model turns both into a calm line, never a dialog.
import 'catalog.dart';

abstract class SenseFavoritesIo {
  /// `main_sense_shortcut_catalog(os)`: `[{id, cat, kind, admin, available}]`, `[]` while the
  /// core has no catalogue.
  Future<String> catalog(SenseFavOs os);

  /// `main_sense_prefs_get(os)`: `{entries, custom}` or `{"error":"unsupported"}`.
  Future<String> prefsGet(SenseFavOs os);

  /// `main_sense_prefs_set(json)`: "" when stored, else a code (`unsupported`).
  Future<String> prefsSet(String json);

  /// `main_sense_custom_shortcut_request(json)`: `{id, status}` or `{"error": …}`.
  Future<String> customRequest(String json);

  /// `session_sense_send_msg(session, name, json)`: "" when sent, else a code
  /// (`unsupported`, `not_allowed`, `no_session`).
  Future<String> send(String name, String json);

  /// Sends a `keys` entry from this side (Ctrl+Alt+Del, lock, Win+D). False when it cannot.
  bool sendKeys(SenseFavKeys keys);
}

/// A run the Host answered (`sense_shortcut_result {req, ok, err}`).
typedef SenseFavResultSink = void Function(int req, bool ok, String? err);

/// Routes the core's events to the open lists. The session event listener calls
/// [handle] (one line next to `SenseSessionEvents.handle`); the main event listener
/// calls [handleGlobal] for `sense_prefs_changed`.
abstract final class SenseFavoritesEvents {
  static const String shortcutResult = 'sense_shortcut_result';
  static const String prefsChanged = 'sense_prefs_changed';

  static final Map<String, SenseFavResultSink> _results = {};
  static final Set<void Function()> _prefs = {};

  static void listen(String peerId, SenseFavResultSink sink) => _results[peerId] = sink;

  static void forget(String peerId, SenseFavResultSink sink) {
    // Method tear-offs are equal, not identical.
    if (_results[peerId] == sink) _results.remove(peerId);
  }

  static void listenPrefs(void Function() f) => _prefs.add(f);
  static void forgetPrefs(void Function() f) => _prefs.remove(f);

  /// A session event; false when [evt] is not one of ours.
  static bool handle(String peerId, Map<String, dynamic> evt) {
    final name = evt['name'];
    if (name == shortcutResult) {
      final req = int.tryParse('${evt['req']}');
      final ok = '${evt['ok']}' == 'true';
      final raw = evt['err'];
      final err = raw == null || '$raw' == 'null' || '$raw'.isEmpty ? null : '$raw';
      if (req != null) _results[peerId]?.call(req, ok, err);
      return true;
    }
    if (name == prefsChanged) {
      handleGlobal(evt);
      return true;
    }
    return false;
  }

  /// A session-less event; false when [evt] is not one of ours.
  static bool handleGlobal(Map<String, dynamic> evt) {
    if (evt['name'] != prefsChanged) return false;
    for (final f in List.of(_prefs)) {
      f();
    }
    return true;
  }
}
