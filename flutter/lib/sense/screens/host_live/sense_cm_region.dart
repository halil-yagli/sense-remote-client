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
