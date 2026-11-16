// Sense Remote: window side of the Host-side connection icon.
//
// RustDesk shows a 300x490 connection manager window on the controlled
// computer. Sense Remote replaces it (Windows first) with a small, draggable,
// always-on-top icon; clicking it opens a card in the same window. The window
// is only resized and moved here, never hidden while a connection is active:
// the connection must stay visible on the controlled side (workshop
// CLAUDE.md, Security).
//
// MAC-SONRA: macOS keeps the RustDesk window until the icon is tried on a Mac
// (window level, Stage Manager and Spaces behave differently there).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

import '../../common.dart';
import '../../models/platform_model.dart';
import 'sense_cm_geometry.dart';

class SenseCm {
  SenseCm._();

  /// Icon mode on this platform. Win7 compatible mode keeps a normal title
  /// bar, where a 52 px window would not fit, so it keeps the old window.
  static bool get enabled =>
      _enabledOverride ?? (isWindows && !kUseCompatibleUiMode);
  static bool? _enabledOverride;

  @visibleForTesting
  static set enabledForTest(bool? value) => _enabledOverride = value;

  /// The card is open (the window is card sized).
  static final RxBool open = false.obs;

  /// Connection shown in the card; -1 picks the first one.
  static final RxInt selected = (-1).obs;

  /// When each connection was first seen authorized, for "bağlı · 03:42".
  static final Map<int, DateTime> connectedSince = {};

  static SenseCmAnchor _anchor = SenseCmAnchor.bottomRight;
  static bool _busy = false;

  /// True when a chat message for [connId] is on screen right now.
  static bool isShowingChat(int connId) =>
      open.value && (selected.value == connId || selected.value < 0);

  /// Shows the collapsed icon at its remembered place (bottom right first).
  static Future<void> showIcon() async {
    open.value = false;
    final screens = await _workAreas();
    final remembered = parseSenseCmPosition(
        bind.mainGetLocalOption(key: kSenseCmPositionOption));
    final area =
        senseCmWorkAreaFor(remembered, screens.map((s) => s.$1).toList());
    if (area != null && remembered != null) {
      final scale = screens.firstWhere((s) => s.$1 == area).$2;
      final size = kSenseCmIconSize * scale;
      await _setBounds(clampSenseCmRect(
          Rect.fromLTWH(remembered.dx, remembered.dy, size.width, size.height),
          area));
      return;
    }
    final current = await _currentWorkArea(screens);
    if (current == null) {
      await windowManager.setSize(kSenseCmIconSize);
      return;
    }
    final (work, scale) = current;
    await _setBounds(senseCmDefaultIconRect(
        work, kSenseCmIconSize * scale, kSenseCmMargin * scale));
  }

  /// Opens the card out of the icon.
  static Future<void> openPanel() async {
    if (open.value || _busy) return;
    _busy = true;
    try {
      final info = await _windowInfo();
      if (info != null) {
        final (frame, area, scale) = info;
        _anchor = senseCmAnchorFor(frame, area);
        await _setBounds(senseCmPanelRect(
            frame, kSenseCmPanelSize * scale, area, _anchor));
      } else {
        await windowManager.setSize(kSenseCmPanelSize);
      }
      open.value = true;
      await windowManager.focus();
    } finally {
      _busy = false;
    }
  }

  /// "Gizle": closes the card, the icon stays where the card was opened.
  static Future<void> closePanel() async {
    if (!open.value || _busy) return;
    _busy = true;
    try {
      open.value = false;
      final info = await _windowInfo();
      if (info != null) {
        final (frame, area, scale) = info;
        final rect = senseCmIconRectFromPanel(
            frame, kSenseCmIconSize * scale, area, _anchor);
        await _setBounds(rect);
        _remember(rect.topLeft);
      } else {
        await windowManager.setSize(kSenseCmIconSize);
      }
    } finally {
      _busy = false;
    }
  }

  static Future<void> toggle() => open.value ? closePanel() : openPanel();

  /// Called after the user dragged the window.
  static Future<void> onMoved() async {
    if (open.value || _busy) return;
    final info = await _windowInfo();
    if (info != null) _remember(info.$1.topLeft);
  }

  static void _remember(Offset topLeft) {
    bind.mainSetLocalOption(
        key: kSenseCmPositionOption, value: formatSenseCmPosition(topLeft));
  }

  static Future<void> _setBounds(Rect rect) async {
    // Window sizes below the system minimum track size get clamped by
    // Windows; the window manager reports this minimum instead.
    await windowManager.setMinimumSize(kSenseCmIconSize);
    await windowManager.setBounds(rect, ignoreDevicePixelRatio: true);
  }

  /// (work area, scale factor) of every monitor, physical pixels; the
  /// primary monitor (the one at the origin on Windows) comes first.
  static Future<List<(Rect, double)>> _workAreas() async {
    try {
      final list = [...await window_size.getScreenList()];
      list.sort((a, b) => (a.frame.topLeft == Offset.zero ? 0 : 1)
          .compareTo(b.frame.topLeft == Offset.zero ? 0 : 1));
      return list.map((s) => (s.visibleFrame, s.scaleFactor)).toList();
    } catch (e) {
      debugPrint('Sense CM: screen list failed: $e');
      return [];
    }
  }

  /// First start: the primary monitor; without a screen list, the monitor
  /// the window is on.
  static Future<(Rect, double)?> _currentWorkArea(
      List<(Rect, double)> screens) async {
    if (screens.isNotEmpty) return screens.first;
    final info = await _windowInfo();
    return info == null ? null : (info.$2, info.$3);
  }

  /// (window frame, work area of its monitor, scale), physical pixels.
  static Future<(Rect, Rect, double)?> _windowInfo() async {
    try {
      final window = await window_size.getWindowInfo();
      final screen = window.screen;
      if (screen == null) return null;
      return (window.frame, screen.visibleFrame, window.scaleFactor);
    } catch (e) {
      debugPrint('Sense CM: window info failed: $e');
      return null;
    }
  }
}
