// Sense Remote (Sürüm 12, #169): the session's view preferences that follow the person's
// account: `view.quality` `{mode: best|balanced|low|custom, fps?}`, `view.scale`
// `{mode: fit|original}` and `keys.bindings` (the key bindings). They live in the core's
// preference store (`main_sense_prefs_*`, same bridge as the favourites and "Hayalet modla
// başla"); with no store (signed out, old core) nothing here does anything and the old local
// behaviour carries on.
//
// Stays on the computer, never written here: window position, audio devices, recording folder.
import 'dart:convert';

import '../../../../models/platform_model.dart';

abstract class SenseAccountPrefsIo {
  /// `main_sense_prefs_get('any')`: `{entries, custom}` or `{"error":"unsupported"}`.
  Future<String> get();

  /// `main_sense_prefs_set(json)`: "" when stored, else a code.
  Future<String> set(String json);
}

class SenseAccountPrefsBridge implements SenseAccountPrefsIo {
  const SenseAccountPrefsBridge();

  @override
  Future<String> get() => bind.mainSensePrefsGet(os: 'any');

  @override
  Future<String> set(String json) => bind.mainSensePrefsSet(json: json);
}

/// What the account holds for this session; every field is null while the account has not set it.
class SenseAccountView {
  const SenseAccountView({this.quality, this.fps, this.scale, this.bindings});

  /// `best`, `balanced`, `low` or `custom`.
  final String? quality;
  final int? fps;

  /// RustDesk's view style: `adaptive` or `original` (the account's `fit` / `original`).
  final String? scale;

  /// The `bindings` list of the keyboard shortcut config, as the account keeps it.
  final List<Map<String, dynamic>>? bindings;
}

class SenseAccountViewPrefs {
  const SenseAccountViewPrefs([this.io = const SenseAccountPrefsBridge()]);

  final SenseAccountPrefsIo io;

  static const String keyQuality = 'view.quality';
  static const String keyScale = 'view.scale';
  static const String keyBindings = 'keys.bindings';

  /// The account's values, or null when nothing is kept for the account.
  Future<SenseAccountView?> read() async {
    try {
      return parse(await io.get());
    } catch (_) {
      return null;
    }
  }

  static SenseAccountView? parse(String raw) {
    final Object? v;
    try {
      v = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (v is! Map || v['error'] != null || v['entries'] is! List) return null;
    Object? value(String key) {
      for (final e in v['entries'] as List) {
        if (e is Map && e['os'] == 'any' && e['key'] == key) return e['value'];
      }
      return null;
    }

    String? quality;
    int? fps;
    final q = value(keyQuality);
    if (q is Map) {
      final mode = q['mode'];
      if (mode == 'best' || mode == 'balanced' || mode == 'low' || mode == 'custom') quality = mode as String;
      final f = q['fps'];
      if (f is int && f >= 1 && f <= 120) fps = f;
    }
    String? scale;
    final s = value(keyScale);
    if (s is Map) {
      scale = switch (s['mode']) {
        'fit' => 'adaptive',
        'original' => 'original',
        _ => null,
      };
    }
    List<Map<String, dynamic>>? bindings;
    final b = value(keyBindings);
    final list = b is Map ? b['bindings'] : b;
    if (list is List) {
      bindings = [for (final x in list) if (x is Map) Map<String, dynamic>.from(x)];
    }
    return SenseAccountView(quality: quality, fps: fps, scale: scale, bindings: bindings);
  }

  /// Keeps the picture quality in the account; false when it could not be stored. Only the mode
  /// (and the frame rate of "custom") go to the account; the custom quality percent stays here.
  Future<bool> writeQuality(String mode, {int? fps}) {
    final value = <String, Object>{
      'mode': mode,
      if (mode == 'custom' && fps != null && fps >= 1 && fps <= 120) 'fps': fps,
    };
    return _put(keyQuality, value);
  }

  /// Keeps the scaling in the account. "custom" has no account value: nothing is written.
  Future<bool> writeScale(String viewStyle) async {
    final mode = switch (viewStyle) {
      'adaptive' => 'fit',
      'original' => 'original',
      _ => null,
    };
    if (mode == null) return false;
    return _put(keyScale, {'mode': mode});
  }

  /// Keeps the key bindings in the account.
  Future<bool> writeBindings(List<Map<String, dynamic>> bindings) => _put(keyBindings, bindings);

  Future<bool> _put(String key, Object value) async {
    try {
      final r = await io.set(jsonEncode({
        'entries': [
          {'os': 'any', 'key': key, 'value': value}
        ]
      }));
      return r.isEmpty;
    } catch (_) {
      return false;
    }
  }

  /// The keyboard shortcut config (local option text) with the account's bindings put in; null
  /// when it already holds them. The other fields (`enabled`, `pass_through`) stay as they are.
  static String? mergeBindings(String localRaw, List<Map<String, dynamic>> account) {
    Map<String, dynamic> cfg;
    try {
      cfg = localRaw.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(localRaw) as Map);
    } catch (_) {
      cfg = <String, dynamic>{};
    }
    final same = jsonEncode(cfg['bindings'] ?? const []) == jsonEncode(account);
    if (same && localRaw.isNotEmpty) return null;
    cfg['bindings'] = account;
    cfg['enabled'] ??= false;
    return jsonEncode(cfg);
  }
}
