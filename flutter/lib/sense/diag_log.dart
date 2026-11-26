import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/sense/diag_text.dart';

// Sense Remote (karar #86): the Dart side of the connection record. Flutter errors, uncaught
// asynchronous errors, `debugPrint` and `print` lines go into the Rust log of this process
// (`main_sense_dart_log`), where the Host / Controller connection record reads them. Every
// window (the multi-window engines run `main` too) installs it once.
//
// Karar #103 (Sürüm 9): interface events as well — screen, list and popup openings, button
// names, setting changes (old → new), ghost mode, display switches and the Host window's size
// and scale. One `[ui] …` line each (see diag_text.dart); names only, never content.
// The lines go through the same bridge call (raw log, unchanged); interface events and errors
// also go to the structured event record (`main_sense_diag_event`, [_senseDiagEvent]), which the
// panel filters by category and kind.

/// Tests catch the lines here instead of the bridge.
@visibleForTesting
void Function(String level, String line)? senseDiagTestSink;

void _senseDiagSend(String level, String line) {
  final sink = senseDiagTestSink;
  if (sink != null) {
    sink(level, senseDiagTruncate(line));
    return;
  }
  try {
    unawaited(
        bind.mainSenseDartLog(level: level, line: senseDiagTruncate(line)).catchError((_) {}));
  } catch (_) {
    // The bridge is not ready (very early start) or already gone: never throw from a logger.
  }
}

/// Tests catch the structured events here instead of the bridge: (category, kind, fields).
@visibleForTesting
void Function(String category, String kind, Map<String, Object?> fields)? senseDiagEventTestSink;

/// One structured event (`main_sense_diag_event`). Never throws; in tests only the sinks see it.
void _senseDiagEvent(String category, String kind, Map<String, Object?> fields) {
  final k = senseDiagEventKind(kind);
  if (k == null) return;
  final clean = senseDiagEventFields(fields);
  final sink = senseDiagEventTestSink;
  if (sink != null) {
    sink(category, k, clean);
    return;
  }
  if (senseDiagTestSink != null) return; // a test that watches the lines only
  try {
    unawaited(bind
        .mainSenseDiagEvent(category: category, kind: k, fieldsJson: jsonEncode(clean))
        .catchError((_) {}));
  } catch (_) {
    // The bridge is not ready or gone: never throw from a logger.
  }
}

bool _installed = false;

/// Hooks `FlutterError.onError`, `PlatformDispatcher.onError` and `debugPrint`. Call it first
/// thing in `main`; the zone part is [senseDiagZoneSpec] / [senseDiagZoneError].
void senseInstallDiagLog() {
  if (_installed) return;
  _installed = true;
  final previousFlutterError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    _senseDiagSend('error',
        senseDiagError('FlutterError', details.exceptionAsString(), details.stack));
    _senseDiagEvent('error', 'flutter',
        {'tur': 'FlutterError', 'hata': details.exceptionAsString()});
    if (previousFlutterError != null) {
      previousFlutterError(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _senseDiagSend('error', senseDiagError('PlatformDispatcher', error, stack));
    _senseDiagEvent('error', 'flutter', {'tur': 'PlatformDispatcher', 'hata': '$error'});
    return false; // not handled here: the default behaviour goes on
  };
  final previousDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) _senseDiagSend('debug', message);
    previousDebugPrint(message, wrapWidth: wrapWidth);
  };
}

/// `runZonedGuarded`'s error handler.
void senseDiagZoneError(Object error, StackTrace stack) {
  _senseDiagSend('error', senseDiagError('Zone', error, stack));
  _senseDiagEvent('error', 'zone', {'hata': '$error'});
}

/// Zone specification that also records `print` calls.
ZoneSpecification senseDiagZoneSpec() => ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        _senseDiagSend('debug', line);
        parent.print(zone, line);
      },
    );

// ---- interface events (karar #103) ----

/// Any interface event: `[ui] <kind> key=value …`. Field values are names and numbers only.
void senseUiEvent(String kind, [Map<String, Object?> fields = const {}]) {
  _senseDiagSend('info', senseUiLine(kind, fields));
  _senseDiagEvent('ui', kind, fields);
}

/// A screen (page, tab, view) opened, e.g. `senseUiScreen('controller.computers')`.
void senseUiScreen(String name, {String? from}) =>
    senseUiEvent('screen', {'name': name, if (from != null) 'from': from});

/// A list (O3–O7) opened or closed.
void senseUiList(String name, {required bool open}) =>
    senseUiEvent('list', {'name': name, 'open': open});

/// A popup opened or closed.
void senseUiPopup(String name, {required bool open}) =>
    senseUiEvent('popup', {'name': name, 'open': open});

/// A button was pressed: its label or key, and where (never what a field contains).
void senseUiButton(String name, {String? where}) =>
    senseUiEvent('button', {'name': name, if (where != null) 'where': where});

/// A setting changed from [from] to [to]; secret settings are written as `***`.
void senseUiSetting(String key, Object? from, Object? to, {String? where}) {
  _senseDiagSend('info', senseUiSettingLine(key, from, to, where: where));
  final secret = senseUiSecretKey(key);
  _senseDiagEvent('ui', 'setting', {
    'ad': key,
    if (where != null) 'yer': where,
    'eski': secret ? kSenseUiMasked : from,
    'yeni': secret ? kSenseUiMasked : to,
  });
}

/// Ghost mode (hayalet mod) on or off, and why (user, policy, session start).
void senseUiGhost(bool on, {String? reason}) =>
    senseUiEvent('ghost', {'on': on, if (reason != null) 'reason': reason});

/// The Controller switched the shown display (numbers, or "all").
void senseUiDisplay({required Object from, required Object to}) =>
    senseUiEvent('display', {'from': from, 'to': to});

/// Records every route push / pop of a navigator as a screen event. Add it to the
/// `navigatorObservers` of a `MaterialApp` (route name, or the route's type without a name).
class SenseDiagNavigatorObserver extends NavigatorObserver {
  static String _name(Route<dynamic>? route) {
    if (route == null) return '-';
    return route.settings.name ?? route.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      senseUiEvent('route', {'op': 'push', 'name': _name(route), 'from': _name(previousRoute)});

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      senseUiEvent('route', {'op': 'pop', 'name': _name(route), 'to': _name(previousRoute)});

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      senseUiEvent('route', {'op': 'replace', 'name': _name(newRoute), 'from': _name(oldRoute)});
}
