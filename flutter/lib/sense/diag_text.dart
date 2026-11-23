// Sense Remote (karar #86): the pure parts of the Dart diagnostic log (no bridge import, so
// tests can use them).

/// Longest line handed to Rust (it cuts at 4000 characters as well).
const int kSenseDiagMaxLine = 4000;

/// Pure: `text` cut to `max` characters (lines that are too long would fill the log).
String senseDiagTruncate(String text, [int max = kSenseDiagMaxLine]) =>
    text.length <= max ? text : text.substring(0, max);

/// Pure: one error as one log text: kind, message and the stack.
String senseDiagError(String kind, Object error, StackTrace? stack) =>
    '$kind: $error${stack == null ? '' : '\n$stack'}';
