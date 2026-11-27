// Sense Remote: a session backend without a RustDesk session, for the bar and list tests.
// Every action is written to [calls]; every setter stores the value.
import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/sense/screens/session/bar/sense_session_bar.dart';
import 'package:flutter_hbb/sense/screens/session/data/grants.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/backend.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

class FakeBackend extends SenseSessionBackend {
  FakeBackend({
    SensePeerFacts? facts,
    this.grants = const SenseSessionGrants.unavailable(),
    this.link = const SenseLinkSample(path: SenseLinkPath.direct, fps: 60, rttMs: 18),
  }) : facts = facts ??
            const SensePeerFacts(
              displaysCount: 3,
              localMultiScreens: true,
              rustDeskIdd: true,
              resolutionsCount: 3,
              codecFormat: 'VP9',
              elevationOffered: true,
              viewCameraSupported: true,
              localWindows: true,
            );

  final List<String> calls = [];

  @override
  SensePeerFacts facts;
  @override
  SenseSessionGrants grants;
  @override
  SenseLinkSample link;

  void _call(String name) {
    calls.add(name);
    notifyListeners();
  }

  void set(VoidCallback f) {
    f();
    notifyListeners();
  }

  @override
  String get peerId => 'peer-1';
  @override
  String peerName = 'Giriş Salonu PC-2';
  @override
  bool ready = true;
  @override
  Future<void> refresh() async => calls.add('refresh');

  // Bar
  @override
  bool barHidden = false;
  @override
  void toggleBar() => set(() => barHidden = !barHidden);
  @override
  bool fullscreen = false;
  @override
  void toggleFullscreen() => set(() => fullscreen = !fullscreen);
  @override
  void end() => _call('end');
  @override
  bool ghostOn = false;
  @override
  bool ghostAvailable = true;
  @override
  bool ghostNeedsDisplay1 = false;
  @override
  void toggleGhost() => set(() {
        ghostOn = !ghostOn;
        calls.add('ghost');
      });
  @override
  String? ghostNote;
  @override
  int ghostNoteSerial = 0;
  void sendGhostNote(String code) => set(() {
        ghostNote = code;
        ghostNoteSerial++;
      });
  @override
  bool inputLocked = false;
  @override
  bool recordingOn = false;

  // O3
  @override
  List<SenseDisplayRef> displays = const [
    SenseDisplayRef(0, primary: true, width: 3840, height: 2160),
    SenseDisplayRef(1, width: 3840, height: 2160),
    SenseDisplayRef(2, width: 1920, height: 1080),
  ];
  @override
  int currentDisplay = 0;
  @override
  void openDisplay(int index) => set(() {
        currentDisplay = index;
        calls.add('openDisplay:$index');
      });
  @override
  bool individualWindows = false;
  @override
  void setIndividualWindows(bool v) => set(() => individualWindows = v);
  @override
  List<SenseResolution> resolutions = const [SenseResolution(3840, 2160), SenseResolution(1920, 1080), SenseResolution(1280, 720)];
  @override
  SenseResolution? currentResolution = const SenseResolution(3840, 2160);
  @override
  SenseResolution? originalResolution = const SenseResolution(3840, 2160);
  @override
  SenseResolution? fitLocalResolution = const SenseResolution(1920, 1080);
  @override
  void setResolution(SenseResolution r) => set(() {
        currentResolution = r;
        calls.add('resolution:${r.key}');
      });
  @override
  bool useAllMyDisplays = false;

  /// Sürüm 10 (#116): like the FFI backend — spreading applies at once when [canSpread],
  /// gathering the windows back waits for the next connection.
  bool canSpread = true;
  bool? spread;
  @override
  bool useAllMyDisplaysPending = false;
  @override
  void setUseAllMyDisplays(bool v) => set(() {
        final was = spread ??= useAllMyDisplays && canSpread;
        useAllMyDisplays = v;
        if (v == was) {
          useAllMyDisplaysPending = false;
        } else if (v && canSpread) {
          spread = true;
          useAllMyDisplaysPending = false;
          calls.add('spreadDisplays');
        } else {
          useAllMyDisplaysPending = true;
        }
      });
  @override
  int virtualDisplayCount = 0;
  @override
  bool canAddVirtualDisplay = true;
  @override
  void addVirtualDisplay() => set(() {
        virtualDisplayCount++;
        calls.add('addVirtual');
      });
  @override
  void removeAllVirtualDisplays() => set(() {
        virtualDisplayCount = 0;
        calls.add('removeVirtual');
      });

