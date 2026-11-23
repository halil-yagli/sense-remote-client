import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/sense/diag_text.dart';

// Sense Remote (karar #86): the Dart side of the connection record. Flutter errors, uncaught
// asynchronous errors, `debugPrint` and `print` lines go into the Rust log of this process
// (`main_sense_dart_log`), where the Host / Controller connection record reads them. Every
// window (the multi-window engines run `main` too) installs it once.

void _senseDiagSend(String level, String line) {
  try {
    unawaited(
        bind.mainSenseDartLog(level: level, line: senseDiagTruncate(line)).catchError((_) {}));
  } catch (_) {
    // The bridge is not ready (very early start) or already gone: never throw from a logger.
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
    if (previousFlutterError != null) {
      previousFlutterError(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    _senseDiagSend('error', senseDiagError('PlatformDispatcher', error, stack));
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
}

/// Zone specification that also records `print` calls.
ZoneSpecification senseDiagZoneSpec() => ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        _senseDiagSend('debug', line);
        parent.print(zone, line);
      },
    );
