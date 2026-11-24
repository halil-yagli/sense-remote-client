// Sense Remote: window side of the Host-side Sense icon (YH H3, H4).
//
// RustDesk shows a 300x490 connection manager window on the controlled
// computer. Sense Remote replaces it (Windows and macOS) with a small,
// draggable, always-on-top icon (64 × 64 area, transparent logo); clicking it
// opens the card in the same window. Dropped at the left or right screen edge
// it becomes an 18 × 52 tab there; pressing the tab brings the icon back.
// The window is only resized and moved here, never hidden while a connection
// is active: the connection must stay visible on the controlled side
// (workshop CLAUDE.md, Security).
//
// macOS (plan 2026-11-21, M6): the icon is placed in points inside
// `NSScreen.visibleFrame` (no menu bar, no Dock), follows the user to every
// Space and stays above full screen apps. Stage Manager is checked on a Mac.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

import '../../../common.dart';
import '../../../models/platform_model.dart';
import '../../window/sense_window_scale.dart';
import 'sense_cm_geometry.dart';
import 'sense_cm_region.dart';

class SenseCm {
  SenseCm._();

  /// Icon mode on this platform (see [senseCmEnabledOn]).
  static bool get enabled =>
      _enabledOverride ??
      senseCmEnabledOn(
          windows: isWindows,
          macOS: isMacOS,
          compatibleUi: kUseCompatibleUiMode);
  static bool? _enabledOverride;

  @visibleForTesting
  static set enabledForTest(bool? value) => _enabledOverride = value;

  /// The card is open (the window is card sized).
  static final RxBool open = false.obs;

  /// The icon is an edge tab (H3 "Kenara saklı"); null = normal icon.
  static final Rxn<SenseCmEdge> edge = Rxn<SenseCmEdge>();

  /// Connection shown in the card; -1 picks the first one.
  static final RxInt selected = (-1).obs;

  /// When each connection was first seen authorized, for "bağlı · 03:42".
  static final Map<int, DateTime> connectedSince = {};

  static SenseCmAnchor _anchor = SenseCmAnchor.bottomRight;

  /// Corner the open card is pinned to (it grows away from it).
  static SenseCmAnchor get anchor => _anchor;
  static bool _busy = false;

  /// True when a chat message for [connId] is on screen right now.
  static bool isShowingChat(int connId) =>
      open.value && (selected.value == connId || selected.value < 0);

  /// Shows the collapsed icon at its remembered place (bottom right first).
  static Future<void> showIcon() async {
    open.value = false;
    edge.value = null;
    await _prepareMacWindow();
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

  /// Opens the card out of the icon (from the edge tab it opens beside the
  /// icon's way back).
  static Future<void> openPanel() async {
    if (open.value || _busy) return;
    if (edge.value != null) await restoreFromEdge();
    _busy = true;
    try {
      final info = await _windowInfo();
      if (info != null) {
        final (frame, area, scale) = info;
        _anchor = senseCmAnchorFor(frame, area);
        open.value = true;
        await _setBounds(senseCmPanelRect(
            frame, kSenseCmPanelSize * scale, area, _anchor));
      } else {
        open.value = true;
        await windowManager.setSize(kSenseCmPanelSize);
      }
      await windowManager.focus();
    } finally {
      _busy = false;
    }
  }

  /// "–": closes the card, the icon stays where the card was opened.
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

  /// Called after the user dragged the window. Dropped at the left or right
  /// edge, the icon becomes the edge tab.
  static Future<void> onMoved() async {
    if (open.value || _busy || edge.value != null) return;
    final info = await _windowInfo();
    if (info == null) return;
    final (frame, area, scale) = info;
    final side = senseCmEdgeFor(frame, area, kSenseCmEdgeSnap * scale);
    if (side == null) {
      _remember(frame.topLeft);
      return;
    }
    _busy = true;
    try {
      final tab = senseCmEdgeRect(frame, area, side, kSenseCmEdgeSize * scale,
          kSenseCmEdgeTopShift * scale);
      edge.value = side;
      await _setBounds(tab);
      // The next connection shows the icon where the tab gives it back.
      _remember(senseCmIconFromEdge(tab, area, side, kSenseCmIconSize * scale,
              kSenseCmEdgeInset * scale, kSenseCmEdgeTopShift * scale)
          .topLeft);
    } finally {
      _busy = false;
    }
  }

  /// The edge tab was pressed: the icon comes back beside the edge.
  static Future<void> restoreFromEdge() async {
    final side = edge.value;
    if (side == null || _busy) return;
    _busy = true;
    try {
      final info = await _windowInfo();
      edge.value = null;
      if (info == null) {
        await windowManager.setSize(kSenseCmIconSize);
        return;
      }
      final (frame, area, scale) = info;
      final rect = senseCmIconFromEdge(frame, area, side,
          kSenseCmIconSize * scale, kSenseCmEdgeInset * scale,
          kSenseCmEdgeTopShift * scale);
      await _setBounds(rect);
      _remember(rect.topLeft);
    } finally {
      _busy = false;
    }
  }

  static void _remember(Offset topLeft) {
    bind.mainSetLocalOption(
        key: kSenseCmPositionOption, value: formatSenseCmPosition(topLeft));
  }

  static const _macHostChannel = MethodChannel('org.rustdesk.rustdesk/host');

  /// Sense Remote (macOS): what makes the RustDesk window an icon there.
  /// Runs every time the icon is shown; each call only sets a window flag.
  static Future<void> _prepareMacWindow() async {
    if (!isMacOS) return;
    try {
      // A 64 pt window has no room for the close/minimize/zoom buttons, and
      // the icon must not be minimized away during a connection.
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden,
          windowButtonVisibility: false);
      await windowManager.setMinimizable(false);
      // The system shadow would draw a frame around the transparent window.
      await windowManager.setHasShadow(false);
      // Every Space, and above full screen apps (the process is an accessory
      // app by now: showCmWindow hides the Dock icon first).
      await windowManager.setVisibleOnAllWorkspaces(true,
          visibleOnFullScreen: true);
      // Flutter paints black behind the widgets on macOS; clear it so no
      // black square shows around the rounded icon (design review T3-4).
      await _macHostChannel.invokeMethod('senseCmClearBackground');
    } catch (e) {
      debugPrint('Sense CM: macOS window setup failed: $e');
    }
  }

