// Sense Remote: live check list of the new permanent password (YH H2, prototype
// `.rules`). The same rule as the service (src/sense/password/rule.rs: charset,
// length, repeated/sequence, contains_id); the service still decides on Kaydet
// (it also refuses common words). Pure, so every line is tested.
import '../../../strings/host.dart';

const int kSensePasswordMin = 12, kSensePasswordMax = 64, kSensePasswordMinDistinct = 6;

/// One line of the list: null = nothing typed yet, true = met, false = not met.
class SensePasswordRuleLine {
  const SensePasswordRuleLine(this.text, this.met);
  final String text;
  final bool? met;
}

bool _charsetOk(String p) => p.codeUnits.every((c) => c >= 0x21 && c <= 0x7e);

int _next(int c) {
  if (c == 0x39) return 0x30; // 9 → 0
  if (c == 0x7a) return 0x61; // z → a
  if (c == 0x5a) return 0x41; // Z → A
  return c + 1;
}

/// Fewer than 6 different characters, or one long ascending / descending run.
bool senseRepeatedOrSequence(String p) {
  final b = p.codeUnits;
  if (b.toSet().length < kSensePasswordMinDistinct) return true;
  if (b.length < 2) return false;
  var up = true, down = true;
  for (var i = 1; i < b.length; i++) {
    if (b[i] != _next(b[i - 1])) up = false;
    if (b[i - 1] != _next(b[i])) down = false;
  }
  return up || down;
}

List<SensePasswordRuleLine> sensePasswordRuleLines(String password, String repeat, String id) {
  final typed = password.isNotEmpty;
  bool? line(bool ok) => typed ? ok : null;
  return [
    SensePasswordRuleLine(SenseHostStrings.ruleLength,
        line(password.length >= kSensePasswordMin && password.length <= kSensePasswordMax)),
    SensePasswordRuleLine(SenseHostStrings.ruleCharset, line(_charsetOk(password))),
    SensePasswordRuleLine(SenseHostStrings.ruleSequence, line(!senseRepeatedOrSequence(password))),
    SensePasswordRuleLine(SenseHostStrings.ruleId, line(id.isEmpty || !password.contains(id))),
    SensePasswordRuleLine(SenseHostStrings.ruleSame, repeat.isEmpty ? null : password == repeat),
  ];
}

/// Kaydet is on only when every line is met.
bool sensePasswordRulesMet(String password, String repeat, String id) =>
    sensePasswordRuleLines(password, repeat, id).every((l) => l.met == true);
