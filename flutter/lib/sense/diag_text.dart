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

// ---- interface events (karar #103) ----
//
// One interface event is one line: `[ui] <kind> key=value key="a value"`. The panel filters on
// the `[ui]` prefix and the kind. Only names go in (screen, popup, button, setting key, display
// number); never what a person typed, the chat, a file, the screen or the clipboard (workshop
// CLAUDE.md, Security). Values of fields whose name looks secret are masked, and so is anything
// that looks like an e-mail address.

/// Prefix of every interface event line.
const String kSenseUiPrefix = '[ui]';

/// Longest value of one field (a name, never content).
const int kSenseUiMaxValue = 120;

/// Written instead of a masked value.
const String kSenseUiMasked = '***';

final RegExp _secretKey = RegExp(
    r'pass|pwd|token|secret|e-?mail|otp|api_?key|private|credential|cookie|session_?(key|token|cookie|secret|auth)',
    caseSensitive: false);

/// Names that are secrets only as a whole word (`pin`, `auth_code`, `twoFa`, `salt`): a plain
/// substring would also hide `typing`, `mapping`, `author`. A session *id* is not a secret.
const Set<String> _secretWords = {'pin', '2fa', 'otp', 'salt', 'auth', 'secret', 'cookie'};
final RegExp _wordBreak = RegExp(r'[^A-Za-z0-9]+|(?<=[a-z0-9])(?=[A-Z])');
final RegExp _email = RegExp(r'[^\s@"=]+@[^\s@"=]+\.[^\s@"=]+');

/// Pure: a field whose name says it holds a password, PIN, 2FA code, token, key, salt, cookie
/// or e-mail.
bool senseUiSecretKey(String key) =>
    _secretKey.hasMatch(key) ||
    key.split(_wordBreak).any((w) => _secretWords.contains(w.toLowerCase()));

/// Pure: one field value as one short, single-line text (e-mail addresses masked).
String senseUiValue(Object? value) {
  var text = value == null ? '-' : value.toString();
  text = text.replaceAll(RegExp(r'[\r\n\t]+'), ' ').replaceAll('"', "'").trim();
  text = text.replaceAll(_email, kSenseUiMasked);
  if (text.length > kSenseUiMaxValue) text = '${text.substring(0, kSenseUiMaxValue)}…';
  if (text.isEmpty) return '""';
  return text.contains(' ') || text.contains('=') ? '"$text"' : text;
}

/// Pure: `[ui] kind a=1 b="x y"`; secret looking fields are masked.
String senseUiLine(String kind, [Map<String, Object?> fields = const {}]) {
  final b = StringBuffer('$kSenseUiPrefix ${senseUiValue(kind)}');
  fields.forEach((key, value) {
    b.write(' $key=');
    b.write(senseUiSecretKey(key) ? kSenseUiMasked : senseUiValue(value));
  });
  return senseDiagTruncate(b.toString());
}

/// Pure: a setting change "eski→yeni"; the values of a secret setting are never written.
String senseUiSettingLine(String key, Object? from, Object? to, {String? where}) {
  final secret = senseUiSecretKey(key);
  return senseUiLine('setting', {
    'key': key,
    if (where != null) 'where': where,
    'from': secret ? kSenseUiMasked : from,
    'to': secret ? kSenseUiMasked : to,
  });
}

/// Pure: a rectangle as `x,y wxh` (whole pixels).
String senseUiRect(double left, double top, double width, double height) =>
    '${left.round()},${top.round()} ${width.round()}x${height.round()}';

/// Pure: a size as `wxh`.
String senseUiSize(double width, double height) => '${width.round()}x${height.round()}';
