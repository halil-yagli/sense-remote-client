// Sense Remote: shared test setup (İnşa planı §5). Every test file gets the
// bundled Poppins, so the golden images show the real type. It replaces the
// copies of `_loadFonts()` the golden tests used to carry.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final loader = FontLoader('Poppins');
  for (final w in ['ExtraLight', 'Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('assets/fonts/Poppins-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
  await testMain();
}