  // O4
  @override
  String viewStyle = SenseRd.viewAdaptive;
  @override
  void setViewStyle(String v) => set(() => viewStyle = v);
  @override
  int customScalePercent = 100;
  @override
  void setCustomScalePercent(int v) => set(() => customScalePercent = v);
  @override
  String imageQuality = SenseRd.qualityBalanced;
  @override
  void setImageQuality(String v) => set(() => imageQuality = v);
  @override
  void refreshVideo() => _call('refreshVideo');
  @override
  String scrollStyle = SenseRd.scrollAuto;
  @override
  void setScrollStyle(String v) => set(() => scrollStyle = v);
  @override
  void resetView() => _call('resetView');
  @override
  bool canAdjustWindow = true;
  @override
  void adjustWindow() => _call('adjustWindow');
  @override
  int customQuality = 50;
  @override
  void setCustomQuality(int v) => set(() => customQuality = v);
  @override
  int customFps = 30;
  @override
  void setCustomFps(int v) => set(() => customFps = v);
  @override
  bool showCustomFps = true;
  @override
  bool showMoreQuality = false;
  @override
  bool trueColor = false;
  @override
  void setTrueColor(bool v) => set(() => trueColor = v);
  @override
  List<String> codecs = const ['auto', 'vp8', 'vp9', 'av1', 'h264', 'h265'];
  @override
  String codec = 'auto';
  @override
  void setCodec(String v) => set(() => codec = v);
  @override
  String? activeCodec;
  @override
  bool muted = false;
  @override
  void setMuted(bool v) => set(() => muted = v);
  @override
  int? viewScalePercent = 38;
  @override
  bool textureRender = false;
  @override
  void setTextureRender(bool v) => set(() => textureRender = v);
  @override
  bool d3dRender = false;
  @override
  void setD3dRender(bool v) => set(() => d3dRender = v);

  // O5
  @override
  List<String> keyboardModes = const [SenseRd.modeMap, SenseRd.modeTranslate, SenseRd.modeLegacy];
  @override
  String keyboardMode = SenseRd.modeMap;
  @override
  void setKeyboardMode(String v) => set(() => keyboardMode = v);
  @override
  bool viewOnly = false;
  @override
  void setViewOnly(bool v) => set(() => viewOnly = v);
  @override
  bool swapCtrlCmd = false;
  @override
  void setSwapCtrlCmd(bool v) => set(() => swapCtrlCmd = v);
  @override
  String localKbLayout = SenseRd.kbIso;
  @override
  void setLocalKbLayout(String v) => set(() => localKbLayout = v);
  @override
  bool shortcutsEnabled = true;
  @override
  List<SenseShortcutRow> shortcuts = const [
    SenseShortcutRow('toggle_fullscreen', 'Tam ekran', 'Ctrl+Alt+Shift+Enter'),
    SenseShortcutRow('toggle_toolbar', 'Çubuğu gizle / göster', 'Ctrl+Alt+Shift+B'),
    SenseShortcutRow('switch_display_next', 'Sonraki ekran', 'Ctrl+Alt+Shift+Sağ'),
    SenseShortcutRow('send_ctrl_alt_del', 'Ctrl+Alt+Del gönder', 'Ctrl+Alt+Shift+Del'),
    SenseShortcutRow('screenshot', 'Ekran görüntüsü al', 'Ctrl+Alt+Shift+P'),
    SenseShortcutRow('close_tab', 'Bağlantıyı bitir', 'Ctrl+Alt+Shift+Q'),
  ];
  @override
  bool showRemoteCursor = true;
  @override
  bool showRemoteCursorLocked = false;
  @override
  void setShowRemoteCursor(bool v) => set(() => showRemoteCursor = v);
  @override
  bool showMyCursor = false;
  @override
  void setShowMyCursor(bool v) => set(() => showMyCursor = v);
  @override
  bool followRemoteCursor = false;
  @override
  void setFollowRemoteCursor(bool v) => set(() => followRemoteCursor = v);
  @override
  bool followRemoteWindow = false;
  @override
  void setFollowRemoteWindow(bool v) => set(() => followRemoteWindow = v);
  @override
  bool zoomCursor = false;
  @override
  void setZoomCursor(bool v) => set(() => zoomCursor = v);
  @override
  bool relativeMouse = false;
  @override
  void setRelativeMouse(bool v) => set(() => relativeMouse = v);
  @override
  bool reverseWheel = false;
  @override
  void setReverseWheel(bool v) => set(() => reverseWheel = v);
  @override
  bool swapMouseButtons = false;
  @override
  void setSwapMouseButtons(bool v) => set(() => swapMouseButtons = v);
  @override
  int trackpadSpeed = 100;
  @override
  void setTrackpadSpeed(int v) => set(() => trackpadSpeed = v);

