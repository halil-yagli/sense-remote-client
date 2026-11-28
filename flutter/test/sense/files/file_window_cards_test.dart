// The file transfer window mounts the Sense connecting cards (#164, plan §2.5): a failed
// login there (offline, wrong password, busy) must reach a card, never RustDesk's box.
// A read of the source (fast, no device); the same rule the wiring guard of #160 holds.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/desktop/pages/file_manager_page.dart').readAsStringSync().replaceAll('\r\n', '\n');

  test('the window attaches the file card layer and removes it on close', () {
    expect(RegExp(r'SenseConnectCards\.attach\(widget\.id,\s*kind: SenseConnectKind\.file').hasMatch(src), isTrue);
    expect(src, contains('SenseConnectCards.remove(widget.id)'));
  });

  test('the stock "Connecting..." box shows only without the Sense window', () {
    expect(src, isNot(contains("showLoading(translate('Connecting...')")));
    final i = src.indexOf("translate('Connecting...')");
    expect(i, isNonNegative, reason: 'the stock fallback stays (nothing deleted)');
    expect(src.substring(src.lastIndexOf('\n', i - 120), i), contains('!senseRoleInstalled()'));
  });
}
