// Sense Remote: the setting keys shared by the Controller settings (C3) and the session
// menus (O3–O6), and whether a key is managed by the panel (TK9 §4; plan §2.6).
// One list, so the settings page and the session menu never disagree on a key or a lock.
import '../../models/platform_model.dart';

/// Where the value is stored (how RustDesk reads it).
enum SenseOptionStore {
  /// `bind.mainGetOption` / `mainSetOption` (service side).
  main,

  /// `bind.mainGetLocalOption` / `mainSetLocalOption` (this user only).
  local,

  /// `bind.mainGetUserDefaultOption` (defaults of new connections).
  userDefault,

  /// Sense bridge (`main_sense_*`).
  sense,

  /// No RustDesk option behind it (S5).
  none,
}

/// Why a key can be locked (TK9 §4 sources a–e).
enum SenseOptionLock {
  /// The user changes it.
  open,

  /// (a) `OVERWRITE_SETTINGS` (`src/sense.rs`): never changeable.
  overwrite,

  /// (b) `HARD_SETTINGS` role keys.
  hard,

  /// (c) Panel envelope `ALLOWED_OPTIONS`: written by the signed panel envelope.
  panel,

  /// Sense's own flow (permanent password).
  sense,

  /// Decision 5 (2026-11-23): locked for real; D3e adds them to `OVERWRITE_SETTINGS`.
  decision,
}

/// C3 settings category of a key (the page order follows this).
enum SenseOptionGroup { connections, newConnections, incoming, security, performance, network, update }

class SenseOptionKey {
  const SenseOptionKey(this.key, {required this.group, required this.store, this.lock = SenseOptionLock.open});

  final String key;
  final SenseOptionGroup group;
  final SenseOptionStore store;
  final SenseOptionLock lock;

  /// Locked by design (not only by the running computer's state).
  bool get lockedByDesign => lock != SenseOptionLock.open;
}

/// Every key of the TK9 §4 table. Stores follow `desktop_setting_page.dart`.
abstract final class SenseOptionKeys {
  // Bağlantılar
  static const openInTabs = SenseOptionKey('enable-open-new-connections-in-tabs',
      group: SenseOptionGroup.connections, store: SenseOptionStore.local);
  static const confirmClosingTabs = SenseOptionKey('enable-confirm-closing-tabs',
      group: SenseOptionGroup.connections, store: SenseOptionStore.local);
  static const keepAwakeOutgoing = SenseOptionKey('keep-awake-during-outgoing-sessions',
      group: SenseOptionGroup.connections, store: SenseOptionStore.local);
  static const syncClipboard = SenseOptionKey('allow-sync-clipboard-between-sessions',
      group: SenseOptionGroup.connections, store: SenseOptionStore.local);

  /// Keyboard shortcuts and pass-through (`ShortcutModel.setEnabled / setPassThrough`).
  static const keyboardShortcuts = SenseOptionKey('keyboard-shortcuts',
      group: SenseOptionGroup.connections, store: SenseOptionStore.local);

  // Yeni bağlantılar (defaults; the session menus O3–O6 change the same keys per session)
  static const viewStyle = SenseOptionKey('view_style',
      group: SenseOptionGroup.newConnections, store: SenseOptionStore.userDefault);
  static const imageQuality = SenseOptionKey('image_quality',
      group: SenseOptionGroup.newConnections, store: SenseOptionStore.userDefault);
  static const viewOnly = SenseOptionKey('view_only',
      group: SenseOptionGroup.newConnections, store: SenseOptionStore.userDefault);
  static const privacyMode = SenseOptionKey('privacy_mode',
      group: SenseOptionGroup.newConnections, store: SenseOptionStore.userDefault);

  // Gelen dosyalar ve kayıt
  static const incomingFilesDir = SenseOptionKey('sense:incoming-dir', // Sense bridge (D3d1), not a config key
      group: SenseOptionGroup.incoming, store: SenseOptionStore.sense);
  static const autoRecordOutgoing = SenseOptionKey('allow-auto-record-outgoing',
      group: SenseOptionGroup.incoming, store: SenseOptionStore.local);
  static const videoSaveDirectory = SenseOptionKey('video-save-directory',
      group: SenseOptionGroup.incoming, store: SenseOptionStore.main);

