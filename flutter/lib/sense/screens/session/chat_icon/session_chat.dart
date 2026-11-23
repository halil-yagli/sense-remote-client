// Sense Remote: wires the chat of one Controller connection (YH O10, O11
// sesli, O12, S12, #62) to RustDesk: text through `session_send_chat`, the
// other side's text and voice-call events through ChatModel (which hands them
// to [SenseChatController] instead of RustDesk's floating chat), files through
// SenseSessionChatFiles (D3d1), call through SenseSessionChatCall.
//
// Mount once over the remote screen, under the toolbar:
//   SenseSessionChat(ffi: ffi, computerName: name, popups: sessionPopups)

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../../../common.dart' show windowOnTop;
import '../../../../models/model.dart' show FFI;
import '../../../../models/platform_model.dart';
import '../../../../models/state_model.dart' show stateGlobal;
import '../../../sense.dart';
import '../../shared/chat/chat_controller.dart';
import '../../shared/chat/data/call.dart';
import '../../shared/chat/data/files.dart';
import '../popups/status/status_widgets.dart' show SenseChatIconPlacement;
import 'chat_layer.dart';

/// The chat controller of a connection, made from its FFI.
SenseChatController senseSessionChatController(FFI ffi) {
  return SenseChatController(
    sendText: (t) => bind.sessionSendChat(sessionId: ffi.sessionId, text: t),
    files: SenseSessionChatFiles(sessionId: ffi.sessionId),
    call: SenseSessionChatCall(sessionId: ffi.sessionId),
  );
}

/// desktop_drop around the chat popup (O12 sürükle-bırak).
Widget senseDesktopDrop(
    Widget child, void Function(List<String> paths) onFiles, ValueChanged<bool> onHover) {
  return DropTarget(
    onDragEntered: (_) => onHover(true),
    onDragExited: (_) => onHover(false),
    onDragDone: (d) {
      onHover(false);
      final paths = [for (final f in d.files) f.path].where((p) => p.isNotEmpty).toList();
      if (paths.isNotEmpty) onFiles(paths);
    },
    child: child,
  );
}

/// The system file chooser, several files, any kind.
Future<List<String>> sensePickFiles() async {
  final r = await FilePicker.platform.pickFiles(allowMultiple: true);
  return [for (final f in r?.files ?? const <PlatformFile>[]) f.path].whereType<String>().toList();
}

class SenseSessionChat extends StatefulWidget {
  const SenseSessionChat({
    super.key,
    required this.ffi,
    required this.computerName,
    this.popups,
    this.iconPlacement,
  });

  final FFI ffi;

  /// Where the icon is, for the right popups (C1).
  final ValueNotifier<SenseChatIconPlacement?>? iconPlacement;
  final String computerName;
  final SensePopupController? popups;

  @override
  State<SenseSessionChat> createState() => _SenseSessionChatState();
}

class _SenseSessionChatState extends State<SenseSessionChat> with WindowListener {
  late SenseChatController _chat;
  final ValueNotifier<bool> _focused = ValueNotifier(true);

  @override
  void initState() {
    super.initState();
    _chat = senseSessionChatController(widget.ffi);
    widget.ffi.chatModel.attachSenseChat(_chat);
    _chat.startPolling();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    widget.ffi.chatModel.detachSenseChat(_chat);
    // S12: the chat lives only as long as the connection window.
    _chat.clear();
    _chat.dispose();
    _focused.dispose();
    super.dispose();
  }

  @override
  void onWindowFocus() => _focused.value = true;

  @override
  void onWindowBlur() => _focused.value = false;

  @override
  Widget build(BuildContext context) {
    return SenseChatLayer(
      controller: _chat,
      computerName: widget.computerName,
      popups: widget.popups,
      windowFocused: _focused,
      onBringToFront: () => windowOnTop(stateGlobal.windowId),
      pickFiles: sensePickFiles,
      dropBuilder: senseDesktopDrop,
      iconPlacement: widget.iconPlacement,
    );
  }
}

