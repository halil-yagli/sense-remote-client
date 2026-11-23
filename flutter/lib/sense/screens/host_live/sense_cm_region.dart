// Sense Remote (YH H3): "şeffaf kısım tıklamayı engellemez". A Flutter window
// on Windows takes every click inside its rectangle, even over transparent
// pixels. In icon mode the window gets a rounded region around the logo, so
// the clear corners of the 64 × 64 area let clicks through to the desktop.
// The card and the edge tab use the whole window (no region).
//
// macOS: the CM window is not opaque (senseCmClearBackground); the system
// passes clicks on fully clear pixels through, so nothing is done there.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart' as win32;

/// Class of the Flutter runner window (flutter/windows/runner/win32_window.cpp).
const String _kRunnerClass = 'FLUTTER_RUNNER_WIN32_WINDOW';

int _hwnd = 0;

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
      win32.SetWindowRgn(hwnd, 0, win32.TRUE);
      return;
    }
    final d = (radius * 2).round();
    final rgn = win32.CreateRoundRectRgn(0, 0, width + 1, height + 1, d, d);
    // The system owns the region after SetWindowRgn; it is not deleted here.
    win32.SetWindowRgn(hwnd, rgn, win32.TRUE);
  } catch (e) {
    debugPrint('Sense CM: window region failed: $e');
  }
}