  static Future<void> _setBounds(Rect rect) async {
    // Window sizes below the system minimum track size get clamped by
    // Windows; the window manager reports this minimum instead. On macOS
    // `rect` is in points and the pixel ratio is not used at all.
    await windowManager.setMinimumSize(kSenseCmEdgeSize);
    await windowManager.setBounds(rect, ignoreDevicePixelRatio: true);
    await _settleBounds(rect);
    _applyRegion(rect);
  }

  /// Windows (S7, #88): a window moved to a monitor with another scale is resized by the
  /// system to that scale (WM_DPICHANGED), so the card ended up at the wrong size with the
  /// Flutter surface still at the old one. The bounds are read back and set again (now on the
  /// right monitor, the system leaves the size alone) until they are the asked-for ones.
  static Future<void> _settleBounds(Rect rect) async {
    if (!isWindows) return;
    try {
      for (var i = 0; i < kSenseBoundsRetries; i++) {
        final got = (await window_size.getWindowInfo()).frame;
        if (senseBoundsMatch(rect, got)) return;
        await windowManager.setBounds(rect, ignoreDevicePixelRatio: true);
      }
    } catch (e) {
      debugPrint('Sense CM: bounds check failed: $e');
    }
  }

  /// Windows: clear corners of the icon let clicks through (H3).
  static void _applyRegion(Rect rect) {
    if (!isWindows) return;
    final iconMode = !open.value && edge.value == null;
    final scale = rect.width / kSenseCmIconSize.width;
    senseCmSetWindowRegion(
      width: rect.width.round(),
      height: rect.height.round(),
      radius: iconMode ? kSenseCmIconRegionRadius * scale : null,
    );
  }

  /// (work area, unit scale) of every monitor in window units (physical
  /// pixels on Windows, points on macOS); the primary monitor comes first.
  static Future<List<(Rect, double)>> _workAreas() async {
    try {
      final list = await window_size.getScreenList();
      return senseCmWorkAreas(
          list.map((s) => (s.frame, s.visibleFrame, s.scaleFactor)).toList(),
          macOS: isMacOS);
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

  /// (window frame, work area of its monitor, unit scale), window units.
  static Future<(Rect, Rect, double)?> _windowInfo() async {
    try {
      final window = await window_size.getWindowInfo();
      final screen = window.screen;
      if (screen == null) return null;
      if (isMacOS) {
        // Sense Remote: see senseCmMacTopOffset.
        final offset = senseCmMacTopOffset(
            (await window_size.getScreenList()).map((s) => s.frame).toList());
        return (
          senseCmMacRect(window.frame, offset),
          senseCmMacRect(screen.visibleFrame, offset),
          1.0
        );
      }
      return (window.frame, screen.visibleFrame, window.scaleFactor);
    } catch (e) {
      debugPrint('Sense CM: window info failed: $e');
      return null;
    }
  }
}

/// Sense Remote: the Host-side connection window in icon mode (`showCmWindow` in main.dart).
/// The small icon at its remembered place (bottom right first), always on top and off the
/// task bar. Returns whether the window is ready to show again.
Future<bool> senseCmShowWindow(
    {required bool isStartup,
    required bool readyToShow,
    required WindowOptions Function(Size size) startupOptions}) async {
  if (isStartup) {
    WindowOptions windowOptions = startupOptions(kSenseCmIconSize);
    await windowManager.waitUntilReadyToShow(windowOptions, null);
    bind.mainHideDock();
    await windowManager.setSkipTaskbar(true);
    await SenseCm.showIcon();
    await Future.wait([windowManager.show(), windowManager.setOpacity(1)]);
    return true;
  } else if (readyToShow) {
    if (await windowManager.getOpacity() != 1 ||
        !await windowManager.isVisible()) {
      await SenseCm.showIcon();
      await windowManager.setOpacity(1);
      await windowManager.show();
      await windowManager.setAlwaysOnTop(true);
    } else if (await windowManager.isMinimized()) {
      // "Show desktop" and similar must not take the icon away.
      await windowManager.restore();
    }
  }
  return readyToShow;
}
