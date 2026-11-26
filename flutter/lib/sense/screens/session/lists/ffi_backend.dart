// Sense Remote: the session backend over the RustDesk session (TK9 §3). Every list item
// calls the same RustDesk function as the stock menu it replaces; the conditions are in
// rules.dart. Differences from the stock menus, all on purpose:
//  - no dialog where Sense has an in-place step: restart asks in the list (T7), the
//    keyboard type and trackpad speed are set in the list (no chooser / dialog windows),
//    custom quality is set in the list (no custom quality dialog);
//  - ghost mode never opens a window (S9-b): a short note next to the button instead;
//  - Bitir closes without the note window (decision 4).
// Sürüm 9 (Paket L): View camera, Terminal as administrator, Always connect via relay, the
// drawing settings (texture / D3D) and the custom resolution call the same RustDesk
// functions as the peer card, the settings page and the resolution menu.
import 'package:flutter_hbb/sense/screens/session/sense_swap_key_default.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../../common.dart';
import '../../../../common/shared_state.dart';
import '../../../../common/widgets/dialog.dart' show showRequestElevationDialog, showAuditDialog;
import '../../../../common/widgets/keyboard_shortcuts/display.dart';
import '../../../../common/widgets/toolbar.dart'
    show TToggleMenu, allowDisplaySwitchInPrivacyMode, toolbarPrivacyMode;
import '../../../../consts.dart';
import '../../../diag_log.dart';
import '../../../../desktop/widgets/kb_layout_type_chooser.dart' show KBLayoutType;
import '../../../../desktop/widgets/remote_toolbar.dart' show ScreenAdjustor, ToolbarState;
import '../../../../models/model.dart';
import '../../../../models/platform_model.dart';
import '../../../../models/shortcut_model.dart';
import '../../../../models/state_model.dart' show stateGlobal;
import '../../../../utils/scale.dart' show getSessionCustomScalePercent;
import '../../../strings/session.dart';
import '../../../tokens/sense_tokens.dart' show SenseSizes;
import '../data/grants.dart';
import '../data/session_state.dart';
import '../layers/layer_controller.dart' show SenseLayerController;
import '../sense_remote_window.dart' show SenseAutoGhost, senseGhostToggle;
import 'backend.dart';
import 'rules.dart';

/// Platform addition a peer sends when it can show its cameras (RustDesk server,
/// Windows and Linux only).
const String kSensePlatformAdditionsSupportViewCamera = 'support_view_camera';

/// The six read-only shortcut rows of O5 and their RustDesk actions.
const List<(String, String)> kSenseShortcutRows = [
  (kShortcutActionToggleFullscreen, SenseSessionStrings.scFullscreen),
  (kShortcutActionToggleToolbar, SenseSessionStrings.scToolbar),
  (kShortcutActionSwitchDisplayNext, SenseSessionStrings.scNextScreen),
  (kShortcutActionSendCtrlAltDel, SenseSessionStrings.scCtrlAltDel),
  (kShortcutActionScreenshot, SenseSessionStrings.scScreenshot),
  (kShortcutActionCloseTab, SenseSessionStrings.scEnd),
];

/// "Ctrl+Alt+Shift+Enter" for a binding map (`{mods:[…], key:…}`), as RustDesk shows it.
String senseShortcutText(Map<String, Object?> binding, {required bool mac}) {
  final mods = binding['mods'] is List ? (binding['mods'] as List).whereType<String>().toList() : const <String>[];
  final parts = <String>[];
  for (final m in ['primary', 'ctrl', 'alt', 'shift']) {
    if (!mods.contains(m)) continue;
    parts.add(switch (m) {
      'primary' => mac ? 'Cmd' : 'Ctrl',
      'ctrl' => 'Ctrl',
      'alt' => mac ? 'Option' : 'Alt',
      _ => 'Shift',
    });
  }
  final key = (binding['key'] ?? '').toString();
  parts.add(switch (key) {
    'delete' => 'Del',
    'enter' => 'Enter',
    // Words, not arrow glyphs: Poppins has none (G1).
    'arrow_left' => 'Sol',
    'arrow_right' => 'Sağ',
    'arrow_up' => 'Yukarı',
    'arrow_down' => 'Aşağı',
    _ => key.startsWith('digit') ? key.substring(5) : key.toUpperCase(),
  });
  return parts.join('+');
}

class SenseFfiSessionBackend extends SenseSessionBackend {
  SenseFfiSessionBackend({
    required this.ffi,
    required this.toolbarState,
    required this.contextOf,
  }) {
    _signals = SenseSessionEvents.of(ffi.id);
    _listen();
  }

  final FFI ffi;
  final ToolbarState toolbarState;

  /// A context under the window's navigator (dialogs that stay: elevation, note; new
  /// connection windows).
  final BuildContext Function() contextOf;

