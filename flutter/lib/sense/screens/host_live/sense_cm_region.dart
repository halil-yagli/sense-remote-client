// Sense Remote (YH H3): "şeffaf kısım tıklamayı engellemez". A Flutter window
// on Windows takes every click inside its rectangle, even over transparent
// pixels. In icon mode the window gets a rounded region around the logo, so
// the clear corners of the 64 × 64 area let clicks through to the desktop.
// The card and the edge tab use the whole window (no region).
//
// macOS: the CM window is not opaque (senseCmClearBackground); the system
// passes clicks on fully clear pixels through, so nothing is done there.
//
// #99 (Sürüm 9): the rest of the Windows window helpers live here too: the
// plain frame (no Windows 11 border or rounded corners around the transparent
// window), the size read-back for the record, and the Flutter view refresh.

import 'dart:ffi' hide Size;
import 'dart:isolate';
import 'dart:ui' show Rect, Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as win32;

/// Class of the Flutter runner window (flutter/windows/runner/win32_window.cpp).
const String _kRunnerClass = 'FLUTTER_RUNNER_WIN32_WINDOW';

int _hwnd = 0;

// CreateRoundRectRgn and SetWindowRgn are not in package:win32 5.10; looked up
// on first use (Windows only).
typedef _CreateRgnC = IntPtr Function(Int32, Int32, Int32, Int32, Int32, Int32);
typedef _CreateRgnD = int Function(int, int, int, int, int, int);
typedef _SetRgnC = Int32 Function(IntPtr, IntPtr, Int32);
typedef _SetRgnD = int Function(int, int, int);

final _createRoundRectRgn = DynamicLibrary.open('gdi32.dll')
    .lookupFunction<_CreateRgnC, _CreateRgnD>('CreateRoundRectRgn');
final _setWindowRgn = DynamicLibrary.open('user32.dll')
    .lookupFunction<_SetRgnC, _SetRgnD>('SetWindowRgn');

// DwmSetWindowAttribute: looked up here too, so a Windows without it (or an
// older package:win32) only skips the plain frame.
typedef _DwmSetC = Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32);
typedef _DwmSetD = int Function(int, int, Pointer<Void>, int);
final _dwmSetWindowAttribute = DynamicLibrary.open('dwmapi.dll')
    .lookupFunction<_DwmSetC, _DwmSetD>('DwmSetWindowAttribute');

// GetDpiForWindow: Windows 10 1607 and later; looked up so older systems only
// leave the DPI out of the record.
typedef _DpiC = Uint32 Function(IntPtr);
typedef _DpiD = int Function(int);
final _getDpiForWindow =
    DynamicLibrary.open('user32.dll').lookupFunction<_DpiC, _DpiD>('GetDpiForWindow');

/// Class of the Flutter view inside the runner window (the embedder's child).
const String _kFlutterViewClass = 'FLUTTERVIEW';

/// The runner window of this process (the CM process has only this one).
int _ownWindow() {
  if (_hwnd != 0 && win32.IsWindow(_hwnd) != 0) return _hwnd;
  _hwnd = 0;
  final cls = _kRunnerClass.toNativeUtf16();
  final pid = calloc<Uint32>();
  try {
    final me = win32.GetCurrentProcessId();
    var hwnd = win32.FindWindowEx(0, 0, cls, nullptr);
    while (hwnd != 0) {
      win32.GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == me) {
        _hwnd = hwnd;
        break;
      }
      hwnd = win32.FindWindowEx(0, hwnd, cls, nullptr);
    }
  } finally {
    calloc.free(pid);
    calloc.free(cls);
  }
  return _hwnd;
}

/// Gives the window a rounded region of [width] × [height] physical pixels
/// with corner [radius]; [radius] null removes the region (whole window).
void senseCmSetWindowRegion(
    {required int width, required int height, double? radius}) {
  try {
    final hwnd = _ownWindow();
    if (hwnd == 0) return;
    if (radius == null) {
      _setWindowRgn(hwnd, 0, 1);
      return;
    }
    final d = (radius * 2).round();
    final rgn = _createRoundRectRgn(0, 0, width + 1, height + 1, d, d);
    // The system owns the region after SetWindowRgn; it is not deleted here.
    _setWindowRgn(hwnd, rgn, 1);
  } catch (e) {
    debugPrint('Sense CM: window region failed: $e');
  }
}