  // Güvenlik
  static const permanentPassword = SenseOptionKey('sense:permanent-password', // Sense bridge, not a config key
      group: SenseOptionGroup.security, store: SenseOptionStore.sense, lock: SenseOptionLock.sense);
  static const connType = SenseOptionKey('conn-type',
      group: SenseOptionGroup.security, store: SenseOptionStore.main, lock: SenseOptionLock.hard);
  static const autoDisconnect = SenseOptionKey('allow-auto-disconnect',
      group: SenseOptionGroup.security, store: SenseOptionStore.main, lock: SenseOptionLock.panel);
  static const autoDisconnectTimeout = SenseOptionKey('auto-disconnect-timeout',
      group: SenseOptionGroup.security, store: SenseOptionStore.main, lock: SenseOptionLock.panel);
  static const lanDiscovery = SenseOptionKey('enable-lan-discovery',
      group: SenseOptionGroup.security, store: SenseOptionStore.main, lock: SenseOptionLock.decision);
  static const directServer = SenseOptionKey('direct-server',
      group: SenseOptionGroup.security, store: SenseOptionStore.main, lock: SenseOptionLock.decision);
  static const directAccessPort = SenseOptionKey('direct-access-port',
      group: SenseOptionGroup.security, store: SenseOptionStore.main, lock: SenseOptionLock.decision);
  static const proxyUrl = SenseOptionKey('proxy-url',
      group: SenseOptionGroup.security, store: SenseOptionStore.main, lock: SenseOptionLock.decision);

  // Performans
  static const hwcodec = SenseOptionKey('enable-hwcodec',
      group: SenseOptionGroup.performance, store: SenseOptionStore.main);
  static const directxCapture = SenseOptionKey('enable-directx-capture',
      group: SenseOptionGroup.performance, store: SenseOptionStore.main);
  static const removeWallpaper = SenseOptionKey('allow-remove-wallpaper',
      group: SenseOptionGroup.performance, store: SenseOptionStore.main, lock: SenseOptionLock.panel);
  static const codecPreference = SenseOptionKey('codec-preference',
      group: SenseOptionGroup.performance, store: SenseOptionStore.userDefault);

  // Ağ ve sunucu
  static const rendezvousServer = SenseOptionKey('custom-rendezvous-server',
      group: SenseOptionGroup.network, store: SenseOptionStore.main, lock: SenseOptionLock.overwrite);
  static const apiServer = SenseOptionKey('api-server',
      group: SenseOptionGroup.network, store: SenseOptionStore.main, lock: SenseOptionLock.overwrite);
  static const relayServer = SenseOptionKey('relay-server',
      group: SenseOptionGroup.network, store: SenseOptionStore.main, lock: SenseOptionLock.overwrite);
  static const serverKey = SenseOptionKey('key',
      group: SenseOptionGroup.network, store: SenseOptionStore.main, lock: SenseOptionLock.overwrite);

  // Güncelleme
  static const autoUpdate = SenseOptionKey('allow-auto-update',
      group: SenseOptionGroup.update, store: SenseOptionStore.main, lock: SenseOptionLock.overwrite);
  static const checkUpdate = SenseOptionKey('enable-check-update',
      group: SenseOptionGroup.update, store: SenseOptionStore.local, lock: SenseOptionLock.overwrite);

  static const List<SenseOptionKey> all = [
    openInTabs, confirmClosingTabs, keepAwakeOutgoing, syncClipboard, keyboardShortcuts,
    viewStyle, imageQuality, viewOnly, privacyMode,
    incomingFilesDir, autoRecordOutgoing, videoSaveDirectory,
    permanentPassword, connType, autoDisconnect, autoDisconnectTimeout,
    lanDiscovery, directServer, directAccessPort, proxyUrl,
    hwcodec, directxCapture, removeWallpaper, codecPreference,
    rendezvousServer, apiServer, relayServer, serverKey,
    autoUpdate, checkUpdate,
  ];

  /// Keys that are locked whatever the computer says (sources a, b, c, decision 5).
  static Set<String> get lockedByDesign => {
        for (final k in all)
          if (k.lockedByDesign && k.store != SenseOptionStore.sense) k.key,
      };

  static SenseOptionKey? byKey(String key) {
    for (final k in all) {
      if (k.key == key) return k;
    }
    return null;
  }
}

typedef SenseOptionLockedFn = bool Function(String key);

/// Asks the computer whether [key] is managed by the panel. Tests replace it.
///
/// Until D3e lands `main_sense_option_locked` (plan §2.6), the answer is
/// RustDesk's `isOptionFixed` (OVERWRITE_SETTINGS) or the design list above.
/// D3e: replace the body of [_bridgeLocked] with `bind.mainSenseOptionLocked(key: key)`.
SenseOptionLockedFn senseOptionLockedImpl = _bridgeLocked;

bool _bridgeLocked(String key) {
  try {
    if (bind.mainIsOptionFixed(key: key)) return true;
  } catch (_) {
    // Native side not ready (tests, early start): fall back to the design list.
  }
  return SenseOptionKeys.lockedByDesign.contains(key);
}

/// "Panelden yönetilir": the row is faded and cannot be changed (C3, O3–O6).
bool senseOptionLocked(String key) => senseOptionLockedImpl(key);