  late final SenseSessionSignals _signals;
  final List<Worker> _workers = [];
  bool _disposed = false;

  // Async values held after [refresh].
  String _viewStyle = SenseRd.viewAdaptive;
  String _imageQuality = SenseRd.qualityBalanced;
  String _scrollStyle = SenseRd.scrollAuto;
  String _keyboardMode = SenseRd.modeMap;
  String _codec = 'auto';
  List<String> _codecs = const ['auto'];
  int _customScale = 100;
  int _customQuality = 50;
  int _customFps = 30;
  bool _publicRelay = false;
  bool _localMultiScreens = false;
  bool _canAdjust = false;
  bool _forceRelay = false;

  late final ScreenAdjustor _adjustor =
      ScreenAdjustor(id: ffi.id, ffi: ffi, cbExitFullscreen: () => stateGlobal.setFullscreen(false));

  SessionID get _sid => ffi.sessionId;
  PeerInfo get _pi => ffi.ffiModel.pi;
  FfiModel get _m => ffi.ffiModel;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _listen() {
    _m.addListener(_notify);
    ffi.qualityMonitorModel.addListener(_notify);
    ffi.recordingModel.addListener(_notify);
    // O1 "%N ölçekte" follows the canvas.
    ffi.canvasModel.addListener(_notify);
    _signals.addListener(_notify);
    void watch(RxInterface<Object?> rx) => _workers.add(ever(rx, (_) => _notify()));
    watch(_pi.isSet);
    watch(_pi.displaysCount);
    watch(stateGlobal.fullscreen);
    _workers.add(ever(toolbarState.hide, (_) => syncInset()));
    watch(toolbarState.hide);
    _workers.add(ever(_pi.isSet, (_) => syncInset()));
    watch(ffi.inputModel.relativeMouseMode);
    // Karar #95: ghost mode opens by itself when the first image arrives.
    _workers.add(ever(_m.waitForFirstImage, (_) => _autoGhostOnImage()));
    _autoGhostOnImage();
    for (final find in <RxInterface<Object?> Function()>[
      () => PrivacyModeState.find(ffi.id),
      () => BlockInputState.find(ffi.id),
      () => CurrentDisplayState.find(ffi.id),
      () => ShowRemoteCursorState.find(ffi.id),
    ]) {
      try {
        watch(find());
      } catch (_) {
        // Not registered yet for this peer; the model listener covers the change.
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _m.removeListener(_notify);
    ffi.qualityMonitorModel.removeListener(_notify);
    ffi.recordingModel.removeListener(_notify);
    ffi.canvasModel.removeListener(_notify);
    _signals.removeListener(_notify);
    for (final w in _workers) {
      w.dispose();
    }
    super.dispose();
  }

  bool _toggleOpt(String option) => bind.sessionGetToggleOptionSync(sessionId: _sid, arg: option);

  Future<void> _flip(String option) async {
    await bind.sessionToggleOption(sessionId: _sid, value: option);
    _notify();
  }

  void _set(String option, bool v) {
    if (_toggleOpt(option) != v) _flip(option);
  }

  T _try<T>(T Function() f, T fallback) {
    try {
      return f();
    } catch (_) {
      return fallback;
    }
  }

  // ---- Session ----
  @override
  String get peerId => ffi.id;

  @override
  String get peerName {
    final alias = _try(() => bind.mainGetPeerOptionSync(id: ffi.id, key: 'alias'), '');
    if (alias.isNotEmpty) return alias;
    return _pi.hostname.isNotEmpty ? _pi.hostname : ffi.id;
  }

  @override
  bool get ready => _pi.isSet.isTrue;

  SensePeerOs get _os => switch (_pi.platform) {
        kPeerPlatformWindows => SensePeerOs.windows,
        kPeerPlatformMacOS => SensePeerOs.mac,
        kPeerPlatformLinux => SensePeerOs.linux,
        kPeerPlatformAndroid => SensePeerOs.android,
        _ => SensePeerOs.other,
      };

  bool get _fileClipboard {
    final old = versionCmp(_pi.version, '1.2.4') < 0 && isWindows && _pi.platform == kPeerPlatformWindows;
    final now = versionCmp(_pi.version, '1.2.4') >= 0 &&
        bind.mainHasFileClipboard() &&
        _pi.platformAdditions.containsKey(kPlatformAdditionsHasFileClipboard);
    return old || now;
  }

  @override
  SensePeerFacts get facts => SensePeerFacts(
        os: _os,
        localMac: isMacOS,
        version: _pi.version,
        defaultConn: ffi.connType == ConnType.defaultConn,
        viewOnly: _m.viewOnly,
        keyboard: _m.keyboard,
        sasEnabled: _pi.sasEnabled,
        deniedPerms: {
          for (final e in _m.permissions.entries)
            if (e.value == false) e.key,
        },
        displaysCount: _pi.displays.length,
        supportMultiDisplay: _pi.isSupportMultiDisplay,
        currentDisplay: _pi.currentDisplay,
        multiUiSession: _try(() => bind.sessionIsMultiUiSession(sessionId: _sid), false),
        localMultiScreens: _localMultiScreens,
        installed: _pi.isInstalled,
        rustDeskIdd: _pi.isRustDeskIdd,
        amyuniIdd: _pi.isAmyuniIdd,
        cursorEmbedded: _pi.cursorEmbedded,
        wayland: _pi.isWayland,
        localWayland: isLinux && _try(() => bind.mainCurrentIsWayland(), false),
        codecFormat: ffi.qualityMonitorModel.data.codecFormat,
        privacyOn: ghostOn,
        resolutionsCount: _pi.resolutions.length,
        virtualResolution: _m.isVirtualDisplayResolution,
        screenshotSupported: isDesktop &&
            _try(() => bind.sessionGetCommonSync(sessionId: _sid, key: 'is_screenshot_supported', param: ''), '') ==
                'true',
        elevationOffered: ffi.elevationModel.showRequestMenu,
        accountDisabled: _try(() => bind.isDisableAccount(), false),
        hideRecordingButton: _try(() => bind.mainGetLocalOption(key: kOptionHideRecordingButton), '') == 'Y',
        recording: ffi.recordingModel.start,
        relativeMouseSupported: ffi.inputModel.isRelativeMouseModeSupported,
        fileClipboard: _fileClipboard,
        audioPerm: _m.permissions['audio'] != false,
        viewCameraSupported: _pi.platformAdditions[kSensePlatformAdditionsSupportViewCamera] == true,
        localWindows: isWindows,
      );

  @override
  SenseSessionGrants get grants => senseReadSessionGrants();

  @override
  SenseLinkSample get link {
    final d = ffi.qualityMonitorModel.data;
    final ct = _try(() => ConnectionTypeState.find(ffi.id), null);
    final path = ct == null || ct.direct.value == kInvalidValueStr
        ? SenseLinkPath.unknown
        : ct.direct.value == ConnectionType.strDirect
            ? SenseLinkPath.direct
            : SenseLinkPath.relay;
    final at = d.lastFrameAt;
    final layer = SenseLayerController.find(ffi.id);
    return SenseLinkSample(
      path: path,
      fps: senseParseFps(d.fps),
      rttMs: senseParseMs(d.delay),
      lastFrameMs: d.lastFrameMs == null || at == null
          ? null
          : d.lastFrameMs! + DateTime.now().difference(at).inMilliseconds,
      lossPct: d.lossEst,
      // O13: the connection layer decides "Dalgalı" (C4); the T6 limits only without it.
      wavy: SenseLayerController.find(ffi.id)?.wavy.value,
      onRestoreLayer: layer != null && layer.minimized ? layer.restoreCard : null,
    );
  }

  @override
  Future<void> refresh() async {
    if (!ready) return;
    try {
      _viewStyle = await bind.sessionGetViewStyle(sessionId: _sid) ?? _viewStyle;
      _imageQuality = await bind.sessionGetImageQuality(sessionId: _sid) ?? _imageQuality;
      _scrollStyle = await bind.sessionGetScrollStyle(sessionId: _sid) ?? _scrollStyle;
      _keyboardMode = await bind.sessionGetKeyboardMode(sessionId: _sid) ?? SenseRd.modeLegacy;
      _codec = await bind.sessionGetOption(sessionId: _sid, arg: kOptionCodecPreference) ?? 'auto';
      if (_codec.isEmpty) _codec = 'auto';
      _codecs = _parseCodecs(await bind.sessionAlternativeCodecs(sessionId: _sid));
      _customScale = await getSessionCustomScalePercent(_sid);
      final q = await bind.sessionGetCustomImageQuality(sessionId: _sid);
      if (q != null && q.isNotEmpty) _customQuality = q[0];
      final fps = await bind.sessionGetOption(sessionId: _sid, arg: 'custom-fps');
      _customFps = int.tryParse(fps ?? '') ?? _customFps;
      final direct = _try(() => ConnectionTypeState.find(ffi.id).direct.value == ConnectionType.strDirect, false);
      _publicRelay = await bind.mainIsUsingPublicServer() && !direct;
      _localMultiScreens = (await getScreenRectList()).length > 1;
      _canAdjust = await _adjustor.isWindowCanBeAdjusted();
      _forceRelay =
          option2bool(kOptionForceAlwaysRelay, await bind.sessionGetOption(sessionId: _sid, arg: kOptionForceAlwaysRelay) ?? '');
      KBLayoutType.value = bind.getLocalKbLayoutType();
    } catch (e) {
      debugPrint('Sense session refresh: $e');
    }
    _notify();
  }

  static List<String> _parseCodecs(String raw) {
    try {
      final j = jsonDecode(raw) as Map;
      return [
        'auto',
        if (j['vp8'] == true) 'vp8',
        'vp9',
        if (j['av1'] == true) 'av1',
        if (j['h264'] == true) 'h264',
        if (j['h265'] == true) 'h265',
      ];
    } catch (_) {
      return const ['auto'];
    }
  }

  // ---- Bar ----
  @override
  bool get barHidden => toolbarState.hide.isTrue;

  @override
  void toggleBar() => toolbarState.switchHide(_sid);

  /// The remote screen starts under the tab strip and the bar: tell the canvas, so
  /// "Sığdır" fits the image into what is left (state_model `tabBarHeight`).
  void syncInset() {
    final h = barHidden ? 0.0 : SenseSizes.sessionToolbarHeight;
    if (stateGlobal.senseBarHeight.value != h) stateGlobal.senseBarHeight.value = h;
    if (ready) ffi.canvasModel.updateViewStyle();
  }

  @override
  bool get fullscreen => stateGlobal.fullscreen.isTrue;

  @override
  void toggleFullscreen() => stateGlobal.setFullscreen(!fullscreen);

  /// Decision 4: no note window; the note is in Eylemler › Oturuma not ekle.
  @override
  void end() => closeConnection(id: ffi.id);

  RxString? get _privacy => _try<RxString?>(() => PrivacyModeState.find(ffi.id), null);

  final SenseAutoGhost _autoGhost = SenseAutoGhost();

  /// Not written to the peer's saved options by us: the next session simply starts
  /// on again (each backend has its own [SenseAutoGhost]).
  void _autoGhostOnImage() {
    if (_disposed || _m.waitForFirstImage.value) return;
    try {
      if (_autoGhost.run(
        ready: ready,
        on: ghostOn,
        available: ghostAvailable,
        needsDisplay1: ghostNeedsDisplay1,
        toggle: senseGhostToggle(_ghostMenus, ghostOn),
      )) {
        senseUiGhost(true, reason: 'session-start');
      }
    } catch (e) {
      debugPrint('Sense ghost auto start: $e'); // never breaks the connection
    }
  }

  @override
  bool get ghostOn => (_privacy?.value ?? '').isNotEmpty;

  List<TToggleMenu> get _ghostMenus {
    final p = _privacy;
    if (p == null) return const [];
    return toolbarPrivacyMode(p, contextOf(), ffi.id, ffi);
  }

  @override
  bool get ghostAvailable {
    if (!ready || (!grants.allows(SenseGrant.privacyMode) && !ghostOn)) return false;
    return senseGhostToggle(_ghostMenus, ghostOn) != null;
  }

  String? get _ghostImpl {
    final impls = _pi.platformAdditions[kPlatformAdditionsSupportedPrivacyModeImpl] as List<dynamic>?;
    if (impls == null) return kPrivacyModeImplMag;
    if (impls.isEmpty) return null;
    return (impls.first as List<dynamic>).first as String;
  }

  @override
  bool get ghostNeedsDisplay1 {
    final impl = _ghostImpl;
    if (impl == null) return false;
    if (allowDisplaySwitchInPrivacyMode(_pi, impl)) return false;
    final multi = _try(() => bind.sessionIsMultiUiSession(sessionId: _sid), false);
    return !(_pi.currentDisplay == 0 && !multi);
  }

  @override
  void toggleGhost() {
    _signals.clearPrivacyNote();
    senseGhostToggle(_ghostMenus, ghostOn)?.call();
  }

  @override
  String? get ghostNote => _signals.privacyNote;

  @override
  int get ghostNoteSerial => _signals.privacySerial;

  @override
  bool get inputLocked => _try(() => BlockInputState.find(ffi.id).value, false);

  @override
  bool get recordingOn => ffi.recordingModel.start;

  // ---- O3 ----
  @override
  List<SenseDisplayRef> get displays => [
        for (var i = 0; i < _pi.displays.length; i++)
          SenseDisplayRef(i,
              primary: _pi.primaryDisplay == i, width: _pi.displays[i].width, height: _pi.displays[i].height),
      ];

  @override
  int get currentDisplay => _pi.currentDisplay;

  /// Same as the stock monitor buttons (separate window when "Her ekranı ayrı pencerede aç").
  @override
  void openDisplay(int i) {
    if (_pi.currentDisplay == i) return;
    senseUiDisplay(from: _pi.currentDisplay == kAllDisplayValue ? 'all' : _pi.currentDisplay, to: i == kAllDisplayValue ? 'all' : i);
    if (individualWindows && i != kAllDisplayValue) {
      openMonitorInNewTabOrWindow(i, ffi.id, _pi);
    } else {
      openMonitorInTheSameTab(i, ffi, _pi);
    }
    _notify();
  }

  @override
  bool get individualWindows =>
      _try(() => bind.sessionGetDisplaysAsIndividualWindows(sessionId: _sid), 'N') == 'Y';

  @override
  void setIndividualWindows(bool v) {
    bind.sessionSetDisplaysAsIndividualWindows(sessionId: _sid, value: v ? 'Y' : 'N');
    _notify();
  }

  @override
  List<SenseResolution> get resolutions => [for (final r in _pi.resolutions) SenseResolution(r.width, r.height)];

  @override
  SenseResolution? get currentResolution {
    final rect = _m.rect;
    if (rect == null || _pi.currentDisplay == kAllDisplayValue) return null;
    final scale = _pi.scaleOfDisplay(_pi.currentDisplay);
    return SenseResolution((rect.width / scale).round(), (rect.height / scale).round());
  }

  @override
  SenseResolution? get originalResolution {
    final d = _pi.tryGetDisplayIfNotAllDisplay();
    if (d == null || !d.isOriginalResolutionSet) return null;
    final r = SenseResolution(d.originalWidth, d.originalHeight);
    return resolutions.contains(r) ? r : null;
  }

  @override
  SenseResolution? get fitLocalResolution {
    try {
      final j = jsonDecode(bind.mainGetMainDisplay()) as Map;
      final local = SenseResolution(j['w'] as int, j['h'] as int);
      if (_m.isVirtualDisplayResolution || resolutions.contains(local)) return local;
    } catch (_) {}
    return null;
  }

  @override
  void setResolution(SenseResolution r) {
    if (_pi.currentDisplay == kAllDisplayValue) return;
    bind.sessionChangeResolution(sessionId: _sid, display: _pi.currentDisplay, width: r.width, height: r.height);
    _notify();
  }

  @override
  bool get useAllMyDisplays =>
      _try(() => bind.sessionGetUseAllMyDisplaysForTheRemoteSession(sessionId: _sid), 'N') == 'Y';

  @override
  void setUseAllMyDisplays(bool v) {
    bind.sessionSetUseAllMyDisplaysForTheRemoteSession(sessionId: _sid, value: v ? 'Y' : 'N');
    _notify();
  }

  @override
  int get virtualDisplayCount =>
      _pi.isRustDeskIdd ? _pi.RustDeskVirtualDisplays.length : _pi.amyuniVirtualDisplayCount;

  @override
  bool get canAddVirtualDisplay => virtualDisplayCount < kMaxVirtualDisplayCount;

  @override
  void addVirtualDisplay() {
    if (_pi.isRustDeskIdd) {
      final used = _pi.RustDeskVirtualDisplays;
      for (var i = 1; i <= kMaxVirtualDisplayCount; i++) {
        if (!used.contains(i)) {
          bind.sessionToggleVirtualDisplay(sessionId: _sid, index: i, on: true);
          return;
        }
      }
    } else {
      bind.sessionToggleVirtualDisplay(sessionId: _sid, index: 0, on: true);
    }
  }

  @override
  void removeAllVirtualDisplays() =>
      bind.sessionToggleVirtualDisplay(sessionId: _sid, index: kAllVirtualDisplay, on: false);

  // ---- O4 ----
  @override
  String get viewStyle => _viewStyle;

  @override
  void setViewStyle(String v) {
    _viewStyle = v;
    bind.sessionSetViewStyle(sessionId: _sid, value: v).then((_) => ffi.canvasModel.updateViewStyle());
    _notify();
  }

  @override
  int get customScalePercent => _customScale;

  @override
  void setCustomScalePercent(int v) async {
    _customScale = v;
    _viewStyle = SenseRd.viewCustom;
    _notify();
    await bind.sessionSetFlutterOption(sessionId: _sid, k: kCustomScalePercentKey, v: v.toString());
    await bind.sessionSetViewStyle(sessionId: _sid, value: kRemoteViewStyleCustom);
    await ffi.canvasModel.updateViewStyle();
  }

  @override
  String get imageQuality => _imageQuality;

  @override
  void setImageQuality(String v) async {
    _imageQuality = v;
    _notify();
    await bind.sessionSetImageQuality(sessionId: _sid, value: v);
    if (v == kRemoteImageQualityCustom) {
      await bind.sessionSetCustomImageQuality(sessionId: _sid, value: _customQuality);
      if (showCustomFps) await bind.sessionSetCustomFps(sessionId: _sid, fps: _customFps);
    }
  }

  @override
  void refreshVideo() => sessionRefreshVideo(_sid, _pi);

  @override
  String get scrollStyle => _scrollStyle;

  @override
  void setScrollStyle(String v) async {
    _scrollStyle = v;
    _notify();
    await bind.sessionSetScrollStyle(sessionId: _sid, value: v);
    ffi.canvasModel.updateScrollStyle();
  }

  /// "Görünümü sıfırla": RustDesk's mobile "Reset canvas", wired for the desktop (TK9 §3).
  @override
  void resetView() => ffi.cursorModel.reset();

  @override
  bool get canAdjustWindow => _canAdjust;

  @override
  void adjustWindow() => _adjustor.doAdjustWindow(contextOf());

  @override
  int get customQuality => _customQuality;

  @override
  void setCustomQuality(int v) {
    _customQuality = v;
    bind.sessionSetCustomImageQuality(sessionId: _sid, value: v);
    _notify();
  }

  @override
  int get customFps => _customFps;

  @override
  void setCustomFps(int v) {
    _customFps = v;
    bind.sessionSetCustomFps(sessionId: _sid, fps: v);
    _notify();
  }

  @override
  bool get showCustomFps => SenseRules.customFps(facts, publicServerRelay: _publicRelay);

  @override
  bool get showMoreQuality => SenseRules.moreQuality(facts, publicServerRelay: _publicRelay);

  @override
  bool get trueColor => _toggleOpt('i444');

  @override
  void setTrueColor(bool v) async {
    if (_toggleOpt('i444') == v) return;
    await bind.sessionToggleOption(sessionId: _sid, value: 'i444');
    bind.sessionChangePreferCodec(sessionId: _sid);
    _notify();
  }

  @override
  List<String> get codecs => _codecs;

  @override
  String get codec => _codec;

  @override
  void setCodec(String v) async {
    _codec = v;
    _notify();
    await bind.sessionPeerOption(sessionId: _sid, name: kOptionCodecPreference, value: v);
    bind.sessionChangePreferCodec(sessionId: _sid);
  }

  @override
  String? get activeCodec => ffi.qualityMonitorModel.data.codecFormat;

  @override
  bool get muted => _toggleOpt('disable-audio');

  @override
  void setMuted(bool v) => _set('disable-audio', v);

  @override
  int? get viewScalePercent {
    if (!ready) return null;
    final s = _try(() => ffi.canvasModel.scale, 0.0);
    if (!s.isFinite || s <= 0) return null;
    return (s * 100).round();
  }

  /// Same getter / setter as the RustDesk settings page ("Use texture rendering").
  @override
  bool get textureRender => _try(() => bind.mainGetUseTextureRender(), false);

  @override
  void setTextureRender(bool v) async {
    await bind.mainSetLocalOption(key: kOptionTextureRender, value: v ? 'Y' : 'N');
    _notify();
  }

  @override
  bool get d3dRender => _try(() => mainGetLocalBoolOptionSync(kOptionD3DRender), false);

  @override
  void setD3dRender(bool v) async {
    await mainSetLocalBoolOption(kOptionD3DRender, v);
    _notify();
  }

  // ---- O5 ----
  @override
  List<String> get keyboardModes {
    bool supported(String m) => _try(() => bind.sessionIsKeyboardModeSupported(sessionId: _sid, mode: m), false);
    String? only;
    if (isInputSourceFlutter && isDesktop) {
      if (supported(kKeyMapMode)) {
        only = kKeyMapMode;
      } else if (supported(kKeyLegacyMode)) {
        only = kKeyLegacyMode;
      }
    }
    return [
      for (final m in [kKeyMapMode, kKeyTranslateMode, kKeyLegacyMode])
        if ((only == null || m == only) && supported(m) && (!_pi.isWayland || m == kKeyMapMode)) m,
    ];
  }

  @override
  String get keyboardMode => _keyboardMode;

  @override
  void setKeyboardMode(String v) async {
    _keyboardMode = v;
    _notify();
    await bind.sessionSetKeyboardMode(sessionId: _sid, value: v);
    await ffi.inputModel.updateKeyboardMode();
  }

  @override
  bool get viewOnly => _m.viewOnly;

  @override
  void setViewOnly(bool v) async {
    if (_m.viewOnly == v) return;
    await bind.sessionToggleOption(sessionId: _sid, value: kOptionToggleViewOnly);
    final now = await bind.sessionGetToggleOption(sessionId: _sid, arg: kOptionToggleViewOnly);
    _m.setViewOnly(ffi.id, now ?? v);
    final mine = await bind.sessionGetToggleOption(sessionId: _sid, arg: kOptionToggleShowMyCursor);
    _m.setShowMyCursor(mine ?? v);
    _notify();
  }

  @override
  bool get swapCtrlCmd => _toggleOpt('allow_swap_key');

  @override
  void setSwapCtrlCmd(bool v) {
    // Sense Remote (S7, #91): the user's choice is remembered for this computer.
    bind.sessionPeerOption(sessionId: _sid, name: kSenseSwapKeyDecidedOption, value: 'Y');
    _set(kSenseSwapKeyOption, v);
  }

  @override
  String get localKbLayout => KBLayoutType.value;

  @override
  void setLocalKbLayout(String v) async {
    await bind.setLocalKbLayoutType(kbLayoutType: v);
    KBLayoutType.value = bind.getLocalKbLayoutType();
    _notify();
  }

  @override
  bool get shortcutsEnabled => _try(() => ShortcutModel.isEnabled(), false);

  @override
  List<SenseShortcutRow> get shortcuts {
    final defaults = {
      for (final b in [...kDefaultShortcutBindings, ...kSenseDefaultShortcutBindings]) b['action'] as String: b,
    };
    return [
      for (final (id, label) in kSenseShortcutRows)
        SenseShortcutRow(
          id,
          label,
          _try(() => ShortcutDisplay.formatFor(id, requireEnabled: false), null) ??
              (defaults[id] == null ? null : senseShortcutText(defaults[id]!, mac: isMacOS)),
        ),
    ];
  }

  @override
  bool get showRemoteCursor => _try(() => ShowRemoteCursorState.find(ffi.id).value, _toggleOpt('show-remote-cursor'));

  @override
  bool get showRemoteCursorLocked {
    if (_pi.currentDisplay == kAllDisplayValue || _try(() => bind.sessionIsMultiUiSession(sessionId: _sid), false)) {
      return false;
    }
    return _try(() => ShowRemoteCursorLockState.find(ffi.id).value, false);
  }

  @override
  void setShowRemoteCursor(bool v) async {
    if (showRemoteCursor == v) return;
    await bind.sessionToggleOption(sessionId: _sid, value: 'show-remote-cursor');
    final now = bind.sessionGetToggleOptionSync(sessionId: _sid, arg: 'show-remote-cursor');
    _try(() => ShowRemoteCursorState.find(ffi.id).value = now, null);
    _notify();
  }

  @override
  bool get showMyCursor => _m.showMyCursor;

  /// Same as the stock "Show my cursor": turning it on also turns view only on.
  @override
  void setShowMyCursor(bool v) async {
    if (_m.showMyCursor == v) return;
    await bind.sessionToggleOption(sessionId: _sid, value: kOptionToggleShowMyCursor);
    final mine = await bind.sessionGetToggleOption(sessionId: _sid, arg: kOptionToggleShowMyCursor) ?? v;
    _m.setShowMyCursor(mine);
    if (mine && !_m.viewOnly) {
      await bind.sessionToggleOption(sessionId: _sid, value: kOptionToggleViewOnly);
      final vo = await bind.sessionGetToggleOption(sessionId: _sid, arg: kOptionToggleViewOnly);
      _m.setViewOnly(ffi.id, vo ?? true);
    }
    _notify();
  }

  @override
  bool get followRemoteCursor => _toggleOpt('follow-remote-cursor');

  /// Following the remote cursor also shows it and locks "show remote cursor" (stock).
  @override
  void setFollowRemoteCursor(bool v) async {
    if (followRemoteCursor == v) return;
    await bind.sessionToggleOption(sessionId: _sid, value: 'follow-remote-cursor');
    final now = _toggleOpt('follow-remote-cursor');
    _try(() => ShowRemoteCursorLockState.find(ffi.id).value = now, null);
    if (now && !_toggleOpt('show-remote-cursor')) {
      await bind.sessionToggleOption(sessionId: _sid, value: 'show-remote-cursor');
      _try(() => ShowRemoteCursorState.find(ffi.id).value = _toggleOpt('show-remote-cursor'), null);
    }
    _notify();
  }

  @override
  bool get followRemoteWindow => _toggleOpt('follow-remote-window');

  @override
  void setFollowRemoteWindow(bool v) => _set('follow-remote-window', v);

  @override
  bool get zoomCursor => _try(() => PeerBoolOption.find(ffi.id, 'zoom-cursor').value, _toggleOpt('zoom-cursor'));

  @override
  void setZoomCursor(bool v) async {
    if (zoomCursor == v) return;
    await bind.sessionToggleOption(sessionId: _sid, value: 'zoom-cursor');
    _try(() => PeerBoolOption.find(ffi.id, 'zoom-cursor').value = _toggleOpt('zoom-cursor'), null);
    _notify();
  }

  @override
  bool get relativeMouse => ffi.inputModel.relativeMouseMode.value;

  @override
  void setRelativeMouse(bool v) {
    final before = ffi.inputModel.relativeMouseMode.value;
    if (!ffi.inputModel.setRelativeMouseMode(v)) ffi.inputModel.relativeMouseMode.value = before;
    _notify();
  }

  @override
  bool get reverseWheel {
    var v = _try(() => bind.sessionGetReverseMouseWheelSync(sessionId: _sid), null) ?? '';
    if (v.isEmpty) v = _try(() => bind.mainGetUserDefaultOption(key: kKeyReverseMouseWheel), '');
    return v == 'Y';
  }

  @override
  void setReverseWheel(bool v) async {
    await bind.sessionSetReverseMouseWheel(sessionId: _sid, value: v ? 'Y' : 'N');
    _notify();
  }

  @override
  bool get swapMouseButtons => _toggleOpt('swap-left-right-mouse');

  @override
  void setSwapMouseButtons(bool v) => _set('swap-left-right-mouse', v);

  @override
  int get trackpadSpeed => ffi.inputModel.trackpadSpeed;

  /// Trackpad speed in the list, not in a dialog (TK9 §3).
  @override
  void setTrackpadSpeed(int v) async {
    await bind.sessionSetTrackpadSpeed(sessionId: _sid, value: v);
    await ffi.inputModel.updateTrackpadSpeed();
    _notify();
  }

  // ---- O6 ----
  @override
  void ctrlAltDel() => bind.sessionCtrlAltDel(sessionId: _sid);

  @override
  bool get screenshotBusy => _m.timerScreenshot != null;

  /// 30 s wait after each screenshot, like the stock menu.
  @override
  void screenshot() {
    if (_m.timerScreenshot != null || _pi.currentDisplay == kAllDisplayValue) return;
    bind.sessionTakeScreenshot(sessionId: _sid, display: _pi.currentDisplay);
    _m.timerScreenshot = Timer(const Duration(seconds: 30), () {
      _m.timerScreenshot = null;
      _notify();
    });
    _notify();
  }

  @override
  void lockScreen() => bind.sessionLockScreen(sessionId: _sid);

  /// The list asked already (in place); no dialog here.
  @override
  void restart() => bind.sessionRestartRemoteDevice(sessionId: _sid);

  @override
  void setBlockInput(bool v) {
    final state = _try<RxBool?>(() => BlockInputState.find(ffi.id), null);
    if (state == null || state.value == v) return;
    bind.sessionToggleOption(sessionId: _sid, value: v ? 'block-input' : 'unblock-input');
    state.value = v;
    _notify();
  }

  @override
  void toggleRecording() => ffi.recordingModel.toggle();

  @override
  void typeClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      bind.sessionInputString(sessionId: _sid, value: text);
    }
  }

