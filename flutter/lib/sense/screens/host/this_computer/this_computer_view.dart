// Sense Remote: "Bu bilgisayar" page (YH H1, H2; prototype `thisView`, images
// a09–a11). Header with live state, the status box (six states, name ✎ in its
// title, tiles Kimlik + Kopyala · Yer ✎ · Sense paneli · Etkin bağlantı) and the
// closable categories (one open): Yetkiler, Kalıcı şifre, Bu bilgisayarın rolü,
// Son bağlantılar. Pure view (data + callbacks); the binding is
// this_computer_page.dart. Host + Controller (B3) shows the same page without
// the role category (it is in Ayarlar) and with the password in Ayarlar.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/host.dart';
import '../data/host_status.dart';
import '../data/identity.dart';
import '../password/password_category.dart';
import '../permissions/permissions_category.dart';
import '../recent/recent_category.dart';
import '../role/role_category.dart';
import '../sense_password_model.dart';

/// Level of a state (prototype HOSTST).
SenseLevel senseHostPhaseLevel(SenseHostPhase p) {
  switch (p) {
    case SenseHostPhase.ready:
    case SenseHostPhase.busy:
      return SenseLevel.ok;
    case SenseHostPhase.connecting:
      return SenseLevel.warn;
    case SenseHostPhase.down:
    case SenseHostPhase.stopped:
    case SenseHostPhase.mac:
      return SenseLevel.hot;
  }
}

/// Short state word of the header and the box title.
String senseHostPhaseWord(SenseHostPhase p) {
  switch (p) {
    case SenseHostPhase.ready:
      return SenseHostStrings.ready;
    case SenseHostPhase.connecting:
      return SenseHostStrings.connecting;
    case SenseHostPhase.busy:
      return SenseHostStrings.connected;
    case SenseHostPhase.down:
    case SenseHostPhase.stopped:
    case SenseHostPhase.mac:
      return SenseHostStrings.notReady;
  }
}

/// Error text of a name / place save.
String senseIdentityErrorText(String code) {
  switch (code) {
    case 'invalid':
      return SenseHostStrings.errInvalid;
    case 'network':
      return SenseHostStrings.errNetwork;
    case 'location_not_in_project':
      return SenseHostStrings.errLocation;
    case 'unavailable':
      return SenseHostStrings.errUnavailable;
    default:
      return SenseHostStrings.errOther;
  }
}

/// Category ids (also test keys `sense-acc-<id>`).
abstract final class SenseThisComputerCategory {
  static const String permissions = 'perm';
  static const String password = 'pw';
  static const String role = 'role';
  static const String recent = 'recent';
}

class SenseThisComputerView extends StatefulWidget {
  const SenseThisComputerView({
    super.key,
    required this.phase,
    required this.identity,
    required this.deviceId,
    required this.permissions,
    required this.recent,
    required this.now,
    this.macMissing = const [],
    this.connections = 0,
    this.connectedBy,
    this.connectedSeconds,
    this.onRetry,
    this.onStartService,
    this.onOpenPermissions,
    this.onRename,
    this.onPlace,
    this.passwordController,
    this.passwordStatus = SensePasswordStatus.none,
    this.onOpenSettingsPassword,
    this.roleController,
    this.mac = false,
    this.initialOpen,
  });

  final SenseHostPhase phase;
  final SenseIdentity identity;
  final String deviceId;

  /// One value per [kSenseHostPermissions] entry.
  final List<bool> permissions;
  final List<SenseRecentConnection> recent;
  final DateTime now;

  /// Names of the missing macOS permissions (state [SenseHostPhase.mac]).
  final List<String> macMissing;
  final int connections;
  final String? connectedBy;
  final int? connectedSeconds;

  final VoidCallback? onRetry;
  final VoidCallback? onStartService;
  final VoidCallback? onOpenPermissions;

  /// Saves the new name; answers null or an error code.
  final Future<String?> Function(String name)? onRename;

  /// Saves the new place; answers null or an error code.
  final Future<String?> Function(SensePlace place)? onPlace;

  /// Host: the password flow in the category. Null (Host + Controller): a row
  /// that opens Ayarlar (prototype "Ayarlar'da aç").
  final SensePasswordController? passwordController;

  /// Header summary when [passwordController] is null.
  final SensePasswordStatus passwordStatus;
  final VoidCallback? onOpenSettingsPassword;

