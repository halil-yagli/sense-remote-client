// Sense Remote (Sürüm 12, #160, #161, #163): the built-in shortcut catalogue as the
// Controller shows it (prototype `FAVCAT`, `FAVG`, `FAVORD`). The core keeps the same ids
// with the fixed command of each (`src/sense/shortcuts/catalog.rs`, FAV-Ç); this file only
// keeps what the list draws: the group, the icon, and whether the row asks first or opens a
// small pane under it. The Turkish names are in `strings/favorites.dart`.
//
// Ids: `<os>.<name>` (`win.taskmgr`, `mac.actmon`); approved custom shortcuts are
// `custom:<uuid>` and come from the panel. Nothing here carries a command or an argument.
import 'package:flutter/material.dart';

import '../../../../strings/favorites.dart';

/// The computer the list is for (#163: a separate list per operating system).
enum SenseFavOs {
  win,
  mac,
  linux;

  /// Code the panel and the core use (`os` of `fav.items`, `main_sense_*`).
  String get code => name;

  /// "Windows", "macOS", "Linux".
  String get label => switch (this) {
        SenseFavOs.win => 'Windows',
        SenseFavOs.mac => 'macOS',
        SenseFavOs.linux => 'Linux',
      };

  String get headerLabel => switch (this) {
        SenseFavOs.win => SenseFavoritesStrings.osWin,
        SenseFavOs.mac => SenseFavoritesStrings.osMac,
        SenseFavOs.linux => SenseFavoritesStrings.osLinux,
      };

  static SenseFavOs? fromCode(Object? code) => switch (code) {
        'win' => SenseFavOs.win,
        'mac' => SenseFavOs.mac,
        'linux' => SenseFavOs.linux,
        _ => null,
      };

  /// The peer's platform string as RustDesk sends it (`pi.platform`): "Windows",
  /// "Mac OS", "Linux"; null for anything else (Android, unknown).
  static SenseFavOs? fromPlatform(String? platform) {
    final p = (platform ?? '').toLowerCase();
    if (p.startsWith('win')) return SenseFavOs.win;
    if (p.startsWith('mac') || p.contains('darwin')) return SenseFavOs.mac;
    if (p.startsWith('linux')) return SenseFavOs.linux;
    return null;
  }
}

/// Catalogue groups (`FAVG`).
enum SenseFavGroup {
  files,
  network,
  admin,
  settings,
  command,
  actions,
  health,
  screen,
  mac,
  custom;

  String get title => switch (this) {
        SenseFavGroup.files => SenseFavoritesStrings.gFiles,
        SenseFavGroup.network => SenseFavoritesStrings.gNetwork,
        SenseFavGroup.admin => SenseFavoritesStrings.gAdmin,
        SenseFavGroup.settings => SenseFavoritesStrings.gSettings,
        SenseFavGroup.command => SenseFavoritesStrings.gCommand,
        SenseFavGroup.actions => SenseFavoritesStrings.gActions,
        SenseFavGroup.health => SenseFavoritesStrings.gHealth,
        SenseFavGroup.screen => SenseFavoritesStrings.gScreen,
        SenseFavGroup.mac => SenseFavoritesStrings.gMac,
        SenseFavGroup.custom => SenseFavoritesStrings.gCustom,
      };
}

/// Order of the groups in the list (`FAVORD`): system actions first, custom last.
const List<SenseFavGroup> kSenseFavGroupOrder = [
  SenseFavGroup.actions,
  SenseFavGroup.files,
  SenseFavGroup.network,
  SenseFavGroup.health,
  SenseFavGroup.admin,
  SenseFavGroup.settings,
  SenseFavGroup.screen,
  SenseFavGroup.command,
  SenseFavGroup.mac,
  SenseFavGroup.custom,
];

/// What opens under a row instead of running it at once.
enum SenseFavPane { none, ip, ping, windows }

/// Keys the Controller itself sends for a `keys` entry (plan §2.3 `kind: keys`).
enum SenseFavKeys { ctrlAltDel, lockScreen, winD }

/// The in-place second step of a row that cannot be undone (T7).
@immutable
class SenseFavAsk {
  const SenseFavAsk({required this.question, required this.detail, required this.ok, this.danger = false});
  final String question;
  final String detail;
  final String ok;

  /// Red action button (`.btn.end`); otherwise the white primary one (`.btn.pri`).
  final bool danger;
}

@immutable
class SenseFavDef {
  const SenseFavDef(this.id, this.os, this.group, this.icon,
      {this.pane = SenseFavPane.none, this.ask, this.keys});