  @override
  bool get fileCopyPaste => _toggleOpt(kOptionEnableFileCopyPaste);

  @override
  void setFileCopyPaste(bool v) => _set(kOptionEnableFileCopyPaste, v);

  @override
  bool get clipboardDisabled => _toggleOpt('disable-clipboard');

  @override
  void setClipboardDisabled(bool v) => _set('disable-clipboard', v);

  void _connectWithToken({bool files = false, bool terminal = false, bool tunnel = false, bool camera = false}) {
    final token = bind.sessionGetConnToken(sessionId: _sid);
    connect(contextOf(), ffi.id,
        loginMethod: bind.sessionGetCommonSync(sessionId: _sid, key: 'login_method', param: '') ?? '',
        isFileTransfer: files,
        isViewCamera: camera,
        isTerminal: terminal,
        isTcpTunneling: tunnel,
        connToken: token);
  }

  @override
  void openRemoteFiles() => _connectWithToken(files: true);

  @override
  void requestElevation() => showRequestElevationDialog(_sid, ffi.dialogManager);

  @override
  bool get lockAfterEnd => _toggleOpt('lock-after-session-end');

  @override
  void setLockAfterEnd(bool v) => _set('lock-after-session-end', v);

  @override
  void addNote() => showAuditDialog(ffi);

