// Sense Remote: screens take colours, sizes and fonts only from the library
// (İnşa planı §4.1; YH T1, T2). In lib/sense/screens/** these are not allowed:
//   - a raw colour `Color(0x...)`,
//   - the old colour classes (SenseTokens, SenseCmTokens, SenseThemeColors, SenseRemoteTokens),
//   - a number font size `fontSize: 12`.
// Files written before the library still have some; their count may only go down
// (B and C rewrite them, then remove the line from [_legacy]). New files must be clean.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _rules = <String, RegExp>{
  'raw colour Color(0x…)': RegExp(r'Color\(0x'),
  'old colour class': RegExp(r'\b(SenseTokens|SenseCmTokens|SenseThemeColors|SenseRemoteTokens)\b'),
  'number fontSize': RegExp(r'fontSize:\s*[0-9]'),
};

/// Count per legacy file on 2026-11-23 (A2a). Only lower is allowed.
const _legacy = <String, int>{
  'lib/sense/screens/controller/sense_update_view.dart': 1,
  'lib/sense/screens/host/sense_home_mac.dart': 1,
  'lib/sense/screens/host/sense_password_page.dart': 1,
  'lib/sense/screens/host_live/sense_cm_panel.dart': 35,
  'lib/sense/screens/host_live/sense_cm_style.dart': 1,
  'lib/sense/screens/host_live/sense_cm_widgets.dart': 32,
  'lib/sense/screens/install/sense_install_layout.dart': 58,
  'lib/sense/screens/install/sense_install_model.dart': 1,
  'lib/sense/screens/install/sense_install_page.dart': 2,
  'lib/sense/screens/install/sense_install_steps_account.dart': 28,
  'lib/sense/screens/install/sense_install_steps_finish.dart': 18,
  'lib/sense/screens/install/sense_install_steps_info.dart': 43,
  'lib/sense/screens/install/sense_install_steps_mac.dart': 18,
  'lib/sense/screens/install/sense_install_steps_upgrade.dart': 6,
  'lib/sense/screens/install/sense_install_wizard.dart': 16,
  'lib/sense/screens/session/sense_remote_map.dart': 16,
  'lib/sense/screens/session/sense_remote_strings.dart': 1,
  'lib/sense/screens/session/sense_remote_window.dart': 12,
};

/// Findings of one file: "line: rule". Comment lines do not count.
List<String> findings(String source) {
  final out = <String>[];
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('//')) continue;
    _rules.forEach((name, re) {
      for (final _ in re.allMatches(line)) {
        out.add('${i + 1}: $name');
      }
    });
  }
  return out;
}

void main() {
  test('the rules catch what they should (and not comments)', () {
    expect(findings('final c = Color(0xFF0071FF);'), hasLength(1));
    expect(findings('style: TextStyle(fontSize: 12)'), hasLength(1));
    expect(findings('style: TextStyle(fontSize: SenseFontSize.body)'), isEmpty);
    expect(findings('typedef _T = SenseCmTokens;'), hasLength(1));
    expect(findings('// Color(0xFF000000) in a comment'), isEmpty);
    expect(findings('SenseColors.text'), isEmpty);
  });

  test('screens use only the library (legacy files only shrink)', () {
    final dir = Directory('lib/sense/screens');
    expect(dir.existsSync(), isTrue, reason: 'run from the flutter/ folder');
    final problems = <String>[];
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final path = f.path.replaceAll(r'\', '/');
      final found = findings(f.readAsStringSync());
      final allowed = _legacy[path] ?? 0;
      if (found.length > allowed) {
        problems.add('$path: ${found.length} (allowed $allowed)\n  ${found.join('\n  ')}');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