  /// Null hides the role category (Host + Controller: it is in Ayarlar).
  final SenseRoleController? roleController;
  final bool mac;
  final String? initialOpen;

  @override
  State<SenseThisComputerView> createState() => _SenseThisComputerViewState();
}

class _SenseThisComputerViewState extends State<SenseThisComputerView> {
  bool _placeEditing = false;
  bool _saved = false;
  String? _error;
  Timer? _savedTimer;

  @override
  void dispose() {
    _savedTimer?.cancel();
    super.dispose();
  }

  void _answer(String? error) {
    if (!mounted) return;
    _savedTimer?.cancel();
    setState(() {
      _error = error == null ? null : senseIdentityErrorText(error);
      _saved = error == null;
    });
    if (error == null) {
      _savedTimer = Timer(SenseMotion.savedHoldLong.duration, () {
        if (mounted) setState(() => _saved = false);
      });
    }
  }

  Future<void> _rename(String name) async {
    if (widget.onRename == null) return;
    _answer(await widget.onRename!(name));
  }

  Future<void> _place(String id) async {
    setState(() => _placeEditing = false);
    final place = widget.identity.places.where((p) => p.id == id).firstOrNull;
    if (place == null || id == widget.identity.placeId || widget.onPlace == null) return;
    _answer(await widget.onPlace!(place));
  }

