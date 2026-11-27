// Sense Remote: voice call of the Host card (YH H4, O11 voice only: #67).
// Answering and ending use RustDesk's CM functions (`cm_handle_incoming_voice_call`,
// `cm_close_voice_call`); the microphone list is the CM side's
// (`get/set_voice_call_input_device(is_cm: true)`). "Ara" on the Host is
// `main_sense_host_start_call(conn_id)` (plan §2.6, D3d2); the Controller
// answers it. Microphone off, level and sound output (plan Ek, #65) act on the
// Host's call, which the server process captures and plays: the core passes
// them on to the connection.

import '../../../../common.dart' show SessionID;
import '../../../../models/platform_model.dart';
import '../../shared/chat/data/call.dart';

/// The Host card has no session; the call functions that take one ignore it
/// on the Host side (`session_sense_call_*`).
final _noSession = SessionID('00000000-0000-0000-0000-000000000000');

class SenseHostChatCall implements SenseChatCall {
  SenseHostChatCall({required this.connId});

  /// The CM connection id (Client.id).
  final int connId;

  /// "Ara" works on the Host (D3d2).
  static const bool canStart = true;

  /// O8: "Mikrofonu kapat" per connection, as the core was told. The core has
  /// no reader for it (`chat_file.rs` MUTED), and the Mikrofon list reads the
  /// devices again each time it opens: without this it showed the microphone
  /// as on while the core still sent silence. Forgotten when the call ends
  /// (the core opens the microphone again then: `set_call_mic(false)`).
  static final Set<int> _muted = {};

  /// Whether "Mikrofonu kapat" is on for [connId] (O8).
  static bool mutedFor(int connId) => _muted.contains(connId);

  /// The core took "Mikrofonu kapat" / an open microphone for [connId].
  static void noteMuted(int connId, bool muted) {
    if (muted) {
      _muted.add(connId);
    } else {
      _muted.remove(connId);
    }
  }

  /// The call of [connId] is over (ended here, by the Controller, or the
  /// connection is gone): the next call starts with the microphone on.
  static void callEnded(int connId) => _muted.remove(connId);

  @override
  Future<void> start() => bind.mainSenseHostStartCall(connId: connId);

  /// "Kabul et" / "Reddet" of an incoming call.
  Future<void> answer(bool accept) {
    callEnded(connId);
    return bind.cmHandleIncomingVoiceCall(id: connId, accept: accept);
  }

  @override
  Future<void> end() {
    callEnded(connId);
    return bind.cmCloseVoiceCall(id: connId);
  }

  @override
  Future<SenseAudioDevices> devices() async {
    final inputs = (await bind.mainGetSoundInputs()).toList();
    final input = await bind.getVoiceCallInputDevice(isCm: true);
    final out = senseParseSoundOutputs(await bind.mainSenseSoundOutputs());
    return SenseAudioDevices(
        inputs: inputs,
        input: input,
        outputs: out.outputs,
        output: out.output,
        muted: mutedFor(connId));
  }

  @override
  Future<void> setInput(String device) =>
      bind.setVoiceCallInputDevice(isCm: true, device: device);

  @override
  Future<void> setOutput(String device) =>
      bind.mainSenseSetCallOutput(device: device);

  @override
  Future<bool> setMuted(bool muted) async {
    final ok = await bind.sessionSenseCallSetMuted(sessionId: _noSession, muted: muted);
    if (ok) noteMuted(connId, muted);
    return ok;
  }

  @override
  Future<double?> level() async =>
      senseCallLevel(await bind.sessionSenseCallLevel(sessionId: _noSession));
}
