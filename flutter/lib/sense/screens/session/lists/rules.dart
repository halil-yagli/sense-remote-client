// Sense Remote: when a session option is offered (TK9 §3). The same conditions as the
// RustDesk menus (`common/widgets/toolbar.dart`, `desktop/widgets/remote_toolbar.dart`),
// written once over plain facts so they are testable without a session. Sense changes:
//  - "Tümü" only when the peer can show all displays together and has more than one (#5),
//  - "Her ekranı ayrı pencerede aç" without the `show_monitors_toolbar` condition,
//  - no "Taraf değiştir" (decision 2), no Android buttons, no Wayland or OS password items.
// Sürüm 9 (Paket L): "Kamerayı görüntüle" (O6), "Terminal aç (yönetici)" (Windows), "Bu
// bilgisayara hep aktarmayla bağlan", çizim ayarları (doku / D3D) and the custom resolution
// of a virtual display, with the same conditions as the RustDesk menus they come from.
import 'package:flutter/foundation.dart';

enum SensePeerOs { windows, mac, linux, android, other }

/// The view mode values (RustDesk `kRemoteViewStyle*`, `kRemoteImageQuality*`, …).
abstract final class SenseRd {
  static const int allDisplays = -1; // kAllDisplayValue
  static const String viewOriginal = 'original';
  static const String viewAdaptive = 'adaptive';
  static const String viewCustom = 'custom';
  static const String qualityBest = 'best';
  static const String qualityBalanced = 'balanced';
  static const String qualityLow = 'low';
  static const String qualityCustom = 'custom';
  static const String scrollAuto = 'scrollauto';
  static const String scrollBar = 'scrollbar';
  static const String scrollEdge = 'scrolledge';
  static const String modeLegacy = 'legacy';
  static const String modeMap = 'map';
  static const String modeTranslate = 'translate';
  static const String kbIso = 'ISO';
  static const String kbNotIso = 'Not ISO';
  static const int customScaleMin = 25; // YH O4 (RustDesk allows wider)
  static const int customScaleMax = 200;
  static const int qualityMin = 10; // kMinQuality
  static const int qualityMax = 100; // kMaxQuality
  static const int qualityMaxMore = 2000; // kMaxMoreQuality
  static const int fpsMin = 5; // kMinFps
  static const int fpsMax = 120; // kMaxFps
  static const int trackpadMin = 10; // kMinTrackpadSpeed
  static const int trackpadMax = 1000; // kMaxTrackpadSpeed
  static const int trackpadListMax = 300; // prototype slider range (c04: 10–300)
}

/// Facts about the running session the rules read.
@immutable
class SensePeerFacts {
  const SensePeerFacts({
    this.os = SensePeerOs.windows,
    this.localMac = false,
    this.version = '1.4.6',
    this.defaultConn = true,
    this.viewOnly = false,
    this.keyboard = true,
    this.sasEnabled = true,
    this.deniedPerms = const {},
    this.displaysCount = 1,
    this.supportMultiDisplay = true,
    this.currentDisplay = 0,
    this.multiUiSession = false,
    this.localMultiScreens = false,
    this.installed = true,
    this.rustDeskIdd = false,
    this.amyuniIdd = false,
    this.cursorEmbedded = false,
    this.wayland = false,
    this.localWayland = false,
    this.codecFormat,
    this.privacyOn = false,
    this.resolutionsCount = 1,
    this.virtualResolution = false,
    this.screenshotSupported = true,
    this.elevationOffered = false,
    this.accountDisabled = false,
    this.hideRecordingButton = false,
    this.recording = false,
    this.relativeMouseSupported = true,
    this.fileClipboard = true,
    this.audioPerm = true,
    this.viewCameraSupported = false,
    this.localWindows = false,
  });

  final SensePeerOs os;
  final bool localMac;
  final String version;

  /// A normal remote control connection (not file transfer / camera / terminal).
  final bool defaultConn;
  final bool viewOnly;

  /// The computer lets this connection use keyboard and mouse (`ffiModel.keyboard`).
  final bool keyboard;
  final bool sasEnabled;