  final String id;
  final SenseFavOs os;
  final SenseFavGroup group;
  final IconData icon;
  final SenseFavPane pane;
  final SenseFavAsk? ask;

  /// Set when the Controller can send this one as keys (used when the core's catalogue
  /// says `kind: keys`).
  final SenseFavKeys? keys;

  String get name => SenseFavoritesStrings.names[id]?.$1 ?? id;
  String get description => SenseFavoritesStrings.names[id]?.$2 ?? '';
}

const _askResetNic = SenseFavAsk(
  question: SenseFavoritesStrings.askResetNic,
  detail: SenseFavoritesStrings.askResetNicDetail,
  ok: SenseFavoritesStrings.askResetNicOk,
);
const _askLogoff = SenseFavAsk(
  question: SenseFavoritesStrings.askLogoff,
  detail: SenseFavoritesStrings.askLogoffDetail,
  ok: SenseFavoritesStrings.askLogoffOk,
  danger: true,
);

const _w = SenseFavOs.win;
const _m = SenseFavOs.mac;
const _files = SenseFavGroup.files;
const _net = SenseFavGroup.network;
const _adm = SenseFavGroup.admin;
const _set = SenseFavGroup.settings;
const _cmd = SenseFavGroup.command;
const _act = SenseFavGroup.actions;
const _hlt = SenseFavGroup.health;
const _scr = SenseFavGroup.screen;
const _mac = SenseFavGroup.mac;

/// The whole built-in catalogue, in the prototype's order. Linux has none yet (#163).
const List<SenseFavDef> kSenseFavCatalog = [
  // Windows
  SenseFavDef('win.thispc', _w, _files, Icons.computer_outlined),
  SenseFavDef('win.explorer', _w, _files, Icons.folder_outlined),
  SenseFavDef('win.taskmgr', _w, _files, Icons.bar_chart_rounded),
  SenseFavDef('win.sysprop', _w, _files, Icons.settings_outlined),
  SenseFavDef('win.programs', _w, _files, Icons.apps_rounded),
  SenseFavDef('win.netadapt', _w, _net, Icons.swap_horiz_rounded),
  SenseFavDef('win.netset', _w, _net, Icons.wifi_rounded),
  SenseFavDef('win.ipinfo', _w, _net, Icons.info_outline_rounded, pane: SenseFavPane.ip),
  SenseFavDef('win.flushdns', _w, _net, Icons.backspace_outlined),
  SenseFavDef('win.resetnic', _w, _net, Icons.refresh_rounded, ask: _askResetNic),
  SenseFavDef('win.ping', _w, _net, Icons.track_changes_rounded, pane: SenseFavPane.ping),
  SenseFavDef('win.firewall', _w, _net, Icons.shield_outlined),
  SenseFavDef('win.shares', _w, _net, Icons.folder_shared_outlined),
  SenseFavDef('win.printers', _w, _net, Icons.print_outlined),
  SenseFavDef('win.services', _w, _adm, Icons.settings_outlined),
  SenseFavDef('win.devmgr', _w, _adm, Icons.memory_rounded),
  SenseFavDef('win.diskmgmt', _w, _adm, Icons.pie_chart_outline_rounded),
  SenseFavDef('win.eventvwr', _w, _adm, Icons.list_alt_rounded),
  SenseFavDef('win.tasksch', _w, _adm, Icons.schedule_rounded),
  SenseFavDef('win.regedit', _w, _adm, Icons.account_tree_outlined),
  SenseFavDef('win.ctrlpanel', _w, _set, Icons.tune_rounded),
  SenseFavDef('win.winset', _w, _set, Icons.settings_outlined),
  SenseFavDef('win.dispset', _w, _set, Icons.desktop_windows_outlined),
  SenseFavDef('win.sndset', _w, _set, Icons.volume_up_outlined),
  SenseFavDef('win.cmd', _w, _cmd, Icons.terminal_rounded),
  SenseFavDef('win.ps', _w, _cmd, Icons.code_rounded),
  SenseFavDef('win.showdesk', _w, _act, Icons.desktop_windows_outlined),
  SenseFavDef('win.cad', _w, _act, Icons.keyboard_outlined, keys: SenseFavKeys.ctrlAltDel),
  SenseFavDef('win.restexp', _w, _act, Icons.refresh_rounded),
  SenseFavDef('win.killhung', _w, _act, Icons.close_rounded, pane: SenseFavPane.windows),
  SenseFavDef('win.lock', _w, _act, Icons.lock_outline_rounded, keys: SenseFavKeys.lockScreen),
  SenseFavDef('win.logoff', _w, _act, Icons.logout_rounded, ask: _askLogoff),
  SenseFavDef('win.clip', _w, _act, Icons.backspace_outlined),
  SenseFavDef('win.minall', _w, _act, Icons.minimize_rounded, keys: SenseFavKeys.winD),
  SenseFavDef('win.winupd', _w, _hlt, Icons.system_update_alt_rounded),
  SenseFavDef('win.power', _w, _hlt, Icons.power_settings_new_rounded),
  SenseFavDef('win.startup', _w, _hlt, Icons.play_arrow_rounded),
  SenseFavDef('win.temp', _w, _hlt, Icons.folder_outlined),
  SenseFavDef('win.resmon', _w, _hlt, Icons.bar_chart_rounded),
  SenseFavDef('win.perfmon', _w, _hlt, Icons.show_chart_rounded),
  SenseFavDef('win.datetime', _w, _hlt, Icons.schedule_rounded),
  SenseFavDef('win.gpu', _w, _scr, Icons.developer_board_rounded),
  SenseFavDef('win.mixer', _w, _scr, Icons.graphic_eq_rounded),
  SenseFavDef('win.defout', _w, _scr, Icons.speaker_outlined),
  SenseFavDef('win.night', _w, _scr, Icons.dark_mode_outlined),
  // macOS
  SenseFavDef('mac.finder', _m, _files, Icons.folder_outlined),
  SenseFavDef('mac.actmon', _m, _files, Icons.bar_chart_rounded),
  SenseFavDef('mac.net', _m, _net, Icons.wifi_rounded),
  SenseFavDef('mac.diskutil', _m, _adm, Icons.pie_chart_outline_rounded),
  SenseFavDef('mac.console', _m, _adm, Icons.list_alt_rounded),
  SenseFavDef('mac.sysset', _m, _set, Icons.settings_outlined),
  SenseFavDef('mac.mdisp', _m, _set, Icons.desktop_windows_outlined),
  SenseFavDef('mac.msnd', _m, _set, Icons.volume_up_outlined),
  SenseFavDef('mac.term', _m, _cmd, Icons.terminal_rounded),
  SenseFavDef('mac.forcequit', _m, _mac, Icons.close_rounded, pane: SenseFavPane.windows),
  SenseFavDef('mac.privacy', _m, _mac, Icons.privacy_tip_outlined),
  SenseFavDef('mac.energy', _m, _mac, Icons.power_settings_new_rounded),
  SenseFavDef('mac.downloads', _m, _mac, Icons.download_rounded),
  SenseFavDef('mac.maclock', _m, _mac, Icons.lock_outline_rounded, keys: SenseFavKeys.lockScreen),
];