/// Windows 11 (#99, #4): no system border and no rounded corners around the
/// transparent window; the card draws its own frame. Older Windows ignores the
/// attributes (the call fails quietly).
void senseCmPlainFrame() {
  try {
    final hwnd = _ownWindow();
    if (hwnd == 0) return;
    final value = calloc<Uint32>();
    try {
      // DWMWA_BORDER_COLOR (34) = DWMWA_COLOR_NONE.
      value.value = 0xFFFFFFFE;
      _dwmSetWindowAttribute(hwnd, 34, value.cast(), sizeOf<Uint32>());
      // DWMWA_WINDOW_CORNER_PREFERENCE (33) = DWMWCP_DONOTROUND (1).
      value.value = 1;
      _dwmSetWindowAttribute(hwnd, 33, value.cast(), sizeOf<Uint32>());
    } finally {
      calloc.free(value);
    }
  } catch (e) {
    debugPrint('Sense CM: plain frame failed: $e');
  }
}

/// What Windows says about the window right now (physical pixels), for the
/// record (#99): window rectangle, client size, Flutter view size and DPI.
class SenseCmWinMetrics {
  const SenseCmWinMetrics(
      {required this.window, required this.client, required this.view, required this.dpi});

  final Rect window;
  final Size client;

  /// Size of the Flutter view window (the child the engine draws into).
  final Size view;

  /// DPI of the window (96 = 100 %); 0 when unknown.
  final int dpi;
}

Size _windowSize(int hwnd, Pointer<win32.RECT> rect) {
  win32.GetWindowRect(hwnd, rect);
  return Size((rect.ref.right - rect.ref.left).toDouble(),
      (rect.ref.bottom - rect.ref.top).toDouble());
}

/// Null off Windows or when the window is not found.
SenseCmWinMetrics? senseCmWindowMetrics() {
  try {
    final hwnd = _ownWindow();
    if (hwnd == 0) return null;
    final rect = calloc<win32.RECT>();
    try {
      win32.GetWindowRect(hwnd, rect);
      final window = Rect.fromLTRB(rect.ref.left.toDouble(), rect.ref.top.toDouble(),
          rect.ref.right.toDouble(), rect.ref.bottom.toDouble());
      win32.GetClientRect(hwnd, rect);
      final client = Size((rect.ref.right - rect.ref.left).toDouble(),
          (rect.ref.bottom - rect.ref.top).toDouble());
      final child = _flutterView(hwnd);
      final view = child == 0 ? Size.zero : _windowSize(child, rect);
      var dpi = 0;
      try {
        dpi = _getDpiForWindow(hwnd);
      } catch (_) {
        // Windows 10 before 1607: not available.
      }
      return SenseCmWinMetrics(window: window, client: client, view: view, dpi: dpi);
    } finally {
      calloc.free(rect);
    }
  } catch (e) {
    debugPrint('Sense CM: window metrics failed: $e');
    return null;
  }
}

int _flutterView(int hwnd) {
  final cls = _kFlutterViewClass.toNativeUtf16();
  try {
    return win32.FindWindowEx(hwnd, 0, cls, nullptr);
  } finally {
    calloc.free(cls);
  }
}

/// #99: makes the Flutter view present a frame at the window's current size.
///
/// After a burst of programmatic resizes (card ↔ icon, a monitor scale change
/// on the way) the embedder can be left waiting for a frame of an in-between
/// size: it keeps showing the last accepted frame stretched into the window
/// (squeezed text, a clear strip beside it) until something resizes the view
/// again. This is the runner's `ForceChildRefresh` (flutter_window.cpp,
/// flutter/flutter#159630): zero width first, which resends the metrics
/// without a new resize target, then the real width.
///
/// It runs on a helper isolate: the resize message is handled on the platform
/// thread, which waits for a frame of the new size; the UI thread stays free
/// to draw that frame instead of being blocked in the call.
Future<void> senseCmRefreshFlutterView() async {
  try {
    final hwnd = _ownWindow();
    if (hwnd == 0) return;
    final child = _flutterView(hwnd);
    if (child == 0) return;
    try {
      await Isolate.run(() => _refreshChild(child));
    } catch (_) {
      _refreshChild(child);
    }
  } catch (e) {
    debugPrint('Sense CM: view refresh failed: $e');
  }
}

