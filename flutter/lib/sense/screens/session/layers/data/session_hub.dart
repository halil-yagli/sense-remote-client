// Sense Remote: where RustDesk's session events reach the connection layers (YH O14).
// models/model.dart hands every message box to [SenseSessionHub.onMessage] first; a
// session-ending one is taken here (Sense shows its own card instead of the RustDesk
// dialog). Kept free of the RustDesk models so model.dart only gains one import and one line.
//
// Sürüm 12 (#164): two places per connection, asked in this order:
//  1. the connecting cards ([registerConnect]; connect_cards.dart) — password, 2-step code,
//     busy, offline, denied, timeout, network error, also before the session is up;
//  2. the session layers ([register]; layer_controller.dart) — weak / lost / ended.
// Sürüm 12 (FO-A12): [reconnect] carries the lost card's attempt count to the top bar.
import 'package:flutter/foundation.dart';

typedef SenseMessageHandler = bool Function(String type, String title, String text);

/// Sürüm 12 (#164): the connecting cards also need RustDesk's own retry flag.
typedef SenseConnectHandler = bool Function(String type, String title, String text, bool hasRetry);

/// Sürüm 12 (FO-A12): reconnect attempts while the link is lost.
@immutable
class SenseReconnectInfo {
  const SenseReconnectInfo({required this.attempt, required this.closeIn});

  /// Real attempts made so far (0 = the first one is on its way).
  final int attempt;

  /// Seconds until the session closes.
  final int closeIn;

  @override
  bool operator ==(Object other) =>
      other is SenseReconnectInfo && other.attempt == attempt && other.closeIn == closeIn;

  @override
  int get hashCode => Object.hash(attempt, closeIn);
}

abstract final class SenseSessionHub {
  static final Map<String, SenseMessageHandler> _handlers = {};
  static final Map<String, SenseConnectHandler> _connect = {};
  static final Map<String, VoidCallback> _connecting = {};
  static final Map<String, ValueNotifier<SenseReconnectInfo?>> _reconnect = {};

  static void register(String peerId, SenseMessageHandler handler) =>
      _handlers[peerId] = handler;

  static void unregister(String peerId, SenseMessageHandler handler) {
    // P3 (B10): a method torn off twice is `==` but not `identical`.
    if (_handlers[peerId] == handler) _handlers.remove(peerId);
  }

  /// Sürüm 12 (#164): the connecting cards of a window; [onConnecting] shows "Bağlanılıyor"
  /// where RustDesk would open its "Connecting…" box (reconnect).
  static void registerConnect(String peerId, SenseConnectHandler handler, {VoidCallback? onConnecting}) {
    _connect[peerId] = handler;
    if (onConnecting != null) {
      _connecting[peerId] = onConnecting;
    } else {
      _connecting.remove(peerId);
    }
  }

  static void unregisterConnect(String peerId, SenseConnectHandler handler) {
    if (_connect[peerId] != handler) return;
    _connect.remove(peerId);
    _connecting.remove(peerId);
  }

  /// True = Sense took the message; RustDesk shows nothing.
  static bool onMessage(String peerId, String type, String title, String text, {bool hasRetry = false}) {
    if (_connect[peerId]?.call(type, title, text, hasRetry) ?? false) return true;
    return _handlers[peerId]?.call(type, title, text) ?? false;
  }

  /// Sürüm 12 (#164): RustDesk is about to show "Connecting…". True = the Sense card shows it.
  static bool onConnecting(String peerId) {
    final f = _connecting[peerId];
    if (f == null) return false;
    f();
    return true;
  }

  /// Sürüm 12 (FO-A12): attempts of the lost card for [peerId] (null = not reconnecting).
  /// The top bar listens; the layer controller sets it every tick.
  static ValueListenable<SenseReconnectInfo?> reconnect(String peerId) =>
      _reconnect.putIfAbsent(peerId, () => ValueNotifier(null));

  static void setReconnect(String peerId, SenseReconnectInfo? info) {
    final n = _reconnect[peerId];
    if (n == null) {
      if (info == null) return;
      _reconnect[peerId] = ValueNotifier(info);
      return;
    }
    n.value = info;
  }

  /// The window closed: nothing is reconnecting any more. The notifier stays (a listener may
  /// still hold it) and is reused by the next window of the same computer.
  static void forget(String peerId) => _reconnect[peerId]?.value = null;
}
