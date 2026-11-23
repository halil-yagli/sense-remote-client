// Sense Remote: the connection layers' link to the RustDesk session (YH O13–O15).
// Quality values: `QualityMonitorModel.data` (TK7; D1 `last_frame_ms`, `loss_est`).
// Session-ending messages: [SenseSessionHub] (models/model.dart `handleMsgBox`).
import '../../../../../common.dart' show closeConnection;
import '../../../../../models/chat_model.dart';
import '../../../../../models/model.dart';
import '../../../../../models/platform_model.dart';
import '../../../shared/chat/data/files.dart' show senseParseFileJobs;
import '../../bar/session_popups.dart' show SenseSessionPopups;
import '../layer_controller.dart';

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
    );
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