void _refreshChild(int child) {
  final rect = calloc<win32.RECT>();
  try {
    final size = _windowSize(child, rect);
    // SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOMOVE | SWP_FRAMECHANGED
    const flags = 0x0004 | 0x0200 | 0x0002 | 0x0020;
    win32.SetWindowPos(child, 0, 0, 0, 0, size.height.round(), flags);
    win32.SetWindowPos(child, 0, 0, 0, size.width.round(), size.height.round(), flags);
  } finally {
    calloc.free(rect);
  }
}

// --- #107: popup window style (true 64 × 64 icon) -------------------------

// GetWindowLongPtrW / SetWindowLongPtrW (64-bit builds); looked up so a
// missing export only skips the style change.
typedef _GetLongC = IntPtr Function(IntPtr, Int32);
typedef _GetLongD = int Function(int, int);
typedef _SetLongC = IntPtr Function(IntPtr, Int32, IntPtr);
typedef _SetLongD = int Function(int, int, int);
final _getWindowLongPtr = DynamicLibrary.open('user32.dll')
    .lookupFunction<_GetLongC, _GetLongD>('GetWindowLongPtrW');
final _setWindowLongPtr = DynamicLibrary.open('user32.dll')
    .lookupFunction<_SetLongC, _SetLongD>('SetWindowLongPtrW');

const int _kGwlStyle = -16;
const int kSenseWsPopup = 0x80000000;
const int kSenseWsCaption = 0x00C00000;
const int kSenseWsThickFrame = 0x00040000;
const int kSenseWsMaximizeBox = 0x00010000;

/// #107: the CM window's style without caption, sizing border and maximize
/// box, as a popup window.
///
/// Slayer v9: the icon asked for 64 × 64 and got 136 × 64. The runner window is
/// an overlapped window with a caption (WS_OVERLAPPEDWINDOW); Windows keeps
/// such windows at least as wide as the system minimum (SM_CXMIN, 136 px) even
/// though window_manager answers WM_GETMINMAXINFO with 24 × 52, so the right
/// half of the icon window was an empty clear strip and the logo sat in a
/// half-region. A popup window is not held to that minimum. Frameless already
/// (no system border is drawn), so the card looks and drags the same.
int senseCmPopupStyle(int style) =>
    ((style & 0xFFFFFFFF) &
        ~(kSenseWsCaption | kSenseWsThickFrame | kSenseWsMaximizeBox)) |
    kSenseWsPopup;

/// Makes the CM window a popup window (see [senseCmPopupStyle]). Runs before
/// every resize; changes nothing when the style is already right. Returns
/// false when the window or the call is not available.
bool senseCmPopupFrame() {
  try {
    final hwnd = _ownWindow();
    if (hwnd == 0) return false;
    final old = _getWindowLongPtr(hwnd, _kGwlStyle) & 0xFFFFFFFF;
    final want = senseCmPopupStyle(old);
    if (want == old) return true;
    _setWindowLongPtr(hwnd, _kGwlStyle, want);
    // SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED
    const flags = 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x0020;
    win32.SetWindowPos(hwnd, 0, 0, 0, 0, 0, flags);
    return true;
  } catch (e) {
    debugPrint('Sense CM: popup style failed: $e');
    return false;
  }
}

// --- #109: not in the picture sent to the Controller ----------------------

typedef _AffinityC = Int32 Function(IntPtr, Uint32);
typedef _AffinityD = int Function(int, int);
final _setWindowDisplayAffinity = DynamicLibrary.open('user32.dll')
    .lookupFunction<_AffinityC, _AffinityD>('SetWindowDisplayAffinity');

/// WDA_EXCLUDEFROMCAPTURE (Windows 10 2004 and later).
const int kSenseWdaExcludeFromCapture = 0x00000011;

/// #109: the Sense card and icon stay on the Host's screen but are left out of
/// screen capture, so the Controller does not see the Host's chat icon next to
/// its own. Older Windows rejects the value: nothing changes there (the window
/// stays in the picture as before). The window is never hidden from the Host
/// user (workshop CLAUDE.md, Security). Returns (done, Windows error code).
(bool, int) senseCmExcludeFromCapture() {
  try {
    final hwnd = _ownWindow();
    if (hwnd == 0) return (false, 0);
    if (_setWindowDisplayAffinity(hwnd, kSenseWdaExcludeFromCapture) != 0) {
      return (true, 0);
    }
    return (false, win32.GetLastError());
  } catch (e) {
    debugPrint('Sense CM: capture exclusion failed: $e');
    return (false, -1);
  }
}
