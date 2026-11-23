// Sense Remote: shared setup of the B4 tests (Settings, About, update, tray).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

export '../components_a/harness.dart' show pumpSense, kSenseMinScreen;

/// Golden images are rendered on the Linux CI runner (no local Flutter). An image
/// that was not generated yet is skipped instead of failing `PR kontrolu`; the golden
/// job (`--update-goldens`) creates it, and from then on it is compared.
const String kGoldenDir = 'test/goldens/controller_settings';

bool goldenSkip(String name) =>
    !Platform.isLinux || (!autoUpdateGoldenFiles && !File('$kGoldenDir/$name.png').existsSync());

/// Path for matchesGoldenFile, relative to the test files in this folder.
String goldenPath(String name) => '../../goldens/controller_settings/$name.png';
