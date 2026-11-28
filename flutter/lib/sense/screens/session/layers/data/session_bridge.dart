// Sense Remote: the connection layers' link to the RustDesk session (YH O13–O15).
// Quality values: `QualityMonitorModel.data` (TK7; D1 `last_frame_ms`, `loss_est`).
// Session-ending messages: [SenseSessionHub] (models/model.dart `handleMsgBox`).
import 'package:flutter/foundation.dart' show VoidCallback;

import '../../../../../common.dart' show closeConnection;
import '../../../../../common/shared_state.dart' show ConnectionType, ConnectionTypeState;
import '../../../../../consts.dart' show kInvalidValueStr;
import '../../../../../models/chat_model.dart';
import '../../../../../models/model.dart';
import '../../../../../models/platform_model.dart';
import '../../../shared/chat/data/files.dart' show senseParseFileJobs;
import '../../data/sense_peer_status.dart' show SensePeerStatusClient;
import '../../../../strings/connect.dart';
import '../../bar/session_popups.dart' show SenseSessionPopups;
import '../connect_cards.dart';
import '../layer_controller.dart';
import '../link_machine.dart' show SenseLinkPhase;

class SenseFfiLayerHost implements SenseLayerHost {
  SenseFfiLayerHost(this.id, this.ffi);

  final String id;
  final FFI ffi;

  @override
  SenseLinkRaw readLink() {
    _readFiles();
    final d = ffi.qualityMonitorModel.data;
    return SenseLinkRaw(
      delay: d.delay,
      fps: d.fps,
      lossEst: d.lossEst,
      lastFrameMs: d.lastFrameMs,
      lastFrameAt: d.lastFrameAt,
      probeAt: d.probeAt,
      direct: _direct(),
      speed: d.speed,
      waitingImage: _waitingImage(),
      serverName: _serverName(),
    );
  }

  /// Sürüm 11 (#144): server name for the connection card line.
  String? _serverName() {
    try {
      return bind.sessionSenseServerName(sessionId: ffi.sessionId);
    } catch (_) {
      return null;
    }
  }

  /// Sürüm 11 (#121): the Host's peer info came (login done) but no picture yet.
  bool _waitingImage() {
    try {
      return ffi.ffiModel.pi.isSet.value && ffi.ffiModel.waitForFirstImage.value;
    } catch (_) {
      return false;
    }
  }

  /// Sürüm 10 (#110): connection type for the good-link card (same source as the bar).
  bool? _direct() {
    try {
      final v = ConnectionTypeState.find(ffi.id).direct.value;
      if (v == kInvalidValueStr) return null;
      return v == ConnectionType.strDirect;
    } catch (_) {
      return null;
    }
  }

  @override
  int chatMessages() {
    final body = ffi.chatModel.messages[MessageKey(ffi.id, ChatModel.clientModeID)];
    return body?.chatMessages.length ?? 0;
  }

  /// Chat files of this session, both directions (`chat_file::file_count` = the
  /// rows of `session_sense_file_jobs`). The bridge call is async, so the last
  /// count is kept and read again on every link reading (once a second).
  int _files = 0;

  void _readFiles() {
    bind.sessionSenseFileJobs(sessionId: ffi.sessionId).then((raw) {
      final n = senseParseFileJobs(raw).length;
      // The list is dropped when the session closes (S12); keep the last count.
      if (n > 0) _files = n;
    }).catchError((_) {});
  }

  @override
  int chatFiles() {
    _readFiles();
    return _files;
  }

  @override
  void goHome() => closeConnection(id: id);

  @override
  void reconnect() => ffi.ffiModel.reconnect(ffi.dialogManager, ffi.sessionId, false);

  /// Sürüm 11 (O1): the same new round as RustDesk's reconnect, without its "Connecting…"
  /// dialog (the lost card shows the attempt). A round still connecting is left alone
  /// (`Session::reconnect`).
  @override
  void retry() {
    try {
      ffi.inputModel.setRelativeMouseMode(false);
    } catch (_) {}
    bind.sessionReconnect(sessionId: ffi.sessionId, forceRelay: false);
  }

