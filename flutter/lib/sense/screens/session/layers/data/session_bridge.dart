// Sense Remote: the connection layers' link to the RustDesk session (YH O13–O15).
// Quality values: `QualityMonitorModel.data` (TK7; D1 `last_frame_ms`, `loss_est`).
// Session-ending messages: [SenseSessionHub] (models/model.dart `handleMsgBox`).
import '../../../../../common.dart' show closeConnection;
import '../../../../../models/chat_model.dart';
import '../../../../../models/model.dart';
import '../../../../../models/platform_model.dart';
import '../../sense_remote_window.dart' show SenseRemoteSession;
import '../layer_controller.dart';

class SenseFfiLayerHost implements SenseLayerHost {
  SenseFfiLayerHost(this.id, this.ffi);

  final String id;
  final FFI ffi;

  @override
  SenseLinkRaw readLink() {
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

  // TODO(C3, D3d1): files sent in the chat (`session_sense_file_jobs`); 0 until then.
  @override
  int chatFiles() => 0;

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
    final s = SenseRemoteSession.of(id);
    if (s.statusOpen) s.toggleStatus();
    if (s.infoOpen) s.toggleInfo();
    s.setChatOpen(false);
  }
}
