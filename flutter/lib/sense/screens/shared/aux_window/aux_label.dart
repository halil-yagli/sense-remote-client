// Sense Remote: names in the secondary windows' tabs and titles (ST 16): the
// computer's alias or host name, never its ID; Turkish window titles.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../common.dart' show kUseCompatibleUiMode;
import '../../../../common/sense_theme.dart' show senseRoleInstalled;
import '../../../../models/platform_model.dart';
import '../../../strings/common.dart';
import '../../../strings/files.dart';

/// The computer's name for a tab and the window title: its alias, else the host
/// name the peer reported, else "Uzak bilgisayar". Never the ID (ST 16).
String senseAuxPeerLabel(String peerId) {
  try {
    final alias = bind.mainGetPeerOptionSync(id: peerId, key: 'alias');
    return senseAuxLabelFrom(alias: alias, peerJson: bind.mainGetPeerSync(id: peerId));
  } catch (_) {
    return SenseAuxStrings.unnamedComputer;
  }
}

/// Pure part of [senseAuxPeerLabel] (tests).
@visibleForTesting
String senseAuxLabelFrom({required String alias, required String peerJson}) {
  if (alias.trim().isNotEmpty) return alias.trim();
  try {
    final decoded = jsonDecode(peerJson);
    final info = decoded is Map ? (decoded['info'] as Map? ?? const {}) : const {};
    final host = info['hostname'];
    if (host is String && host.trim().isNotEmpty) return host.trim();
  } catch (_) {}
  return SenseAuxStrings.unnamedComputer;
}

/// Whether the secondary windows draw the Sense frame (role installed, desktop).
bool senseAuxFrameOn() => senseRoleInstalled() && !kUseCompatibleUiMode;

/// Window title for Alt+Tab / taskbar: "Uzak dosyalar · Giriş Salonu PC-2 — Sense Remote".
String senseAuxWindowTitle(String kind, String peerId) =>
    SenseAuxStrings.windowTitle(kind, senseAuxPeerLabel(peerId), SenseCommonStrings.appName);