  /// RustDesk permissions turned off for this connection (`permissions[x] == false`).
  final Set<String> deniedPerms;
  final int displaysCount;
  final bool supportMultiDisplay;
  final int currentDisplay;
  final bool multiUiSession;
  final bool localMultiScreens;
  final bool installed;
  final bool rustDeskIdd;
  final bool amyuniIdd;
  final bool cursorEmbedded;
  final bool wayland;
  final bool localWayland;
  final String? codecFormat;
  final bool privacyOn;
  final int resolutionsCount;
  final bool virtualResolution;
  final bool screenshotSupported;
  final bool elevationOffered;
  final bool accountDisabled;
  final bool hideRecordingButton;
  final bool recording;
  final bool relativeMouseSupported;

  /// File copy-paste is possible between the two sides (version / platform checks).
  final bool fileClipboard;
  final bool audioPerm;

  /// The peer can show its cameras (`platform_additions.support_view_camera`; RustDesk
  /// sends it from Windows and Linux only, so a Mac peer has no camera item).
  final bool viewCameraSupported;

  /// This (the Controller) computer runs Windows (D3D rendering is Windows only).
  final bool localWindows;

  bool perm(String name) => !deniedPerms.contains(name);
  bool get onAllDisplays => currentDisplay == SenseRd.allDisplays;
  bool get desktopPeer => os == SensePeerOs.windows || os == SensePeerOs.mac || os == SensePeerOs.linux;
}

/// RustDesk `versionCmp`: compares dotted numbers.
int senseVersionCmp(String a, String b) {
  List<int> parts(String v) => v.split('.').map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).toList();
  final x = parts(a), y = parts(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final p = i < x.length ? x[i] : 0;
    final q = i < y.length ? y[i] : 0;
    if (p != q) return p < q ? -1 : 1;
  }
  return 0;
}

abstract final class SenseRules {
  // ---- O3 Ekranlar ----
  static bool displayTiles(SensePeerFacts f) => f.displaysCount >= 1;

  /// #5: one display → no "Tümü".
  static bool allTile(SensePeerFacts f) => f.supportMultiDisplay && f.displaysCount > 1;

  /// #97: also visible while ghost mode is on (it starts on in every session, #95); a hidden
  /// switch would lock a computer that once had it on into separate windows. Default is off
  /// (RustDesk option `displays_as_individual_windows`, empty = off; only "Y" opens windows).
  static bool individualWindows(SensePeerFacts f) => f.supportMultiDisplay && f.displaysCount > 1;
  static bool resolution(SensePeerFacts f) =>
      f.keyboard && (f.virtualResolution || f.resolutionsCount > 1) && !f.onAllDisplays;

  /// "Özel çözünürlük" (width × height): RustDesk offers it only on a virtual display
  /// resolution (`isVirtualDisplayResolution`), inside the resolution menu.
  static bool customResolution(SensePeerFacts f) => resolution(f) && f.virtualResolution;
  static bool useAllMyDisplays(SensePeerFacts f) => f.supportMultiDisplay && f.localMultiScreens;

  /// Windows + installed + a virtual display driver.
  static bool virtualDisplay(SensePeerFacts f) =>
      f.os == SensePeerOs.windows && f.installed && (f.rustDeskIdd || f.amyuniIdd);

  // ---- O4 Görüntü ----
  static bool scroll(String viewStyle) =>
      viewStyle == SenseRd.viewOriginal || viewStyle == SenseRd.viewCustom;
  static bool customFps(SensePeerFacts f, {required bool publicServerRelay}) =>
      !publicServerRelay && senseVersionCmp(f.version, '1.2.0') >= 0;
  static bool moreQuality(SensePeerFacts f, {required bool publicServerRelay}) =>
      !publicServerRelay && senseVersionCmp(f.version, '1.2.2') >= 0;

  /// 4:4:4 needs AV1 or VP9 and a peer from 1.2.4.
  static bool trueColor(SensePeerFacts f) =>
      senseVersionCmp(f.version, '1.2.4') >= 0 && (f.codecFormat == 'AV1' || f.codecFormat == 'VP9');
  static bool mute(SensePeerFacts f) => f.defaultConn && f.audioPerm;

  /// Drawing settings of this computer (RustDesk settings "Use texture rendering", "Use D3D
  /// rendering"): local options, used by the next connection.
  static bool textureRender(SensePeerFacts f) => f.defaultConn;
  static bool d3dRender(SensePeerFacts f) => f.defaultConn && f.localWindows;

