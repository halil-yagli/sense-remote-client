// Sense Remote (T1/T2): no stock RustDesk blue accent and no WorkSans in the app code.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no WorkSans and no stock accent blue in lib/', () {
    final problems = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      if (text.contains('WorkSans')) problems.add('${f.path}: WorkSans');
      if (RegExp(r'Color\(0x[0-9A-Fa-f]{2}0071FF\)').hasMatch(text)) {
        problems.add('${f.path}: 0071FF');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
