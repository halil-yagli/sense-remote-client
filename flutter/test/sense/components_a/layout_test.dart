// Sense Remote: nothing overflows on the smallest target screens (YH T3, T9; A2a).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gallery.dart';
import 'harness.dart';

void main() {
  for (final size in const [Size(1280, 720), Size(1366, 768), Size(1500, 800), Size(1299, 799)]) {
    testWidgets('all components fit at ${size.width.toInt()}×${size.height.toInt()}', (tester) async {
      await pumpSense(tester, galleryAll(), size: size, center: false);
      expect(tester.takeException(), isNull);
    });
  }
}
