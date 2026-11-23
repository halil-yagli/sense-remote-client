// Sense Remote: where the Controller settings (YH C3) read and write. Every
// row is a real core option (TK9 §4; #2, #66): the bridge below calls the
// same functions the stock settings page used, with the same stores and the
// same yes/no encoding, so a switch here changes the setting the core reads.
// Tests replace the whole backend with a fake and check key, store and value.
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../../../../../common.dart' show option2bool, bool2option, defaultOptionNo;
import '../../../../../models/platform_model.dart';
import '../../../../../models/shortcut_model.dart';
import '../../../../data/option_keys.dart';
import '../../sense_home_strings.dart' show SenseHomeRole, senseHomeRoleFrom;
import 'incoming.dart';

abstract class SenseSettingsBackend {
  /// Raw value of [key] in [store].
  String read(String key, SenseOptionStore store);
  Future<void> write(String key, SenseOptionStore store, String value);

  /// Yes/no value, decoded like the core does (`option2bool`; new-connection
  /// defaults are "Y" = on).
  bool readBool(String key, SenseOptionStore store);
  Future<void> writeBool(String key, SenseOptionStore store, bool value);

  /// Keyboard shortcuts live in one JSON (`keyboard-shortcuts`); ShortcutModel
  /// owns it.
  bool shortcutsEnabled();
  Future<void> setShortcutsEnabled(bool value);
  bool shortcutsPassThrough();
  Future<void> setShortcutsPassThrough(bool value);

  /// Folder the recordings go to (the core's answer, default included).
  String recordDir();

  /// Chat files folder (D3d1 bridge, see incoming.dart).
  SenseIncomingDirSource get incoming;

  /// System folder picker; null when cancelled.
  Future<String?> pickDirectory(String initial);

  /// "Panelden yönetilir" (D3e bridge through option_keys.dart).
  bool locked(String key) => senseOptionLocked(key);

  SenseHomeRole role();

  /// Called after a value was written (e.g. probe the hardware codec).
  void afterWrite(String key, String value) {}
}

class SenseSettingsBridge extends SenseSettingsBackend {
  SenseSettingsBridge({SenseIncomingDirSource? incoming})
      : incoming = incoming ?? SenseIncomingDirBridge();

  @override
  final SenseIncomingDirSource incoming;

  @override
  String read(String key, SenseOptionStore store) {
    switch (store) {
      case SenseOptionStore.main:
        return bind.mainGetOptionSync(key: key);
      case SenseOptionStore.local:
        return bind.mainGetLocalOption(key: key);
      case SenseOptionStore.userDefault:
        return bind.mainGetUserDefaultOption(key: key);
      case SenseOptionStore.sense:
      case SenseOptionStore.none:
        return '';
    }
  }

  @override
  Future<void> write(String key, SenseOptionStore store, String value) async {
    switch (store) {
      case SenseOptionStore.main:
        await bind.mainSetOption(key: key, value: value);
        break;
      case SenseOptionStore.local:
        await bind.mainSetLocalOption(key: key, value: value);
        break;
      case SenseOptionStore.userDefault:
        await bind.mainSetUserDefaultOption(key: key, value: value);
        break;
      case SenseOptionStore.sense:
      case SenseOptionStore.none:
        return;
    }
    afterWrite(key, value);
  }

  @override
  bool readBool(String key, SenseOptionStore store) {
    final raw = read(key, store);
    // New-connection defaults ("Other Default Options"): only "Y" is on.
    if (store == SenseOptionStore.userDefault) return raw == 'Y';
    return option2bool(key, raw);
  }

  @override
  Future<void> writeBool(String key, SenseOptionStore store, bool value) {
    final raw = store == SenseOptionStore.userDefault
        ? (value ? 'Y' : defaultOptionNo as String)
        : bool2option(key, value);
    return write(key, store, raw);
  }

  @override
  bool shortcutsEnabled() => ShortcutModel.isEnabled();

  @override
  Future<void> setShortcutsEnabled(bool value) => ShortcutModel.setEnabled(value);

  @override
  bool shortcutsPassThrough() => ShortcutModel.isPassThrough();

  @override
  Future<void> setShortcutsPassThrough(bool value) => ShortcutModel.setPassThrough(value);

  @override
  String recordDir() => bind.mainVideoSaveDirectory(root: false);

  @override
  Future<String?> pickDirectory(String initial) async {
    String? start;
    try {
      if (initial.isNotEmpty && await Directory(initial).exists()) start = initial;
    } catch (_) {}
    return FilePicker.platform.getDirectoryPath(initialDirectory: start);
  }

  @override
  SenseHomeRole role() => senseHomeRoleFrom(
      incomingOnly: bind.isIncomingOnly(),
      outgoingOnly: bind.isOutgoingOnly(),
      settingsDisabled: bind.isDisableSettings());

  @override
  void afterWrite(String key, String value) {
    // Same as the stock page: turning the hardware codec on probes it.
    if (key == SenseOptionKeys.hwcodec.key && value != 'N') bind.mainCheckHwcodec();
  }
}