  @override
  void openTerminal() => _connectWithToken(terminal: true);

  /// Like the RustDesk peer card: the flag is read (and cleared) when the terminal
  /// session is added.
  @override
  void openTerminalAdmin() {
    setEnvTerminalAdmin();
    _connectWithToken(terminal: true);
  }

  @override
  void openTunnel() => _connectWithToken(tunnel: true);

  @override
  void openCamera() => _connectWithToken(camera: true);

  @override
  bool get forceRelay => _forceRelay;

  @override
  bool get forceRelayEverywhere =>
      _try(() => option2bool(kOptionForceAlwaysRelay, bind.mainGetOptionSync(key: kOptionForceAlwaysRelay)), false);

  /// Written to this computer's saved options through the session, so it is kept when the
  /// session saves its config; RustDesk reads it when the next connection starts.
  @override
  void setForceRelay(bool v) async {
    _forceRelay = v;
    _notify();
    await bind.sessionPeerOption(
        sessionId: _sid, name: kOptionForceAlwaysRelay, value: bool2option(kOptionForceAlwaysRelay, v));
  }

  @override
  String get fingerprint => _try(() => FingerprintState.find(ffi.id).value, '');

  @override
  void copyFingerprint() {
    final f = fingerprint;
    if (f.isNotEmpty) Clipboard.setData(ClipboardData(text: f));
  }
}
