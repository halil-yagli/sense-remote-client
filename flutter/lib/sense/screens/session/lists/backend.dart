// Sense Remote: everything the session bar and its lists read from and do to the
// RustDesk session. The real one (`ffi_backend.dart`) calls the RustDesk functions of
// TK9 §3; tests use a fake. Values that RustDesk only gives asynchronously are read by
// [refresh] and then held, so the lists draw synchronously.
import 'package:flutter/foundation.dart';

import '../data/grants.dart';
import '../data/session_state.dart';
import 'rules.dart';

@immutable
class SenseDisplayRef {
  const SenseDisplayRef(this.index, {this.primary = false, this.width = 0, this.height = 0});
  final int index;
  final bool primary;
  final int width;
  final int height;
}

@immutable
class SenseResolution {
  const SenseResolution(this.width, this.height);
  final int width;
  final int height;
  String get key => '${width}x$height';
  String get label => '$width×$height';
  @override
  bool operator ==(Object other) => other is SenseResolution && other.width == width && other.height == height;
  @override
  int get hashCode => Object.hash(width, height);
}

/// One read-only shortcut row (O5 "Kısayollar").
@immutable
class SenseShortcutRow {
  const SenseShortcutRow(this.actionId, this.label, this.keys);
  final String actionId;
  final String label;

  /// "Ctrl+Alt+Shift+Enter", or null when nothing is bound.
  final String? keys;
}

abstract class SenseSessionBackend extends ChangeNotifier {
  // ---- Session ----
  String get peerId;
  String get peerName;

  /// The peer info has arrived (menus can be used).
  bool get ready;
  SensePeerFacts get facts;
  SenseSessionGrants get grants;
  SenseLinkSample get link;

  /// Reads the values RustDesk gives asynchronously; notifies when done.
  Future<void> refresh();

  // ---- Bar ----
  bool get barHidden;
  void toggleBar();
  bool get fullscreen;
  void toggleFullscreen();
  void end();
  bool get ghostOn;

  /// False: ghost mode cannot be switched here (no privacy mode, no right, view only).
  bool get ghostAvailable;

  /// Turning ghost mode on needs display 1 with some implementations (S9-b: no dialog,
  /// the bar says it in place).
  bool get ghostNeedsDisplay1;
  void toggleGhost();

  /// The code of the last ghost note of the core (`sense_privacy_note`), or null.
  String? get ghostNote;
  int get ghostNoteSerial;
  bool get inputLocked;
  bool get recordingOn;

  // ---- O3 Ekranlar ----
  List<SenseDisplayRef> get displays;
  int get currentDisplay;
  void openDisplay(int index);
  bool get individualWindows;
  void setIndividualWindows(bool v);
  List<SenseResolution> get resolutions;
  SenseResolution? get currentResolution;
  SenseResolution? get originalResolution;
  SenseResolution? get fitLocalResolution;
  void setResolution(SenseResolution r);
  bool get useAllMyDisplays;
  void setUseAllMyDisplays(bool v);
  int get virtualDisplayCount;
  bool get canAddVirtualDisplay;
  void addVirtualDisplay();
  void removeAllVirtualDisplays();

  // ---- O4 Görüntü ----
  String get viewStyle;
  void setViewStyle(String v);
  int get customScalePercent;
  void setCustomScalePercent(int v);
  String get imageQuality;
  void setImageQuality(String v);
  void refreshVideo();
  String get scrollStyle;
  void setScrollStyle(String v);
  void resetView();
  bool get canAdjustWindow;
  void adjustWindow();
  int get customQuality;
  void setCustomQuality(int v);
  int get customFps;
  void setCustomFps(int v);
  bool get showCustomFps;
  bool get showMoreQuality;
  bool get trueColor;
  void setTrueColor(bool v);

  /// Codec keys this peer can use ('auto', 'vp8', 'vp9', 'av1', 'h264', 'h265').
  List<String> get codecs;
  String get codec;
  void setCodec(String v);

  /// The codec "Otomatik" picked right now (e.g. "VP9"), or null.
  String? get activeCodec;
  bool get muted;
  void setMuted(bool v);

  // ---- O5 Klavye ve fare ----
  /// Keyboard modes this session supports (map, translate, legacy).
  List<String> get keyboardModes;
  String get keyboardMode;
  void setKeyboardMode(String v);
  bool get viewOnly;
  void setViewOnly(bool v);
  bool get swapCtrlCmd;
  void setSwapCtrlCmd(bool v);
  String get localKbLayout;
  void setLocalKbLayout(String v);
  bool get shortcutsEnabled;
  List<SenseShortcutRow> get shortcuts;
  bool get showRemoteCursor;
  bool get showRemoteCursorLocked;
  void setShowRemoteCursor(bool v);
  bool get showMyCursor;
  void setShowMyCursor(bool v);
  bool get followRemoteCursor;
  void setFollowRemoteCursor(bool v);
  bool get followRemoteWindow;
  void setFollowRemoteWindow(bool v);
  bool get zoomCursor;
  void setZoomCursor(bool v);
  bool get relativeMouse;
  void setRelativeMouse(bool v);
  bool get reverseWheel;
  void setReverseWheel(bool v);
  bool get swapMouseButtons;
  void setSwapMouseButtons(bool v);
  int get trackpadSpeed;
  void setTrackpadSpeed(int v);

  // ---- O6 Eylemler ----
  void ctrlAltDel();
  bool get screenshotBusy;
  void screenshot();
  void lockScreen();
  void restart();
  void setBlockInput(bool v);
  void toggleRecording();
  void typeClipboard();
  bool get fileCopyPaste;
  void setFileCopyPaste(bool v);
  bool get clipboardDisabled;
  void setClipboardDisabled(bool v);
  void openRemoteFiles();
  void requestElevation();
  bool get lockAfterEnd;
  void setLockAfterEnd(bool v);
  void addNote();
  void openTerminal();
  void openTunnel();
  void openCamera();

  /// The connection fingerprint, or empty.
  String get fingerprint;
  void copyFingerprint();
}
