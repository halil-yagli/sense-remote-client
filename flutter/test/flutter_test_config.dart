// Sense Remote: shared test setup (İnşa planı §5). Every test file gets:
//  - the bundled Poppins, so the golden images show the real type;
//  - the Material icon font (`Icons.*`), so icons are drawn instead of boxes (G2);
//  - real soft shadows. Flutter's automated test binding turns blur off
//    (`debugDisableShadows`), which drew every popup / list shadow as a hard dark
//    block under the frame (G6). The goldens run on one CI image, so blur is stable.
// It replaces the copies of `_loadFonts()` the golden tests used to carry.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The automated binding with shadows on. Created before any test, so
/// `TestWidgetsFlutterBinding.ensureInitialized()` returns this one.
class _SenseTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  _SenseTestBinding();

  final poppins = FontLoader('Poppins');
  for (final w in ['ExtraLight', 'Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('assets/fonts/Poppins-$w.ttf').readAsBytesSync();
    poppins.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await poppins.load();

  final icons = await _materialIcons();
  if (icons != null) {
    await (FontLoader('MaterialIcons')..addFont(Future.value(icons))).load();
  } else {
    // Not fatal for behaviour tests; goldens would show boxes again.
    stderr.writeln('flutter_test_config: MaterialIcons-Regular.otf bulunamadı; simgeler kutu çizilir.');
  }

  await testMain();
}

/// The icon font: first from the test asset bundle (`uses-material-design: true`
/// puts it there), then from the Flutter SDK cache. Works on Linux CI and Windows.
Future<ByteData?> _materialIcons() async {
  try {
    final data = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
    if (data.lengthInBytes > 0) return data;
  } catch (_) {}

  const rel = ['bin', 'cache', 'artifacts', 'material_fonts', 'MaterialIcons-Regular.otf'];
  final roots = <String>[
    if (Platform.environment['FLUTTER_ROOT'] case final r?) r,
  ];
  // flutter_tester lives in <root>/bin/cache/artifacts/engine/<platform>/.
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    roots.add(dir.path);
    dir = dir.parent;
  }
  for (final root in roots) {
    for (final candidate in [
      [root, ...rel].join(Platform.pathSeparator),
      [root, 'material_fonts', 'MaterialIcons-Regular.otf'].join(Platform.pathSeparator),
    ]) {
      final f = File(candidate);
      if (f.existsSync()) {
        final bytes = f.readAsBytesSync();
        return ByteData.view(bytes.buffer);
      }
    }
  }
  return null;
}