  // ---- O5 Klavye ve fare ----
  static bool viewOnlyEnabled(SensePeerFacts f) => senseVersionCmp(f.version, '1.2.0') >= 0 && f.keyboard;

  /// Ctrl ↔ Cmd: only between a Mac and something else.
  static bool swapCtrlCmd(SensePeerFacts f) =>
      f.keyboard && (f.localMac != (f.os == SensePeerOs.mac));

  /// "Bu bilgisayarın klavyesi": Mac peer, Windows / Linux here.
  static bool localKbLayout(SensePeerFacts f) => f.os == SensePeerOs.mac && !f.localMac;
  static bool showRemoteCursor(SensePeerFacts f) =>
      f.os != SensePeerOs.android && !f.cursorEmbedded && !f.wayland;
  static bool showMyCursor(SensePeerFacts f) => f.desktopPeer;
  static bool followRemote(SensePeerFacts f) =>
      showRemoteCursor(f) &&
      senseVersionCmp(f.version, '1.2.4') >= 0 &&
      f.displaysCount > 1 &&
      !f.onAllDisplays &&
      !f.multiUiSession;
  static bool zoomCursor(SensePeerFacts f, String viewStyle) =>
      f.os != SensePeerOs.android && viewStyle != SenseRd.viewOriginal;
  static bool relativeMouse(SensePeerFacts f) =>
      f.defaultConn && !f.localWayland && f.keyboard && !f.viewOnly && f.relativeMouseSupported;
  static bool mouseOptions(SensePeerFacts f) => f.keyboard;

  // ---- O6 Eylemler ----
  /// Not for a Mac peer (no secure attention sequence there).
  static bool ctrlAltDel(SensePeerFacts f) =>
      f.defaultConn && !f.viewOnly && f.keyboard && (f.os == SensePeerOs.linux || f.sasEnabled);
  static bool screenshot(SensePeerFacts f) => f.screenshotSupported;
  static bool lockScreen(SensePeerFacts f) => f.defaultConn && !f.viewOnly && f.keyboard;
  static bool restart(SensePeerFacts f) => f.defaultConn && f.perm('restart') && f.desktopPeer;

  /// Only a Windows peer can lock its own keyboard and mouse.
  static bool blockInput(SensePeerFacts f) =>
      f.defaultConn && f.keyboard && f.perm('block_input') && f.os == SensePeerOs.windows;
  static bool recording(SensePeerFacts f) =>
      !f.hideRecordingButton && (f.recording || f.perm('recording'));
  static bool typeClipboard(SensePeerFacts f) =>
      f.defaultConn && f.os != SensePeerOs.android && f.perm('keyboard');
  static bool fileCopyPaste(SensePeerFacts f) =>
      f.defaultConn && f.keyboard && f.perm('file') && f.fileClipboard;
  static bool disableClipboard(SensePeerFacts f) => f.defaultConn && f.keyboard && f.perm('clipboard');
  static bool remoteFiles(SensePeerFacts f) => f.defaultConn;

  /// Windows asks for elevation when the Host runs without it (RustDesk offers it).
  static bool elevation(SensePeerFacts f) => f.defaultConn && f.perm('keyboard') && f.elevationOffered;
  static bool lockAfterEnd(SensePeerFacts f) => f.defaultConn && f.keyboard && f.os != SensePeerOs.android;
  static bool note(SensePeerFacts f) => f.defaultConn && !f.accountDisabled;
  static bool advanced(SensePeerFacts f) => f.defaultConn;

  /// RustDesk peer menu "Terminal (Run as administrator)": Windows peers only.
  static bool terminalAdmin(SensePeerFacts f) => advanced(f) && f.os == SensePeerOs.windows;

  /// RustDesk "View camera" (toolbar, desktop): a separate camera connection. Hidden when
  /// the peer cannot show cameras (Mac) or the computer turned the camera permission off.
  static bool viewCamera(SensePeerFacts f) =>
      advanced(f) && f.desktopPeer && f.viewCameraSupported && f.perm('camera');

  /// RustDesk peer menu "Always connect via relay" (peer option `force-always-relay`).
  static bool forceRelay(SensePeerFacts f) => f.defaultConn;
}
