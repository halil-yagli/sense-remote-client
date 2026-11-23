// Sense Remote: where RustDesk's session events reach the connection layers (YH O14).
// models/model.dart hands every message box to [SenseSessionHub.onMessage] first; a
// session-ending one is taken here (Sense shows its own card instead of the RustDesk
// dialog). Kept free of Flutter so model.dart only gains one import and one line.

typedef SenseMessageHandler = bool Function(String type, String title, String text);

abstract final class SenseSessionHub {
  static final Map<String, SenseMessageHandler> _handlers = {};

  static void register(String peerId, SenseMessageHandler handler) =>
      _handlers[peerId] = handler;

  static void unregister(String peerId, SenseMessageHandler handler) {
    if (identical(_handlers[peerId], handler)) _handlers.remove(peerId);
  }

  /// True = Sense took the message; RustDesk shows nothing.
  static bool onMessage(String peerId, String type, String title, String text) =>
      _handlers[peerId]?.call(type, title, text) ?? false;
}
