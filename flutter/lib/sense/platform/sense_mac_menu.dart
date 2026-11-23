// Sense Remote (D3f): the macOS app menu. "Sense Remote Hakkında" (MainMenu.xib →
// AppDelegate.senseShowAbout) sends `showAbout` on this channel to the main
// window; the window comes to the front and the open shell shows its Hakkında
// page (router.dart `senseShowAbout`). There is no "Ayarlar…" item.
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../../common.dart' show windowOnTop;
import '../router.dart' show senseShowAbout;

const _kChannel = MethodChannel('org.rustdesk.rustdesk/sense_menu');

/// main.dart calls it once for the main window (macOS only).
void senseListenMacMenu() {
  if (!Platform.isMacOS) return;
  _kChannel.setMethodCallHandler((call) async {
    if (call.method != 'showAbout') return null;
    await windowOnTop(null);
    senseShowAbout();
    return null;
  });
}
