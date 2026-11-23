// Sense Remote: voice call and sound devices of the chat (YH O11, voice only:
// #67, no camera). RustDesk already has a two-way voice call; this wraps it.
// The Host card (C5) gives its own [SenseChatCall] (cm_* functions, D3d2 for
// "Host'tan Ara").

import 'dart:convert';

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

/// Sound outputs from `main_sense_sound_outputs` (`{outputs: [..], output}`).
/// Broken input gives "system default only", never an exception.
({List<String> outputs, String output}) senseParseSoundOutputs(String raw) {
  try {
    final data = jsonDecode(raw);
    if (data is Map) {
      final list = data['outputs'];
      final outputs = list is List ? [for (final o in list) if (o is String) o] : <String>[];
      final output = data['output'] is String ? data['output'] as String : '';
      return (outputs: outputs, output: outputs.contains(output) ? output : '');
    }
  } catch (_) {}
  return (outputs: const <String>[], output: '');
}

/// `session_sense_call_level`: 0..1, below 0 = unknown (no call / not measured).
double? senseCallLevel(double raw) => raw < 0 ? null : raw.clamp(0.0, 1.0).toDouble();

/// Controller side of one connection: RustDesk's voice call
/// (`session_request_voice_call`, `session_close_voice_call`) and its voice
/// call input device (`flutter_ffi.rs` set/get_voice_call_input_device). A
/// call the Host starts (D3d2) is answered with [start] and refused with [end].
/// Microphone off, level and sound output: `session_sense_call_*`,
/// `main_sense_*` (D3d2, plan Ek).
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
    final out = senseParseSoundOutputs(await bind.mainSenseSoundOutputs());
    return SenseAudioDevices(
        inputs: inputs, input: input, outputs: out.outputs, output: out.output);
  }

  @override
  Future<void> setInput(String device) =>
      bind.setVoiceCallInputDevice(isCm: false, device: device);

  @override
  Future<void> setOutput(String device) =>
      bind.mainSenseSetCallOutput(device: device);

  @override
  Future<bool> setMuted(bool muted) =>
      bind.sessionSenseCallSetMuted(sessionId: sessionId, muted: muted);

  @override
  Future<double?> level() async =>
      senseCallLevel(await bind.sessionSenseCallLevel(sessionId: sessionId));
}
