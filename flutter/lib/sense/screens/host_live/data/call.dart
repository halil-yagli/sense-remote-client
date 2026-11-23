// Sense Remote: voice call of the Host card (YH H4, O11 voice only: #67).
// Answering and ending use RustDesk's CM functions (`cm_handle_incoming_voice_call`,
// `cm_close_voice_call`); the microphone list is the CM side's
// (`get/set_voice_call_input_device(is_cm: true)`). Starting a call from the
// Host waits for `main_sense_host_start_call(conn_id)` (plan §2.6, D3d2).

import '../../../../models/platform_model.dart';
import '../../shared/chat/data/call.dart';

class SenseHostChatCall implements SenseChatCall {
  SenseHostChatCall({required this.connId});

  /// The CM connection id (Client.id).
  final int connId;

  /// "Ara" works on the Host. False until D3d2: the button is drawn faded.
  static const bool canStart = false;

  @override
  Future<void> start() async {
    // TODO(D3d2): main_sense_host_start_call(conn_id) — RustDesk has no
    // Host-initiated call (TK2 connection.rs:4127). When it lands:
    //   await bind.mainSenseHostStartCall(connId: connId);
  }

  /// "Kabul et" / "Reddet" of an incoming call.
  Future<void> answer(bool accept) =>
      bind.cmHandleIncomingVoiceCall(id: connId, accept: accept);

  @override
  Future<void> end() => bind.cmCloseVoiceCall(id: connId);

  @override
  Future<SenseAudioDevices> devices() async {
    final inputs = (await bind.mainGetSoundInputs()).toList();
    final input = await bind.getVoiceCallInputDevice(isCm: true);
    // TODO(D3d2): sound output list and choice (no bridge function yet).
    return SenseAudioDevices(inputs: inputs, input: input);
  }

  @override
  Future<void> setInput(String device) =>
      bind.setVoiceCallInputDevice(isCm: true, device: device);

  @override
  Future<void> setOutput(String device) async {
    // TODO(D3d2): output device of the voice call (no bridge function yet).
  }

  @override
  Future<bool> setMuted(bool muted) async {
    // TODO(D3d2): microphone off during a call (plan Ek, #65).
    return false;
  }

  @override
  Future<double?> level() async {
    // TODO(D3d2): microphone level (plan Ek, #65).
    return null;
  }
}