  @override
  Widget build(BuildContext context) {
    final level = senseHostPhaseLevel(widget.phase);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SenseHeaderRow(
          key: const Key('sense-host-header'),
          title: SenseHostStrings.thisComputerBold,
          titleThin: SenseHostStrings.thisComputerThin,
          status: senseHostPhaseWord(widget.phase),
          statusLevel: level,
        ),
        _statusBox(level),
        const SizedBox(height: _kGap),
        _categories(),
      ],
    );
  }

  // ---- status box (H1) ----

  (String, Widget?) _stateLine() {
    switch (widget.phase) {
      case SenseHostPhase.ready:
        return (SenseHostStrings.readyText, null);
      case SenseHostPhase.connecting:
        return (SenseHostStrings.connectingText, null);
      case SenseHostPhase.busy:
        final d = widget.connectedSeconds;
        return (SenseHostStrings.busyText(widget.connectedBy, d == null ? null : SenseHostStrings.duration(d)), null);
      case SenseHostPhase.down:
        return (
          SenseHostStrings.downText,
          SenseButton(
              key: const Key('sense-host-retry'),
              label: SenseHostStrings.retry,
              kind: SenseButtonKind.primary, // same look as the Controller list's retry (Y8)
              size: SenseButtonSize.small,
              onPressed: widget.onRetry)
        );
      case SenseHostPhase.stopped:
        return (
          SenseHostStrings.stoppedText,
          SenseButton(
              key: const Key('sense-host-start-service'),
              label: SenseHostStrings.startService,
              size: SenseButtonSize.small,
              kind: SenseButtonKind.primary,
              onPressed: widget.onStartService)
        );
      case SenseHostPhase.mac:
        return (
          SenseHostStrings.macText(widget.macMissing.isEmpty ? const ['Ekran Kaydı'] : widget.macMissing),
          SenseButton(
              key: const Key('sense-host-open-permissions'),
              label: SenseHostStrings.openPermissions,
              size: SenseButtonSize.small,
              kind: SenseButtonKind.primary,
              onPressed: widget.onOpenPermissions)
        );
    }
  }

  Widget _statusBox(SenseLevel level) {
    final (text, action) = _stateLine();
    final titleStyle = SenseTextStyles.of(
        size: SenseFontSize.categoryTitleSmall,
        weight: SenseFontWeight.bold,
        color: SenseStatusBox.titleColor(level));
    final name = widget.identity.name.isEmpty ? SenseHostStrings.thisComputer : widget.identity.name;
    final hot = level == SenseLevel.hot;
    final down = widget.phase == SenseHostPhase.down || widget.phase == SenseHostPhase.stopped;
    final panelOk = widget.identity.panelOk ?? !down;
    final busy = widget.phase == SenseHostPhase.busy || widget.connections > 0;
    return Container(
      key: const Key('sense-status-box'),
      padding: const EdgeInsets.symmetric(vertical: _kBoxPadV, horizontal: _kBoxPadH),
      decoration: BoxDecoration(
        color: hot ? null : SenseColors.bg,
        gradient: hot
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.alphaBlend(SenseColors.hot.withOpacity(0.08), SenseColors.bg), SenseColors.bg],
                stops: const [0, 0.6],
              )
            : null,
        border: Border.all(color: SenseStatusBox.borderColor(level)),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('${senseHostPhaseWord(widget.phase)} — ', style: titleStyle),
                  Flexible(
                    child: SenseInlineEdit(
                      key: const Key('sense-host-name'),
                      value: name,
                      style: titleStyle,
                      tooltip: SenseHostStrings.editName,
                      enabled: widget.onRename != null,
                      onSubmitted: _rename,
                    ),
                  ),
                ]),
                const SizedBox(height: 2),
                Text(text,
                    key: const Key('sense-host-state'),
                    style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
              ]),
            ),
            if (action != null) ...[const SizedBox(width: _kGap), action],
          ]),
          const SizedBox(height: _kBoxPadV),
          SenseStatGrid(children: [
            _HostTile(
              label: SenseHostStrings.id,
              // Kopyala sits on the label line (top right), so the ID tile is as tall as the others.
              trailing: SenseCopyButton(
                  key: const Key('sense-host-copy-id'),
                  text: widget.deviceId.replaceAll(' ', ''),
                  onCopied: () => SenseToast.show(context, SenseHostStrings.idCopied)),
              child: Text(widget.deviceId,
                  key: const Key('sense-host-id'),
                  maxLines: 1,
                  softWrap: false,
                  style: _valueStyle(null)),
            ),
            _HostTile(label: SenseHostStrings.place, child: _placeValue()),
            _HostTile(
              label: SenseHostStrings.panel,
              level: panelOk ? SenseLevel.ok : SenseLevel.hot,
              child: Text(panelOk ? SenseHostStrings.panelOk : SenseHostStrings.panelDown,
                  key: const Key('sense-host-panel'),
                  style: _valueStyle(panelOk ? SenseLevel.ok : SenseLevel.hot)),
            ),
            _HostTile(
              label: SenseHostStrings.activeConnection,
              level: busy ? SenseLevel.ok : null,
              child: Text(
                  busy
                      ? SenseHostStrings.activeCount(widget.connections < 1 ? 1 : widget.connections, widget.connectedBy)
                      : SenseHostStrings.none,
                  key: const Key('sense-host-active'),
                  style: _valueStyle(busy ? SenseLevel.ok : null)),
            ),
          ]),
          if (_saved || _error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error ?? SenseHostStrings.identitySaved,
                  key: const Key('sense-host-identity-note'),
                  style: SenseTextStyles.of(
                      size: SenseFontSize.hint,
                      color: _error == null ? SenseColors.ok : SenseColors.dangerTextSoft)),
            ),
        ],
      ),
    );
  }

  Widget _placeValue() {
    final id = widget.identity;
    final text = id.placeName.isEmpty ? SenseHostStrings.noPlace : id.placeName;
    final canEdit = widget.onPlace != null && id.places.length > 1;
    if (_placeEditing && canEdit) {
      return CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => setState(() => _placeEditing = false)},
        child: Focus(
          autofocus: true,
          child: SenseSelect<String>(
            key: const Key('sense-host-place-select'),
            options: [for (final p in id.places) SenseSelectOption(value: p.id, label: p.name)],
            value: id.placeId,
            onChanged: _place,
          ),
        ),
      );
    }
    return _PenText(
      key: const Key('sense-host-place'),
      text: text,
      style: _valueStyle(null),
      tooltip: SenseHostStrings.editPlace,
      onTap: canEdit ? () => setState(() => _placeEditing = true) : null,
    );
  }

  // ---- categories (H2) ----

  Widget _categories() {
    final pw = widget.passwordController;
    final role = widget.roleController;
    return ListenableBuilder(
      listenable: Listenable.merge([if (pw != null) pw, if (role != null) role]),
      builder: (context, _) {
        final pwStatus = pw?.status ?? widget.passwordStatus;
        return SenseAccordion(
          density: SenseAccordionDensity.page,
          spacing: _kGap,
          initialOpenId: widget.initialOpen,
          items: [
            SenseAccordionItem(
              id: SenseThisComputerCategory.permissions,
              title: SenseHostStrings.permissions,
              summary: senseHostPermissionsSummary(widget.permissions),
              level: SenseLevel.ok,
              builder: (_) => SensePermissionsCategoryBody(on: widget.permissions),
            ),
            SenseAccordionItem(
              id: SenseThisComputerCategory.password,
              title: SenseHostStrings.password,
              summary: senseHostPasswordSummary(pwStatus),
              level: senseHostPasswordLevel(pwStatus),
              builder: (_) => pw != null
                  ? SensePasswordCategoryBody(controller: pw, deviceId: widget.deviceId)
                  : SenseSettingRow(
                      key: const Key('sense-pw-settings-row'),
                      label: SenseHostStrings.passwordInSettings,
                      description: SenseHostStrings.passwordInSettingsHint,
                      last: true,
                      control: SenseButton(
                          key: const Key('sense-pw-open-settings'),
                          label: SenseHostStrings.openInSettings,
                          size: SenseButtonSize.small,
                          onPressed: widget.onOpenSettingsPassword),
                    ),
            ),
            if (role != null)
              SenseAccordionItem(
                id: SenseThisComputerCategory.role,
                title: SenseHostStrings.role,
                summary: senseRoleSummary(role),
                level: role.busy ? SenseLevel.warn : SenseLevel.ok,
                builder: (_) => SenseRoleCategoryBody(controller: role, mac: widget.mac),
              ),
            SenseAccordionItem(
              id: SenseThisComputerCategory.recent,
              title: SenseHostStrings.recent,
              summary: senseRecentSummary(widget.recent, widget.now),
              level: widget.recent.isEmpty ? null : SenseLevel.ok,
              builder: (_) => SenseRecentCategoryBody(list: widget.recent, now: widget.now),
            ),
          ],
        );
      },
    );
  }
}