  /// Sürüm 11 (O2): every window of the connection closes, then this one.
  @override
  void endConnection() {
    // The other windows are found through this window's session: close it only afterwards.
    bind
        .sessionSenseEndAll(sessionId: ffi.sessionId)
        .catchError((_) {})
        .whenComplete(() => closeConnection(id: id));
  }

  @override
  void shareActivity() => bind.sessionSenseActivity(sessionId: ffi.sessionId);

  @override
  Duration? sharedIdle() {
    try {
      final ms = bind.sessionSenseIdleMs(sessionId: ffi.sessionId);
      return ms < 0 ? null : Duration(milliseconds: ms);
    } catch (_) {
      return null;
    }
  }

  /// A video refresh request resets the Host's idle timer
  /// (`connection.rs` `RefreshVideoDisplay` → `update_auto_disconnect_timer`).
  @override
  void keepAlive() {
    final display = ffi.ffiModel.pi.currentDisplay;
    // "All displays" is -1; any display resets the timer.
    bind.sessionRefresh(sessionId: ffi.sessionId, display: display < 0 ? 0 : display);
  }

  @override
  void closePopups() {
    ffi.dialogManager.dismissAll();
    // Status, display info and the bar lists share one popup place (C1).
    SenseSessionPopups.closeAllOf(id);
  }
}

/// Sürüm 12 (#164): the connecting cards' link to a RustDesk session of any window kind.
class SenseFfiConnectHost implements SenseConnectHost {
  SenseFfiConnectHost(this.id, this.ffi, {this.kind = SenseConnectKind.screen, VoidCallback? onClose})
      : _onClose = onClose;

  final String id;
  final FFI ffi;
  final SenseConnectKind kind;
  final VoidCallback? _onClose;

  @override
  String get peerName {
    try {
      final alias = bind.mainGetPeerOptionSync(id: id, key: 'alias').trim();
      if (alias.isNotEmpty) return alias;
    } catch (_) {}
    final host = ffi.ffiModel.pi.hostname.trim();
    return host.isNotEmpty ? host : SenseConnectStrings.remoteFallback;
  }

  bool get _peerInfo {
    try {
      return ffi.ffiModel.pi.isSet.value;
    } catch (_) {
      return false;
    }
  }

  @override
  bool get connected {
    if (!_peerInfo) return false;
    if (kind != SenseConnectKind.screen && kind != SenseConnectKind.camera) return true;
    try {
      if (!ffi.ffiModel.waitForFirstImage.value) return true;
    } catch (_) {
      return true;
    }
    // The session layers' "Görüntü bekleniyor" card is up: it takes over.
    return SenseLayerController.find(id)?.waitingImage ?? false;
  }

  @override
  bool get layerOwnsScreen {
    final c = SenseLayerController.find(id);
    if (c == null) return false;
    return c.ended != null || c.link.phase != SenseLinkPhase.normal;
  }

  @override
  int get step {
    if (_peerInfo) return 2;
    try {
      final v = ConnectionTypeState.find(ffi.id).direct.value;
      if (v != kInvalidValueStr && v.isNotEmpty) return 1;
    } catch (_) {}
    return 0;
  }

  @override
  bool get trustAvailable {
    try {
      return bind.sessionGetEnableTrustedDevices(sessionId: ffi.sessionId);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> remembered() async => await bind.sessionGetRemember(sessionId: ffi.sessionId) ?? false;

  @override
  void login(String password, bool remember) =>
      ffi.login('', '', ffi.sessionId, password, remember);

  @override
  void send2fa(String code, bool trust) => ffi.send2FA(ffi.sessionId, code, trust);

  @override
  void retry() {
    try {
      ffi.inputModel.setRelativeMouseMode(false);
    } catch (_) {}
    bind.sessionReconnect(sessionId: ffi.sessionId, forceRelay: false);
  }

  @override
  Future<SenseOfflineInfo?> offlineInfo() async {
    // Sürüm 12: the panel's peer-status (the same key the status popup uses).
    final status = (await SensePeerStatusClient().fetch(id)).status;
    if (status == null) return null;
    return SenseOfflineInfo(lastSeenAt: status.lastSeenAt, wakeable: status.wakeable);
  }

  @override
  void close() {
    final f = _onClose;
    if (f != null) {
      f();
    } else {
      closeConnection(id: id);
    }
  }
}
