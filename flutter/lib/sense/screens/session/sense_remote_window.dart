// Sense Remote: glue between the connection window (remote_page.dart,
// remote_toolbar.dart) and the Sense parts. The bar, island and lists sit above the
// remote screen (bar/, via remote_tab_page.dart); this file puts the layer over the
// remote screen: the right popups (Bilgisayar durumu, Ekran bilgisi) and the chat,
// which share one popup place (T7), plus the display map and ghost helpers.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common.dart' show openMonitorInNewTabOrWindow, openMonitorInTheSameTab;
import '../../../common/shared_state.dart';
import '../../../common/widgets/toolbar.dart'
    show TToggleMenu, allowDisplaySwitchInPrivacyMode;
import '../../../consts.dart' show kAllDisplayValue;
import '../../../models/model.dart';
import '../../../models/platform_model.dart';
import '../../components/popup_host.dart';
import 'bar/session_popups.dart';
import 'chat_icon/session_chat.dart';
import 'data/peer_status.dart';
import 'data/session_state.dart';
import 'sense_remote_map.dart';

/// Per-connection Sense state; dropped when the connection page closes.
abstract final class SenseRemoteSession {
  static void remove(String id) {
    SenseSessionPopups.remove(id);
    SensePeerStatusFeed.remove(id);
    SenseSessionEvents.remove(id);
  }
}

/// RustDesk displays of the peer, in RustDesk index order.
List<SenseMapDisplay> senseMapDisplays(PeerInfo pi) => [
      for (var i = 0; i < pi.displays.length; i++)
        SenseMapDisplay(
          index: i,
          x: pi.displays[i].x,
          y: pi.displays[i].y,
          width: pi.displays[i].width,
          height: pi.displays[i].height,
          primary: pi.primaryDisplay == i,
        ),
    ];

/// Same behaviour as the stock monitor buttons (_MonitorMenu.onPressed).
void senseOpenDisplay(int i, String id, FFI ffi) {
  final pi = ffi.ffiModel.pi;
  if (CurrentDisplayState.find(id).value == i) return;
  final individual = pi.isSupportMultiDisplay &&
      bind.sessionGetDisplaysAsIndividualWindows(sessionId: ffi.sessionId) ==
          'Y';
  if (individual && i != kAllDisplayValue) {
    openMonitorInNewTabOrWindow(i, ffi.id, pi);
  } else {
    openMonitorInTheSameTab(i, ffi, pi);
  }
}

/// Toolbar: display map + "Tümü". Shown under the same rule as the stock
/// monitor menu in privacy mode.
class SenseRemoteToolbarMap extends StatelessWidget {
  const SenseRemoteToolbarMap(
      {super.key, required this.id, required this.ffi, this.vertical = false});
  final String id;
  final FFI ffi;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final pi = ffi.ffiModel.pi;
      final privacy = PrivacyModeState.find(id);
      final count = pi.displaysCount.value;
      final current = CurrentDisplayState.find(id).value;
      if (count < 1 ||
          !(privacy.isEmpty ||
              allowDisplaySwitchInPrivacyMode(pi, privacy.value))) {
        return const Offstage();
      }
      final displays = senseMapDisplays(pi);
      return SenseRemoteMapBar(
        displays: displays,
        current: current,
        vertical: vertical,
        // Same rule as the stock "All monitors" button.
        allowAll: pi.isSupportMultiDisplay,
        onPick: (i) => senseOpenDisplay(i, id, ffi),
      );
    });
  }
}

/// What the ghost button does: turn the active privacy mode off, or the first
/// available one on. Null when RustDesk offers no privacy mode (no permission,
/// unsupported peer, view only). Pure; covered by tests.
VoidCallback? senseGhostToggle(List<TToggleMenu> menus, bool on) {
  if (menus.isEmpty) return null;
  if (on) {
    for (final m in menus) {
      final change = m.onChanged;
      if (m.value && change != null) return () => change(false);
    }
    final first = menus.first.onChanged;
    return first == null ? null : () => first(false);
  }
  for (final m in menus) {
    final change = m.onChanged;
    if (change != null) return () => change(true);
  }
  return null;
}

/// Layer above the remote image: the right popups and the chat. Empty areas let the
/// pointer through to the remote image.
class SenseRemoteOverlay extends StatelessWidget {
  const SenseRemoteOverlay({super.key, required this.id, required this.ffi});
  final String id;
  final FFI ffi;

  @override
  Widget build(BuildContext context) {
    final popups = SenseSessionPopups.of(id, ffi);
    return SensePopupHost(
      controller: popups.controller,
      child: SenseSessionChat(
        ffi: ffi,
        computerName: ffi.ffiModel.pi.hostname,
        popups: popups.controller,
        iconPlacement: popups.chatIcon,
      ),
    );
  }
}