// Prototype `.amain` gap 10; `.ov` padding 8×10; `.kv>div` padding 8×10, gap 2.
const double _kGap = 10, _kBoxPadV = 8, _kBoxPadH = 10, _kTilePadV = 8, _kTilePadH = 10;

TextStyle _valueStyle(SenseLevel? level) => SenseTextStyles.of(
      size: SenseFontSize.categoryTitle,
      weight: SenseFontWeight.bold,
      color: switch (level) {
        SenseLevel.ok => SenseColors.ok,
        SenseLevel.warn => SenseColors.warn,
        SenseLevel.hot => SenseColors.dangerText,
        _ => SenseColors.text,
      },
    );

/// A tile of the status box (`.kv>div`): label + any value widget.
class _HostTile extends StatelessWidget {
  const _HostTile({required this.label, required this.child, this.level, this.trailing});

  final String label;
  final Widget child;
  final SenseLevel? level;

  /// Drawn over the top right corner, on the label line; takes no height.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final border = switch (level) {
      SenseLevel.warn => SenseColors.warn.withOpacity(0.45),
      SenseLevel.hot => SenseColors.hot.withOpacity(0.55),
      _ => SenseColors.line,
    };
    final tile = Container(
      padding: const EdgeInsets.symmetric(vertical: _kTilePadV, horizontal: _kTilePadH),
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(SenseRadii.category),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.of(size: SenseFontSize.caps, color: SenseColors.textMuted)),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
    final t = trailing;
    if (t == null) return tile;
    return Stack(children: [
      tile,
      Positioned(top: _kTilePadV - 4, right: _kTilePadH - 2, child: t),
    ]);
  }
}

/// Text with a ✎ that shows on hover (prototype `.mefld`); null [onTap] = plain text.
class _PenText extends StatelessWidget {
  const _PenText({super.key, required this.text, required this.style, this.tooltip, this.onTap});

  final String text;
  final TextStyle style;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    if (onTap == null) return label;
    return SenseInteractive(
      onTap: onTap,
      tooltip: tooltip,
      mouseCursor: SystemMouseCursors.click,
      builder: (_, s) => SenseFocusRing(
        visible: s.focused,
        radius: SenseRadii.button,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: label),
          const SizedBox(width: SenseUi.iconGap),
          Opacity(
            opacity: s.hovered || s.focused ? 1 : 0,
            child: Icon(Icons.edit_outlined,
                size: SenseFontSize.hint,
                color: s.hovered ? SenseColors.text : SenseColors.textMuted),
          ),
        ]),
      ),
    );
  }
}