final Map<String, SenseFavDef> _byId = {for (final d in kSenseFavCatalog) d.id: d};

/// The built-in entry [id], or null (custom or unknown).
SenseFavDef? senseFavDef(String id) => _byId[id];

/// The built-in entries of [os], in catalogue order.
List<SenseFavDef> senseFavCatalogOf(SenseFavOs os) => [for (final d in kSenseFavCatalog) if (d.os == os) d];

/// Prefix of an approved custom shortcut id.
const String kSenseFavCustomPrefix = 'custom:';

/// One entry of the core's catalogue (`main_sense_shortcut_catalog(os)` →
/// `[{id, cat, kind, admin, available}]`).
@immutable
class SenseFavCoreEntry {
  const SenseFavCoreEntry({required this.id, this.kind = 'exec', this.admin = false, this.available = true});
  final String id;

  /// `exec` = the Host runs it; `keys` = the Controller sends keys.
  final String kind;
  final bool admin;
  final bool available;
}

/// Reads the core's catalogue answer. Anything that is not a list (an error object, an
/// empty string) gives an empty map: the core has no catalogue yet.
Map<String, SenseFavCoreEntry> senseFavParseCoreCatalog(Object? decoded) {
  final out = <String, SenseFavCoreEntry>{};
  if (decoded is! List) return out;
  for (final e in decoded) {
    if (e is! Map) continue;
    final id = e['id'];
    if (id is! String || id.isEmpty || id.length > 64) continue;
    out[id] = SenseFavCoreEntry(
      id: id,
      kind: e['kind'] == 'keys' ? 'keys' : 'exec',
      admin: e['admin'] == true,
      available: e['available'] != false,
    );
  }
  return out;
}

/// Ids of the core's catalogue that have no Turkish name here (the catalogue-equality
/// test keeps this empty).
List<String> senseFavMissingNames(Iterable<String> coreIds) =>
    [for (final id in coreIds) if (!id.startsWith(kSenseFavCustomPrefix) && !_byId.containsKey(id)) id];
