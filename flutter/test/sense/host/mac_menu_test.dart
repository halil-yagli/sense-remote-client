// Sense Remote (D3f): the macOS app menu. "Sense Remote Hakkında" goes to the
// Sense About page (XIB action → AppDelegate → channel → router), the
// non-working "Ayarlar…" item is gone.
import 'dart:io';

import 'package:flutter_hbb/sense/router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = 'org.rustdesk.rustdesk/sense_menu';

  test('menu: About calls the app delegate, no Ayarlar item', () {
    final xib = File('macos/Runner/Base.lproj/MainMenu.xib').readAsStringSync();
    expect(xib, contains('<action selector="senseShowAbout:" target="Voe-Tx-rLC"'));
    expect(xib, isNot(contains('orderFrontStandardAboutPanel:')));
    expect(xib, isNot(contains('Ayarlar')));
    expect(xib, isNot(contains('keyEquivalent=","')));
    // Voe-Tx-rLC is the AppDelegate object.
    expect(xib, contains('<customObject id="Voe-Tx-rLC" customClass="AppDelegate"'));
  });

  test('the delegate and Dart use the same channel and method', () {
    final swift = File('macos/Runner/AppDelegate.swift').readAsStringSync();
    expect(swift, contains('@IBAction func senseShowAbout(_ sender: Any?)'));
    expect(swift, contains('name: "$channel"'));
    expect(swift, contains('invokeMethod("showAbout"'));
    final dart = File('lib/sense/platform/sense_mac_menu.dart').readAsStringSync();
    expect(dart, contains("MethodChannel('$channel')"));
    expect(dart, contains("call.method != 'showAbout'"));
    expect(File('lib/main.dart').readAsStringSync(), contains('senseListenMacMenu();'));
  });

  test('both shells follow the About request', () {
    for (final path in [
      'lib/sense/screens/host/shell/host_shell.dart',
      'lib/sense/screens/controller/shell/controller_shell.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src, contains('senseAboutRequest.addListener(_showAbout)'), reason: path);
      expect(src, contains('senseAboutRequest.removeListener(_showAbout)'), reason: path);
    }
    final before = senseAboutRequest.value;
    var heard = 0;
    void listener() => heard++;
    senseAboutRequest.addListener(listener);
    senseShowAbout();
    senseAboutRequest.removeListener(listener);
    expect(senseAboutRequest.value, before + 1);
    expect(heard, 1);
  });
}
