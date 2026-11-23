// Sense Remote: voice call and sound devices of the chat (YH O11, voice only:
// #67, no camera). RustDesk already has a two-way voice call; this wraps it.
// The Host card (C5) gives its own [SenseChatCall] (cm_* functions, D3d2 for
// "Host'tan Ara").

import '../../../../../common.dart' show SessionID;
import '../../../../../models/platform_model.dart';

/// Devices the Mikrofon list shows.
class SenseAudioDevices {
  const SenseAudioDevices({
    this.inputs = const [],
    this.input = '',
    this.outputs = const [],
    this.output = '',
    this.muted = false,
  });

  /// Microphones connected to this computer (names as the system gives them).
  final List<String> inputs;

  /// Chosen microphone; '' = the system default.
  final String input;

  /// Sound outputs; empty = only the system default can be used.
  final List<String> outputs;
  final String output;
  final bool muted;

  SenseAudioDevices copyWith({String? input, String? output, bool? muted}) => SenseAudioDevices(
        inputs: inputs,
        input: input ?? this.input,
        outputs: outputs,
        output: output ?? this.output,
        muted: muted ?? this.muted,
      );
}

/// What the chat needs from the call side.
abstract class SenseChatCall {
  /// "Ara": asks the other side; the answer comes as a call phase.
  Future<void> start();

  /// "Aramayı bitir" (also cancels a call that is still ringing).
  Future<void> end();

  Future<SenseAudioDevices> devices();
  Future<void> setInput(String device);
  Future<void> setOutput(String device);

  /// Turns the microphone off / on. False when it could not be done.
  Future<bool> setMuted(bool muted);

  /// Microphone level 0..1 for the green bar; null when it cannot be read.
  Future<double?> level();
}

/// Controller side of one connection: RustDesk's voice call
/// (`session_request_voice_call`, `session_close_voice_call`) and its voice
/// call input device (`flutter_ffi.rs` set/get_voice_call_input_device).
class SenseSessionChatCall implements SenseChatCall {
  SenseSessionChatCall({required this.sessionId});

  /// FFI.sessionId.
  final SessionID sessionId;

  @override
  Future<void> start() => bind.sessionRequestVoiceCall(sessionId: sessionId);

  @override
  Future<void> end() => bind.sessionCloseVoiceCall(sessionId: sessionId);

  @override
  Future<SenseAudioDevices> devices() async {
    final inputs = (await bind.mainGetSoundInputs()).toList();
    final input = await bind.getVoiceCallInputDevice(isCm: false);
    // TODO(D3d2): sound output list and choice — RustDesk plays the call on the
    // system default output and has no bridge function for it.
    return SenseAudioDevices(inputs: inputs, input: input);
  }

  @override
  Future<void> setInput(String device) =>
      bind.setVoiceCallInputDevice(isCm: false, device: device);

  @override
  Future<void> setOutput(String device) async {
    // TODO(D3d2): output device of the voice call (no bridge function yet).
  }

  @override
  Future<bool> setMuted(bool muted) async {
    // TODO(D3d2): microphone off during a call — RustDesk has no "mute" for the
    // voice call; choosing an unknown device falls back to the default one, so
    // it cannot be faked safely. Report "not done" until the bridge has it.
    return false;
  }

  @override
  Future<double?> level() async {
    // TODO(D3d2): microphone level of the voice call (no bridge function yet).
    return null;
  }
}