  // O6
  @override
  void ctrlAltDel() => _call('ctrlAltDel');
  @override
  bool screenshotBusy = false;
  @override
  void screenshot() => _call('screenshot');
  @override
  void lockScreen() => _call('lockScreen');
  @override
  void restart() => _call('restart');
  @override
  void setBlockInput(bool v) => set(() => inputLocked = v);
  @override
  void toggleRecording() => set(() {
        recordingOn = !recordingOn;
        calls.add('recording');
      });
  @override
  void typeClipboard() => _call('typeClipboard');
  @override
  bool fileCopyPaste = true;
  @override
  void setFileCopyPaste(bool v) => set(() => fileCopyPaste = v);
  @override
  bool clipboardDisabled = false;
  @override
  void setClipboardDisabled(bool v) => set(() => clipboardDisabled = v);
  @override
  void openRemoteFiles() => _call('remoteFiles');
  @override
  void requestElevation() => _call('elevation');
  @override
  bool lockAfterEnd = false;
  @override
  void setLockAfterEnd(bool v) => set(() => lockAfterEnd = v);
  @override
  void addNote() => _call('note');
  @override
  void openTerminal() => _call('terminal');
  @override
  void openTerminalAdmin() => _call('terminalAdmin');
  @override
  void openTunnel() => _call('tunnel');
  @override
  void openCamera() => _call('camera');
  @override
  bool forceRelay = false;
  @override
  bool forceRelayEverywhere = false;
  @override
  void setForceRelay(bool v) => set(() => forceRelay = v);
  @override
  String fingerprint = 'ab12 cd34';
  @override
  void copyFingerprint() => _call('fingerprint');
}

class FakePopups extends ChangeNotifier implements SenseBarPopups {
  final Set<SenseBarPopup> open = {};
  SenseLevel? statusLevel = SenseLevel.hot;
  SenseLevel? infoLevel = SenseLevel.warn;

  @override
  bool isOpen(SenseBarPopup p) => open.contains(p);

  @override
  void toggle(SenseBarPopup p) {
    if (!open.remove(p)) {
      open
        ..clear()
        ..add(p);
    }
    notifyListeners();
  }

  @override
  void closeAll() {
    open.clear();
    notifyListeners();
  }

  @override
  SenseLevel? level(SenseBarPopup p) => p == SenseBarPopup.status ? statusLevel : infoLevel;

  bool kicked = false;
  final List<bool> menuEvents = [];

  @override
  bool get menuAllowed => !kicked;

  @override
  void onMenu(bool open) {
    menuEvents.add(open);
    if (open) kicked = false;
  }

  /// Another popup (the chat) takes the place.
  void kick() {
    kicked = true;
    notifyListeners();
  }
}
