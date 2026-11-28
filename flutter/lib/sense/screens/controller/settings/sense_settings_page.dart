// Sense Remote: Controller settings (YH C3; prototype `setView2`; images a03,
// s10, s11, s12). Only this computer's own preferences; a change applies at
// once and the row says "Kaydedildi". Every row is a real option (TK9 §4):
// [SenseSettingsBackend] writes it where the core reads it. Rows the panel
// manages are faded with "Panelden yönetilir" and cannot be changed
// (`senseOptionLocked`, D3e). No theme category (#38); session-menu choices are
// not repeated here (only the start of new connections, YH C3).
import 'package:flutter/material.dart';

import '../../../../consts.dart' show kRemoteViewStyleAdaptive, kRemoteViewStyleOriginal,
    kRemoteImageQualityBest, kRemoteImageQualityBalanced, kRemoteImageQualityLow, kOptionEnableRecordSession;
import '../../../data/option_keys.dart';
import '../../../diag_log.dart';
import '../../../sense.dart';
import '../../../strings/settings.dart';
import '../../../router.dart' show senseRoleChangeReopen;
import '../../host/data/role.dart' show SenseRoleBackend, SenseRoleBridge;
import '../../host/role/role_category.dart' show SenseRoleController, SenseRoleCategoryBody, senseRoleSummary;
import '../../host/password/password_about_row.dart' show SensePasswordAboutRow;
import '../sense_home_strings.dart' show SenseHomeRole, senseRoleLabel;
import 'data/settings_backend.dart';
import 'widgets.dart';

/// `.amain` padding (18 top, 22 sides, 24 bottom).
const EdgeInsets kSensePagePadding = EdgeInsets.fromLTRB(22, 18, 22, 24);

/// Category ids (also test keys `sense-acc-<id>`).
/// `where` of the interface records of this page (karar #103).
const String _where = 'controller.settings';

abstract final class SenseSettingsCategory {
  static const role = 'role';
  static const connections = 'connections';
  static const newConnections = 'new';
  static const incoming = 'incoming';
  static const security = 'security';
  static const performance = 'performance';
  static const network = 'network';
  static const update = 'update';
}

/// Pure: folder shown for the chat files ('' = Downloads).
String senseFolderLabel(String path) => path.trim().isEmpty ? SenseSettingsStrings.downloads : path;

/// Pure: short folder name for a category summary.
String senseFolderShort(String path) {
  if (path.trim().isEmpty) return SenseSettingsStrings.downloads;
  final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

/// Binds the page to the app.
class SenseSettingsPage extends StatelessWidget {
  const SenseSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => SenseSettingsView(backend: SenseSettingsBridge());
}

class SenseSettingsView extends StatefulWidget {
  const SenseSettingsView({
    super.key,
    required this.backend,
    this.initialOpen = SenseSettingsCategory.role,
    this.passwordSection,
    this.isWindowsHost,
    this.roleBackend = const SenseRoleBridge(),
  });

  /// "Bu bilgisayarın rolü" (B2's role component, H2 = C3).
  final SenseRoleBackend roleBackend;

  final SenseSettingsBackend backend;
  final String? initialOpen;

  /// Kalıcı şifre flow for a computer that is also a Host; null = the app's
  /// own (B2's password row).
  final Widget? passwordSection;

  /// DirectX capture is a Windows setting; null = this platform.
  final bool? isWindowsHost;

  @override
  State<SenseSettingsView> createState() => _SenseSettingsViewState();
}

class _SenseSettingsViewState extends State<SenseSettingsView> {
  final Map<String, int> _saved = {};
  String _incoming = '';
  final _scroll = ScrollController();
  bool _restarting = false;

  /// B9: a setting that could not be written; shown on top of the page until the next try.
  String? _failed;
  late final SenseRoleController _role = SenseRoleController(widget.roleBackend,
      onRestart: () {
    if (mounted) setState(() => _restarting = true);
    // Sense Remote (D3b): the app reopens with the new role.
    senseRoleChangeReopen();
  });

  SenseSettingsBackend get _b => widget.backend;

  @override
  void initState() {
    super.initState();
    _loadIncoming();
    _role.addListener(_onRole);
    _role.load().catchError((_) {});
  }

  void _onRole() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _role.removeListener(_onRole);
    _role.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadIncoming() async {
    String v = '';
    try {
      v = await _b.incoming.current();
    } catch (_) {}
    if (mounted) setState(() => _incoming = v);
  }

  void _mark(String id) => setState(() => _saved[id] = (_saved[id] ?? 0) + 1);

  int _t(String id) => _saved[id] ?? 0;

  bool _locked(String key) {
    try {
      return _b.locked(key);
    } catch (_) {
      return SenseOptionKeys.lockedByDesign.contains(key);
    }
  }

  /// B9: the record "changed" is written after the write worked; a failure is said on the
  /// page ("Kaydedilemedi") and the switch stays where it was.
  Future<void> _write(String id, Object before, Object after, Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _failed = id);
      return;
    }
    senseUiSetting(id, before, after, where: _where);
    if (mounted) setState(() => _failed = null);
    _mark(id);
  }

  Future<void> _setBool(SenseOptionKey k, bool v) async {
    if (_locked(k.key)) return;
    await _write(k.key, _bool(k), v, () => _b.writeBool(k.key, k.store, v));
  }

  Future<void> _setChoice(SenseOptionKey k, String v) async {
    if (_locked(k.key)) return;
    await _write(k.key, _raw(k), v, () => _b.write(k.key, k.store, v));
  }

  /// B7: "Hayalet modla başla" is on unless turned off (karar #95); off is written as "N"
  /// explicitly, because the empty default means on.
  bool _ghostStart() => _raw(SenseOptionKeys.privacyMode) != 'N';

  Future<void> _setGhostStart(bool v) async {
    final k = SenseOptionKeys.privacyMode;
    if (_locked(k.key)) return;
    await _write(k.key, _ghostStart(), v, () => _b.write(k.key, k.store, v ? 'Y' : 'N'));
  }

  Future<void> _changeIncoming() async {
    if (_locked(SenseOptionKeys.incomingFilesDir.key)) return;
    final picked = await _b.pickDirectory(_incoming);
    if (picked == null || picked.isEmpty) return;
    senseUiSetting(SenseOptionKeys.incomingFilesDir.key, '-', 'changed', where: _where); // the path is not written
    await _b.incoming.set(picked);
    await _loadIncoming();
    _mark(SenseOptionKeys.incomingFilesDir.key);
  }

  Future<void> _changeRecordDir() async {
    final k = SenseOptionKeys.videoSaveDirectory;
    if (_locked(k.key)) return;
    final picked = await _b.pickDirectory(_b.recordDir());
    if (picked == null || picked.isEmpty) return;
    // The stock page keeps this one in the local options (only this user).
    senseUiSetting(k.key, '-', 'changed', where: _where); // the path is not written
    await _b.write(k.key, SenseOptionStore.local, picked);
    _mark(k.key);
  }

  Future<void> _setShortcuts(bool v) async {
    if (_locked(SenseOptionKeys.keyboardShortcuts.key)) return;
    senseUiSetting('shortcuts', _b.shortcutsEnabled(), v, where: _where);
    await _b.setShortcutsEnabled(v);
    _mark('shortcuts');
  }

  Future<void> _setPassThrough(bool v) async {
    if (_locked(SenseOptionKeys.keyboardShortcuts.key)) return;
    senseUiSetting('pass-through', _b.shortcutsPassThrough(), v, where: _where);
    await _b.setShortcutsPassThrough(v);
    _mark('pass-through');
  }

  bool _bool(SenseOptionKey k) => _b.readBool(k.key, k.store);
  String _raw(SenseOptionKey k) => _b.read(k.key, k.store);

  @override
  Widget build(BuildContext context) {
    final role = _b.role();
    final host = role == SenseHomeRole.host || role == SenseHomeRole.both;
    final controller = role != SenseHomeRole.host;
    var mine = 0, lockedCount = 0;

    Widget toggle(SenseOptionKey k, String label,
        {String? hint, bool last = false, bool? value, Future<void> Function(bool)? set}) {
      final locked = _locked(k.key);
      locked ? lockedCount++ : mine++;
      return SenseToggleRow(
        key: Key('sense-set-${k.key}'),
        label: label,
        description: hint,
        value: value ?? _bool(k),
        locked: locked,
        savedTrigger: _t(k.key),
        last: last,
        onChanged: locked ? null : (v) => (set ?? (x) => _setBool(k, x))(v),
      );
    }

    Widget segment(SenseOptionKey k, String label, List<SenseSegmentOption<String>> options) {
      final locked = _locked(k.key);
      locked ? lockedCount++ : mine++;
      return SenseSettingRow(
        key: Key('sense-set-${k.key}'),
        label: label,
        locked: locked,
        savedTrigger: _t(k.key),
        control: SenseSegment<String>(
          options: options,
          value: _raw(k),
          locked: locked,
          // Prototype `.aseg`: own width on the right of the row.
          expand: false,
          semanticLabel: label,
          onChanged: locked ? null : (v) => _setChoice(k, v),
        ),
      );
    }

    Widget lockedRow(String label, String value, {String? hint, bool last = false, Key? key}) {
      lockedCount++;
      return SenseLockedValueRow(key: key, label: label, value: value, description: hint, last: last);
    }

    Widget dirRow(String id, String label, String hint, String value, VoidCallback onChange, {bool last = false}) {
      final locked = _locked(id);
      locked ? lockedCount++ : mine++;
      return SenseSettingRow(
        key: Key('sense-set-$id'),
        label: label,
        description: hint,
        locked: locked,
        savedTrigger: _t(id),
        last: last,
        control: Row(mainAxisSize: MainAxisSize.min, children: [
          SenseRowValue(value),
          const SizedBox(width: SenseUi.iconGap),
          SenseButton(
            key: Key('sense-set-$id-change'),
            label: SenseSettingsStrings.change,
            size: SenseButtonSize.small,
            onPressed: locked ? null : onChange,
          ),
        ]),
      );
    }

    // Bağlantılar (Controller).
    final shortcutsLocked = _locked(SenseOptionKeys.keyboardShortcuts.key);
    final shortcutsOn = _b.shortcutsEnabled();
    final connections = <Widget>[];
    if (controller) {
      connections.addAll([
        toggle(SenseOptionKeys.openInTabs, SenseSettingsStrings.openInTabs, hint: SenseSettingsStrings.openInTabsHint),
        toggle(SenseOptionKeys.confirmClosingTabs, SenseSettingsStrings.confirmClosingTabs),
        toggle(SenseOptionKeys.keepAwakeOutgoing, SenseSettingsStrings.keepAwake),
        toggle(SenseOptionKeys.syncClipboard, SenseSettingsStrings.syncClipboard),
        toggle(SenseOptionKeys.askNote, SenseSettingsStrings.askNote, hint: SenseSettingsStrings.askNoteHint),
      ]);
      shortcutsLocked ? lockedCount++ : mine++;
      connections.add(SenseToggleRow(
        key: const Key('sense-set-shortcuts'),
        label: SenseSettingsStrings.shortcuts,
        description: SenseSettingsStrings.shortcutsHint,
        value: shortcutsOn,
        locked: shortcutsLocked,
        savedTrigger: _t('shortcuts'),
        last: !shortcutsOn,
        onChanged: shortcutsLocked ? null : _setShortcuts,
      ));
      if (shortcutsOn) {
        shortcutsLocked ? lockedCount++ : mine++;
        connections.add(SenseToggleRow(
          key: const Key('sense-set-pass-through'),
          label: SenseSettingsStrings.passThrough,
          value: _b.shortcutsPassThrough(),
          locked: shortcutsLocked,
          savedTrigger: _t('pass-through'),
          last: true,
          onChanged: shortcutsLocked ? null : _setPassThrough,
        ));
      }
    }
    final connSummary = [
      _bool(SenseOptionKeys.openInTabs) ? SenseSettingsStrings.sumTabs : SenseSettingsStrings.sumWindows,
      if (_bool(SenseOptionKeys.keepAwakeOutgoing)) SenseSettingsStrings.sumAwake,
    ].join(' · ');

    // Yeni bağlantılar nasıl başlasın (Controller).
    final newConn = <Widget>[];
    if (controller) {
      newConn.addAll([
        segment(SenseOptionKeys.viewStyle, SenseSettingsStrings.viewStyle, const [
          SenseSegmentOption(value: kRemoteViewStyleAdaptive, label: SenseSettingsStrings.viewFit),
          SenseSegmentOption(value: kRemoteViewStyleOriginal, label: SenseSettingsStrings.viewOriginal),
        ]),
        segment(SenseOptionKeys.imageQuality, SenseSettingsStrings.quality, const [
          SenseSegmentOption(value: kRemoteImageQualityBest, label: SenseSettingsStrings.qualityBest),
          SenseSegmentOption(value: kRemoteImageQualityBalanced, label: SenseSettingsStrings.qualityBalanced),
          SenseSegmentOption(value: kRemoteImageQualityLow, label: SenseSettingsStrings.qualityFast),
        ]),
        toggle(SenseOptionKeys.viewOnly, SenseSettingsStrings.viewOnly),
        toggle(SenseOptionKeys.privacyMode, SenseSettingsStrings.privacy,
            hint: SenseSettingsStrings.privacyHint, last: true, value: _ghostStart(), set: _setGhostStart),
      ]);
    }
    final view = _raw(SenseOptionKeys.viewStyle);
    final quality = _raw(SenseOptionKeys.imageQuality);
    final newSummary = [
      if (view == kRemoteViewStyleAdaptive) SenseSettingsStrings.viewFit,
      if (view == kRemoteViewStyleOriginal) SenseSettingsStrings.viewOriginal,
      if (quality == kRemoteImageQualityBest) SenseSettingsStrings.qualityBest,
      if (quality == kRemoteImageQualityBalanced) SenseSettingsStrings.qualityBalanced,
      if (quality == kRemoteImageQualityLow) SenseSettingsStrings.qualityFast,
      if (_bool(SenseOptionKeys.viewOnly)) SenseSettingsStrings.sumViewOnly,
      if (_ghostStart()) SenseSettingsStrings.sumPrivacy,
    ].join(' · ');

    // Gelen dosyalar ve kayıt.
    final recordOn = _bool(SenseOptionKeys.autoRecordOutgoing);
    final incoming = <Widget>[
      dirRow(SenseOptionKeys.incomingFilesDir.key, SenseSettingsStrings.incomingDir,
          SenseSettingsStrings.incomingDirHint, senseFolderLabel(_incoming), _changeIncoming,
          last: !controller && !host),
      if (controller) ...[
        toggle(SenseOptionKeys.autoRecordOutgoing, SenseSettingsStrings.autoRecord),
        dirRow(SenseOptionKeys.videoSaveDirectory.key, SenseSettingsStrings.recordDir,
            SenseSettingsStrings.recordDirHint, _b.recordDir(), _changeRecordDir,
            last: !host),
      ],
      // FU-A5: whether the Controller may record connections to this Host is the panel's
      // `enable-record-session`; the value is read, not written here.
      if (host)
        lockedRow(SenseSettingsStrings.recordIncoming,
            _b.readBool(kOptionEnableRecordSession, SenseOptionStore.main)
                ? SenseSettingsStrings.on
                : SenseSettingsStrings.off,
            last: true, key: const Key('sense-set-enable-record-session')),
    ];
    final incomingSummary = [
      senseFolderShort(_incoming),
      if (controller) recordOn ? SenseSettingsStrings.sumRecordOn : SenseSettingsStrings.sumRecordOff,
    ].join(' · ');

    // Güvenlik.
    final connType = _b.read(SenseOptionKeys.connType.key, SenseOptionKeys.connType.store);
    final approve = _b.read(SenseOptionKeys.approveMode.key, SenseOptionKeys.approveMode.store);
    final idleOn = _bool(SenseOptionKeys.autoDisconnect);
    final idleMin = int.tryParse(_raw(SenseOptionKeys.autoDisconnectTimeout)) ?? 10;
    final directOn = _bool(SenseOptionKeys.directServer);
    final port = _raw(SenseOptionKeys.directAccessPort).trim();
    final security = <Widget>[
      if (host)
        widget.passwordSection ?? const SensePasswordAboutRow()
      else
        const SenseSettingRow(
            key: Key('sense-set-password'),
            label: SenseSettingsStrings.password,
            description: SenseSettingsStrings.passwordController),
      // FU-B2 (#166): these four are the Host's; a Controller-only computer does not show them.
      if (host) ...[
        lockedRow(SenseSettingsStrings.acceptConn,
            connType == 'outgoing' ? SenseSettingsStrings.acceptConnNone : SenseSettingsStrings.acceptConnFor(approve),
            key: const Key('sense-set-conn-type')),
        lockedRow(SenseSettingsStrings.idleDisconnect,
            idleOn ? SenseSettingsStrings.idleMinutes(idleMin) : SenseSettingsStrings.off,
            key: const Key('sense-set-allow-auto-disconnect')),
        lockedRow(SenseSettingsStrings.lanDiscovery,
            _bool(SenseOptionKeys.lanDiscovery) ? SenseSettingsStrings.on : SenseSettingsStrings.off,
            key: const Key('sense-set-enable-lan-discovery')),
        lockedRow(SenseSettingsStrings.directIp,
            directOn ? (port.isEmpty ? SenseSettingsStrings.on : SenseSettingsStrings.directIpPort(port)) : SenseSettingsStrings.off,
            hint: SenseSettingsStrings.directIpHint,
            key: const Key('sense-set-direct-server')),
      ],
      lockedRow(SenseSettingsStrings.login, SenseSettingsStrings.loginValue, last: true, key: const Key('sense-set-login')),
    ];

    // Performans.
    final hwOn = _bool(SenseOptionKeys.hwcodec);
    final windows = widget.isWindowsHost ?? Theme.of(context).platform == TargetPlatform.windows;
    final codec = _raw(SenseOptionKeys.codecPreference).trim();
    final performance = <Widget>[
      if (controller)
        toggle(SenseOptionKeys.hwcodec, SenseSettingsStrings.hwcodec,
            hint: SenseSettingsStrings.hwcodecHint, last: !host),
      if (host) ...[
        lockedRow(SenseSettingsStrings.hostEncoder,
            codec.isEmpty || codec == 'auto' ? SenseSettingsStrings.codecAuto : codec.toUpperCase(),
            key: const Key('sense-set-codec-preference')),
        if (windows)
          lockedRow(SenseSettingsStrings.directx,
              _bool(SenseOptionKeys.directxCapture) ? SenseSettingsStrings.on : SenseSettingsStrings.off,
              key: const Key('sense-set-enable-directx-capture')),
        lockedRow(SenseSettingsStrings.wallpaper,
            _bool(SenseOptionKeys.removeWallpaper) ? SenseSettingsStrings.on : SenseSettingsStrings.off,
            last: true, key: const Key('sense-set-allow-remove-wallpaper')),
      ],
    ];

    // Ağ ve sunucu (always the panel's).
    final relayOnly = _b.readBool('force-always-relay', SenseOptionStore.main);
    final server = _raw(SenseOptionKeys.rendezvousServer).trim();
    final api = _raw(SenseOptionKeys.apiServer).trim();
    final proxy = _raw(SenseOptionKeys.proxyUrl).trim();
    final network = <Widget>[
      lockedRow(SenseSettingsStrings.server,
          server.isEmpty ? SenseSettingsStrings.serverPublic : SenseSettingsStrings.serverSense,
          // B8: the "no fallback" note is true only for the Sense server.
          hint: server.isEmpty ? null : SenseSettingsStrings.serverHint,
          key: const Key('sense-set-custom-rendezvous-server')),
      lockedRow(SenseSettingsStrings.panelAddress,
          api.isEmpty ? SenseSettingsStrings.panelNone : SenseSettingsStrings.panelSense,
          key: const Key('sense-set-api-server')),
      lockedRow(SenseSettingsStrings.proxy, proxy.isEmpty ? SenseSettingsStrings.proxyNone : SenseSettingsStrings.proxySet,
          key: const Key('sense-set-proxy-url')),
      lockedRow(SenseSettingsStrings.direct, relayOnly ? SenseSettingsStrings.directRelay : SenseSettingsStrings.on,
          last: true, key: const Key('sense-set-direct')),
    ];

    // Güncelleme (always the panel's).
    final update = <Widget>[
      lockedRow(SenseSettingsStrings.autoUpdate,
          controller && !host ? SenseSettingsStrings.autoUpdateController : SenseSettingsStrings.autoUpdateHost,
          hint: SenseSettingsStrings.autoUpdateHint, last: true, key: const Key('sense-set-allow-auto-update')),
    ];

    Widget column(List<Widget> rows) =>
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows);

    final items = <SenseAccordionItem>[
      SenseAccordionItem(
          id: SenseSettingsCategory.role,
          title: SenseSettingsStrings.catRole,
          summary: senseRoleSummary(_role),
          level: SenseLevel.ok,
          builder: (_) => SenseRoleCategoryBody(
              controller: _role, mac: Theme.of(context).platform == TargetPlatform.macOS)),
      if (controller) ...[
        SenseAccordionItem(
            id: SenseSettingsCategory.connections,
            title: SenseSettingsStrings.catConnections,
            summary: connSummary,
            level: SenseLevel.ok,
            builder: (_) => column(connections)),
        SenseAccordionItem(
            id: SenseSettingsCategory.newConnections,
            title: SenseSettingsStrings.catNew,
            summary: newSummary,
            level: SenseLevel.ok,
            builder: (_) => column(newConn)),
      ],
      SenseAccordionItem(
          id: SenseSettingsCategory.incoming,
          title: SenseSettingsStrings.catIncoming,
          summary: incomingSummary,
          level: SenseLevel.ok,
          builder: (_) => column(incoming)),
      SenseAccordionItem(
          id: SenseSettingsCategory.security,
          title: SenseSettingsStrings.catSecurity,
          summary: SenseSettingsStrings.sumSecurity,
          level: SenseLevel.ok,
          builder: (_) => column(security)),
      SenseAccordionItem(
          id: SenseSettingsCategory.performance,
          title: SenseSettingsStrings.catPerformance,
          summary: controller ? SenseSettingsStrings.sumHwcodec(hwOn) : SenseSettingsStrings.sumPanel,
          level: SenseLevel.ok,
          builder: (_) => column(performance)),
      SenseAccordionItem(
          id: SenseSettingsCategory.network,
          title: SenseSettingsStrings.catNetwork,
          summary: SenseSettingsStrings.sumNetwork(!relayOnly, publicServer: server.isEmpty),
          level: SenseLevel.ok,
          builder: (_) => column(network)),
      SenseAccordionItem(
          id: SenseSettingsCategory.update,
          title: SenseSettingsStrings.catUpdate,
          summary: SenseSettingsStrings.sumUpdate,
          level: SenseLevel.ok,
          builder: (_) => column(update)),
    ];

    if (_restarting) return const SenseSplash();
    return ColoredBox(
      color: SenseColors.bg,
      child: SenseScrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: kSensePagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SensePageHead(title: SenseSettingsStrings.title, note: SenseSettingsStrings.live),
              if (_failed != null) ...[
                SenseOverviewBox(
                  key: const Key('sense-settings-failed'),
                  level: SenseLevel.warn,
                  title: SenseSettingsStrings.saveFailedTitle,
                  body: SenseSettingsStrings.saveFailedBody,
                ),
                const SizedBox(height: kSensePageGap),
              ],
              SenseOverviewBox(
                key: const Key('sense-settings-overview'),
                title: SenseSettingsStrings.overviewTitle(senseRoleLabel(role), mine, lockedCount),
                body: SenseSettingsStrings.overviewBody,
              ),
              const SizedBox(height: kSensePageGap),
              SenseAccordion(
                items: items,
                initialOpenId: widget.initialOpen,
                density: SenseAccordionDensity.page,
                spacing: kSensePageGap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Router entry (A2c `SenseEntry.controllerSettings`, C3; never from a Host).
Widget senseControllerSettingsScreen() => const SenseSettingsPage();
