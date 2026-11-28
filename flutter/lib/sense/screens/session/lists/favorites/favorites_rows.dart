// Sense Remote (Sürüm 12, #160–#163): the parts of the "Sık kullanılanlar" list (prototype
// `.fv`, `.fi`, `.kb`, `.fkeys`, `.fpane`, `.fvask`, `.frec`, `.fg`, `.fc`, `.favform`).
// Only library colours, sizes and fonts.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../components/button.dart';
import '../../../../components/caret.dart';
import '../../../../components/inline_confirm.dart' show SenseConfirmStrip, senseAskRowColor;
import '../../../../components/glyph.dart';
import '../../../../components/sense_select.dart';
import '../../../../components/spinner.dart';
import '../../../../strings/common.dart';
import '../../../../strings/favorites.dart';
import '../../../../tokens/sense_tokens.dart';
import '../../../../tokens/theme.dart';
import 'catalog.dart';
import 'favorites_model.dart';

/// Turkish capitals: "Eklenebilecek" → "EKLENEBİLECEK" (Dart's own gives a dotless I).
String senseFavUpper(String s) => s.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();

/// Small caps section title (`.fvh`).
class SenseFavSectionTitle extends StatelessWidget {
  const SenseFavSectionTitle(this.text, {super.key, this.top = 8});
  final String text;
  final double top;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(14, top, 14, 2),
        child: Text(senseFavUpper(text),
            style: SenseTextStyles.of(
                size: SenseFontSize.caps,
                weight: SenseFontWeight.bold,
                color: SenseColors.textDim,
                letterSpacingEm: SenseLetterSpacing.capsWide)),
      );
}

/// The icon box (`.fi`): 24 px, 7 px corners; 20 px in the recent chips.
class SenseFavIcon extends StatelessWidget {
  const SenseFavIcon(this.icon, {super.key, this.small = false});
  final IconData icon;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final edge = small ? 20.0 : 24.0;
    return Container(
      width: edge,
      height: edge,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: SenseColors.raised,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(small ? 6 : 7),
      ),
      child: Icon(icon, size: small ? SenseFontSize.hint : SenseFontSize.bodySmall, color: SenseColors.text),
    );
  }
}

/// Grey tag (`.kb`) and orange tag (`.ftag`).
class _Chip extends StatelessWidget {
  const _Chip(this.label, {this.dashed = false, this.warn = false});
  final String label;
  final bool dashed;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: warn ? SenseColors.warn.withOpacity(0.15) : SenseColors.raised,
        border: warn ? null : Border.all(color: dashed ? SenseColors.lineStrong : SenseColors.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label,
          maxLines: 1,
          style: SenseTextStyles.of(
              size: warn ? SenseFontSize.capsSmall : SenseFontSize.hintSmall,
              color: warn ? SenseColors.warn : (dashed ? SenseColors.textDim : SenseColors.textMuted))),
    );
  }
}

/// Name, and a second line under it (`.fn`).
class _Name extends StatelessWidget {
  const _Name(this.name, {this.sub, this.subWarn = false});
  final String name;
  final String? sub;
  final bool subWarn;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.of(size: SenseFontSize.body, weight: SenseFontWeight.medium, height: 1.25)),
          if (sub != null)
            Text(sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SenseTextStyles.of(
                    size: SenseFontSize.hintSmall,
                    color: subWarn ? SenseColors.warn : SenseColors.textDim,
                    height: 1.25)),
        ],
      );
}

/// One row of "Kısayollarım" (`.fv`): grip, icon, name, key tag, "Aç ›".
class SenseFavMineRow extends StatelessWidget {
  const SenseFavMineRow({
    super.key,
    required this.item,
    required this.index,
    required this.keyLabel,
    required this.passive,
    required this.onRun,
    required this.onKeyTap,
    this.paneOpen = false,
  });

  final SenseFavItem item;
  final int index;

  /// "Ctrl+Alt+Shift+1", or null when no key is set.
  final String? keyLabel;

  /// No keyboard and mouse permission: faded, nothing runs.
  final bool passive;
  final bool paneOpen;
  final VoidCallback onRun;
  final VoidCallback onKeyTap;

  @override
  Widget build(BuildContext context) {
    final off = passive || item.pending || !item.available;
    final tip = passive
        ? SenseFavoritesStrings.needsInput
        : item.pending
            ? SenseFavoritesStrings.pendingApproval
            : (!item.available ? SenseFavoritesStrings.unavailable : null);
    final row = SenseInteractive(
      key: ValueKey('sense-fav-run-${item.id}'),
      onTap: off ? null : onRun,
      semanticLabel: item.name,
      tooltip: tip,
      builder: (context, s) {
        final go = item.pane != SenseFavPane.none
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                Text(SenseFavoritesStrings.openPane,
                    style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
                const SizedBox(width: 3),
                SenseCaret(
                    direction: SenseCaretDirection.down,
                    size: 8,
                    color: SenseColors.textMuted,
                    small: true),
              ])
            : Text(item.ask != null ? SenseFavoritesStrings.ask : SenseFavoritesStrings.open,
                style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted));
        final showKey = keyLabel != null || (s.hovered && !off);
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
          constraints: const BoxConstraints(minHeight: 34),
          decoration: BoxDecoration(
            color: s.hovered && !off ? SenseColors.hover : null,
            borderRadius: BorderRadius.circular(SenseRadii.button),
          ),
          child: Row(children: [
            Tooltip(
              message: SenseFavoritesStrings.dragTooltip,
              child: ReorderableDragStartListener(
                index: index,
                enabled: !passive,
                child: const MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: SizedBox(
                    width: 14,
                    child: SenseGlyph(SenseGlyphKind.drag, size: SenseFontSize.bodySmall, color: SenseColors.textDim),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            SenseFavIcon(item.icon),
            const SizedBox(width: 9),
            Expanded(
              child: _Name(item.name, sub: item.pending ? SenseFavoritesStrings.pendingApproval : null, subWarn: true),
            ),
            if (showKey) ...[
              const SizedBox(width: 9),
              GestureDetector(
                key: ValueKey('sense-fav-key-${item.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: off ? null : onKeyTap,
                child: Tooltip(
                  message: SenseFavoritesStrings.keyTooltip,
                  child: _Chip(keyLabel ?? SenseFavoritesStrings.addKey, dashed: keyLabel == null),
                ),
              ),
            ],
            const SizedBox(width: 9),
            go,
          ]),
        );
      },
    );
    return Opacity(opacity: off ? SenseUi.disabledOpacity : 1, child: row);
  }
}

/// The key slots under a row (`.fkeys`): 1–9 and "Yok".
class SenseFavKeyPicker extends StatelessWidget {
  const SenseFavKeyPicker({super.key, required this.current, required this.label, required this.onPick});
  final int? current;
  final String Function(int n) label;
  final ValueChanged<int?> onPick;

  Widget _slot(String text, bool sel, VoidCallback tap, Key key) => SenseInteractive(
        key: key,
        onTap: tap,
        selected: sel,
        semanticLabel: text,
        builder: (context, s) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: sel ? SenseColors.text : (s.hovered ? SenseColors.hover : SenseColors.surface),
            border: Border.all(color: sel ? SenseColors.text : SenseColors.line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(text,
              style: SenseTextStyles.of(
                  size: SenseFontSize.hintSmall,
                  weight: SenseFontWeight.medium,
                  color: sel ? SenseColors.bg : SenseColors.textSecondary)),
        ),
      );

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(36, 2, 12, 8),
        child: Wrap(spacing: 4, runSpacing: 4, children: [
          for (var n = 1; n <= 9; n++)
            _slot(label(n), current == n, () => onPick(n), ValueKey('sense-fav-slot-$n')),
          _slot(SenseFavoritesStrings.keyNone, false, () => onPick(null), const ValueKey('sense-fav-slot-none')),
        ]),
      );
}

/// The in-place question of a row that cannot be undone (`.it.asking.fvask`). Sürüm 12
/// (#158): the one question layout of the library ([SenseConfirmStrip]) on the row's red tint.
class SenseFavAskRow extends StatelessWidget {
  const SenseFavAskRow({super.key, required this.ask, required this.onCancel, required this.onConfirm});
  final SenseFavAsk ask;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('sense-fav-ask'),
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.fromLTRB(34, 8, 10, 10),
      decoration: BoxDecoration(
        color: senseAskRowColor,
        borderRadius: BorderRadius.circular(SenseRadii.button),
      ),
      child: SenseConfirmStrip(
        question: ask.question,
        detail: ask.detail,
        confirmLabel: ask.ok,
        confirmKind: ask.danger ? SenseButtonKind.danger : SenseButtonKind.primary,
        onCancel: onCancel,
        onConfirm: onConfirm,
      ),
    );
  }
}

/// The box under a pane row (`.fpane`).
class _PaneBox extends StatelessWidget {
  const _PaneBox({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(34, 2, 10, 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.button),
        ),
        child: child,
      );
}

/// One "label · value" line (`.fkv`).
class SenseFavKv extends StatelessWidget {
  const SenseFavKv(this.label, this.value, {super.key});
  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textDim)),
          const SizedBox(width: 10),
          Expanded(child: Align(alignment: Alignment.centerRight, child: value)),
        ]),
      );
}

Widget _value(String text, {Color color = SenseColors.text}) => Text(text,
    textAlign: TextAlign.right,
    style: SenseTextStyles.of(size: SenseFontSize.hintLarge, weight: SenseFontWeight.medium, color: color));

/// IP card (`favPanel('ipinfo')`).
class SenseFavIpPane extends StatelessWidget {
  const SenseFavIpPane({super.key, required this.info});
  final SenseFavIpInfo info;

  @override
  Widget build(BuildContext context) {
    if (info.empty) {
      return _PaneBox(
        child: Text(SenseFavoritesStrings.ipUnknown,
            key: const ValueKey('sense-fav-ip-unknown'),
            style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textDim)),
      );
    }
    String join(List<String> l) => l.isEmpty ? '—' : l.join(' · ');
    return _PaneBox(
      child: Column(key: const ValueKey('sense-fav-ip'), mainAxisSize: MainAxisSize.min, children: [
        SenseFavKv(SenseFavoritesStrings.ipAddress, _value(info.ip ?? '—')),
        SenseFavKv(SenseFavoritesStrings.ipGateway, _value(join(info.gateway))),
        SenseFavKv(SenseFavoritesStrings.ipDns, _value(join(info.dns))),
      ]),
    );
  }
}

/// IP card with the Host's own answer (#171, `res.ip`): the session's data shows at once, the
/// Host's values replace it when they come; an older Host leaves the session's data.
class SenseFavHostIpPane extends StatefulWidget {
  const SenseFavHostIpPane({super.key, required this.fallback, required this.load});
  final SenseFavIpInfo fallback;
  final Future<SenseFavIpInfo?> Function() load;

  @override
  State<SenseFavHostIpPane> createState() => _SenseFavHostIpPaneState();
}

class _SenseFavHostIpPaneState extends State<SenseFavHostIpPane> {
  SenseFavIpInfo? _host;

  @override
  void initState() {
    super.initState();
    widget.load().then((v) {
      if (mounted && v != null && !v.empty) setState(() => _host = v);
    });
  }

  @override
  Widget build(BuildContext context) => SenseFavIpPane(info: _host ?? widget.fallback);
}

/// A one-line text field of the list (search, ping address, form): dark, white frame on focus.
class SenseFavField extends StatelessWidget {
  const SenseFavField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.focusNode,
    this.maxLength,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final FocusNode? focusNode;
  final int? maxLength;

  OutlineInputBorder _border(Color c) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(SenseRadii.button), borderSide: BorderSide(color: c));

  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          maxLines: 1,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          inputFormatters: [if (maxLength != null) LengthLimitingTextInputFormatter(maxLength)],
          style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.medium),
          cursorColor: SenseColors.text,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: SenseColors.surface,
            hintText: hint,
            hintStyle: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textDim),
            contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            enabledBorder: _border(SenseColors.line),
            focusedBorder: _border(SenseColors.text),
            disabledBorder: _border(SenseColors.line),
            border: _border(SenseColors.line),
          ),
        ),
      );
}

/// Ping pane (`favPanel('ping')`): address, "Başlat", the result line.
class SenseFavPingPane extends StatefulWidget {
  const SenseFavPingPane({super.key, required this.onPing});
  final Future<String> Function(String address) onPing;

  @override
  State<SenseFavPingPane> createState() => _SenseFavPingPaneState();
}

class _SenseFavPingPaneState extends State<SenseFavPingPane> {
  final _addr = TextEditingController(text: SenseFavoritesStrings.pingDefault);
  bool _running = false;
  String? _result;

  @override
  void dispose() {
    _addr.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _running = true;
      _result = null;
    });
    final r = await widget.onPing(_addr.text);
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _PaneBox(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Row(children: [
            Expanded(
              child: SenseFavField(
                key: const ValueKey('sense-fav-ping-addr'),
                controller: _addr,
                hint: SenseFavoritesStrings.pingHint,
                maxLength: 253,
                onSubmitted: (_) => _start(),
              ),
            ),
            const SizedBox(width: 6),
            SenseButton(
              key: const ValueKey('sense-fav-ping-start'),
              label: SenseFavoritesStrings.pingStart,
              size: SenseButtonSize.small,
              onPressed: _running ? null : _start,
            ),
          ]),
        ),
        if (_running)
          SenseFavKv(
              SenseFavoritesStrings.pingResult,
              Row(mainAxisSize: MainAxisSize.min, children: [
                const SenseSpinner(size: 10),
                const SizedBox(width: 6),
                _value(SenseFavoritesStrings.pingRunning),
              ])),
        if (!_running && _result != null)
          SenseFavKv(SenseFavoritesStrings.pingResult,
              _value(_result!, color: _result == SenseFavoritesStrings.pingUnsupported ? SenseColors.textMuted : SenseColors.text)),
      ]),
    );
  }
}

/// Window list pane (`favPanel('killhung')`, #171): the Host's windows / apps (`res.windows`),
/// the ones that do not answer first with a red button; "Kapat" (Mac "Çık") closes one.
class SenseFavWindowsPane extends StatefulWidget {
  const SenseFavWindowsPane({super.key, required this.load, required this.close, this.mac = false});
  final Future<(List<SenseFavWindow>?, String?)> Function() load;
  final Future<String?> Function(SenseFavWindow w) close;
  final bool mac;

  @override
  State<SenseFavWindowsPane> createState() => _SenseFavWindowsPaneState();
}

class _SenseFavWindowsPaneState extends State<SenseFavWindowsPane> {
  List<SenseFavWindow>? _list;
  String? _error;
  bool _loading = true;
  int? _closing;

  @override
  void initState() {
    super.initState();
    widget.load().then((r) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _list = r.$1;
        _error = r.$2;
      });
    });
  }

  Future<void> _close(SenseFavWindow w) async {
    setState(() {
      _closing = w.pid;
      _error = null;
    });
    final err = await widget.close(w);
    if (!mounted) return;
    setState(() {
      _closing = null;
      if (err == null) {
        _list = [for (final x in _list ?? const <SenseFavWindow>[]) if (x.pid != w.pid) x];
      } else {
        _error = err;
      }
    });
  }

  Widget _line(String text, {Key? key, Color color = SenseColors.textMuted}) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Text(text, key: key, style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: color)),
      );

  @override
  Widget build(BuildContext context) {
    final list = _list;
    return _PaneBox(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(SenseFavoritesStrings.windowList,
              style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim)),
        ),
        if (_loading)
          Padding(
            key: const ValueKey('sense-fav-windows-loading'),
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              const SenseSpinner(size: 10),
              const SizedBox(width: 6),
              Text(SenseFavoritesStrings.windowsLoading,
                  style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
            ]),
          ),
        if (!_loading && list != null && list.isEmpty)
          _line(SenseFavoritesStrings.windowsEmpty, key: const ValueKey('sense-fav-windows-empty')),
        if (list != null)
          for (final w in list)
            Padding(
              key: ValueKey('sense-fav-window-${w.pid}'),
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Expanded(
                  child: Text(SenseFavoritesStrings.windowName(w.name, hung: w.hung),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SenseTextStyles.of(size: SenseFontSize.hintLarge)),
                ),
                const SizedBox(width: 8),
                SenseButton(
                  key: ValueKey('sense-fav-window-close-${w.pid}'),
                  label: widget.mac ? SenseFavoritesStrings.windowQuit : SenseFavoritesStrings.windowClose,
                  size: SenseButtonSize.small,
                  kind: w.hung ? SenseButtonKind.danger : SenseButtonKind.normal,
                  onPressed: _closing == null ? () => _close(w) : null,
                ),
              ]),
            ),
        if (_error != null)
          _line(_error!,
              key: ValueKey(list == null ? 'sense-fav-windows-unsupported' : 'sense-fav-windows-error')),
      ]),
    );
  }
}

/// A recent chip (`.frec button`).
class SenseFavRecentChip extends StatelessWidget {
  const SenseFavRecentChip({super.key, required this.item, required this.passive, required this.onTap});
  final SenseFavItem item;
  final bool passive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chip = SenseInteractive(
      key: ValueKey('sense-fav-recent-${item.id}'),
      onTap: passive ? null : onTap,
      semanticLabel: item.name,
      tooltip: passive ? SenseFavoritesStrings.needsInput : null,
      builder: (context, s) => Container(
        padding: const EdgeInsets.fromLTRB(5, 4, 9, 4),
        decoration: BoxDecoration(
          color: s.hovered && !passive ? SenseColors.hover : SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.button),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SenseFavIcon(item.icon, small: true),
          const SizedBox(width: 6),
          Text(item.name,
              style: SenseTextStyles.of(
                  size: SenseFontSize.hintLarge, weight: SenseFontWeight.medium, color: SenseColors.textSecondary)),
        ]),
      ),
    );
    return Opacity(opacity: passive ? SenseUi.disabledOpacity : 1, child: chip);
  }
}

/// One catalogue group (`.fg`): closable box, "2 seçili · 9" while closed.
class SenseFavGroupBox extends StatelessWidget {
  const SenseFavGroupBox({
    super.key,
    required this.group,
    required this.open,
    required this.chosenCount,
    required this.count,
    required this.onToggle,
    required this.children,
  });

  final SenseFavGroup group;
  final bool open;
  final int chosenCount;
  final int count;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: SenseColors.bg,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        SenseInteractive(
          key: ValueKey('sense-fav-group-${group.name}'),
          onTap: onToggle,
          semanticLabel: group.title,
          toggled: open,
          builder: (context, s) => Container(
            color: s.hovered ? SenseColors.hover : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              SenseCaret(direction: open ? SenseCaretDirection.down : SenseCaretDirection.right, size: 8),
              const SizedBox(width: 8),
              Expanded(
                child: Text(group.title,
                    style: SenseTextStyles.of(size: SenseFontSize.body, weight: SenseFontWeight.bold)),
              ),
              Text(SenseFavoritesStrings.groupCount(chosenCount, count),
                  style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim)),
            ]),
          ),
        ),
        if (open)
          Container(
            padding: const EdgeInsets.only(bottom: 6),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: SenseColors.line))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
      ]),
    );
  }
}

/// A catalogue row with its tick (`.fc`).
class SenseFavCatalogRow extends StatelessWidget {
  const SenseFavCatalogRow({super.key, required this.item, required this.chosen, required this.onToggle});
  final SenseFavItem item;
  final bool chosen;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => SenseInteractive(
        key: ValueKey('sense-fav-pick-${item.id}'),
        onTap: onToggle,
        toggled: chosen,
        semanticLabel: item.name,
        builder: (context, s) => Container(
          color: s.hovered ? SenseColors.hover : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          constraints: const BoxConstraints(minHeight: 34),
          child: Row(children: [
            SenseFavIcon(item.icon),
            const SizedBox(width: 9),
            Expanded(child: _Name(item.name, sub: item.description)),
            if (item.pending) ...[
              const SizedBox(width: 9),
              const _Chip(SenseFavoritesStrings.pendingTag, warn: true),
            ],
            const SizedBox(width: 9),
            _Tick(on: chosen),
          ]),
        ),
      );
}

class _Tick extends StatelessWidget {
  const _Tick({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
        width: 16,
        height: 16,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? SenseColors.text : null,
          border: Border.all(color: on ? SenseColors.text : SenseColors.lineStrong, width: 1.5),
          borderRadius: BorderRadius.circular(5),
        ),
        child: on ? const SenseGlyph(SenseGlyphKind.check, size: SenseFontSize.hint, color: SenseColors.bg) : null,
      );
}

/// "+ Özel kısayol ekle" (`.fadd`).
class SenseFavAddLine extends StatelessWidget {
  const SenseFavAddLine({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SenseInteractive(
        key: const ValueKey('sense-fav-add'),
        onTap: onTap,
        semanticLabel: SenseFavoritesStrings.addCustom,
        builder: (context, s) => Container(
          color: s.hovered ? SenseColors.hover : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(SenseFavoritesStrings.addCustom,
              style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.medium)),
        ),
      );
}

/// The custom shortcut form (`.favform`, #161, K3, K8).
class SenseFavCustomFormView extends StatefulWidget {
  const SenseFavCustomFormView({super.key, required this.os, required this.onCancel, required this.onSubmit});
  final SenseFavOs os;
  final VoidCallback onCancel;

  /// Null when sent, else the reason shown under the form.
  final Future<String?> Function(SenseFavCustomForm form) onSubmit;

  @override
  State<SenseFavCustomFormView> createState() => _SenseFavCustomFormViewState();
}

class _SenseFavCustomFormViewState extends State<SenseFavCustomFormView> {
  final _name = TextEditingController();
  final _path = TextEditingController();
  late SenseFavOs _os = widget.os == SenseFavOs.linux ? SenseFavOs.win : widget.os;
  SenseFavCustomKind _kind = SenseFavCustomKind.program;
  SenseFavCustomScope _scope = SenseFavCustomScope.pc;
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  String get _pathHint => switch (_kind) {
        SenseFavCustomKind.url => SenseFavoritesStrings.formPathUrl,
        SenseFavCustomKind.folder =>
          _os == SenseFavOs.win ? SenseFavoritesStrings.formPathFolder : SenseFavoritesStrings.formPathFolderMac,
        SenseFavCustomKind.program =>
          _os == SenseFavOs.win ? SenseFavoritesStrings.formPathProgram : SenseFavoritesStrings.formPathProgramMac,
      };

  Future<void> _submit() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final err = await widget.onSubmit(SenseFavCustomForm(
      name: _name.text,
      os: _os,
      kind: _kind,
      target: _path.text,
      scope: _scope,
    ));
    if (!mounted) return;
    setState(() {
      _sending = false;
      _error = err;
    });
  }

  Widget _select<T>(Key key, T value, List<(T, String)> options, ValueChanged<T> onChanged) => SizedBox(
        width: double.infinity,
        child: SenseSelect<T>(
          key: key,
          value: value,
          options: [for (final o in options) SenseSelectOption(value: o.$1, label: o.$2)],
          onChanged: (v) => setState(() => onChanged(v)),
          menuMinWidth: 300,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('sense-fav-form'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        SenseFavField(
            key: const ValueKey('sense-fav-form-name'),
            controller: _name,
            hint: SenseFavoritesStrings.formName,
            maxLength: 60),
        const SizedBox(height: 7),
        _select(const ValueKey('sense-fav-form-os'), _os, const [
          (SenseFavOs.win, SenseFavoritesStrings.formOsWin),
          (SenseFavOs.mac, SenseFavoritesStrings.formOsMac),
          (SenseFavOs.linux, SenseFavoritesStrings.formOsLinux),
        ], (v) => _os = v),
        const SizedBox(height: 7),
        _select(const ValueKey('sense-fav-form-kind'), _kind, const [
          (SenseFavCustomKind.program, SenseFavoritesStrings.formKindProgram),
          (SenseFavCustomKind.folder, SenseFavoritesStrings.formKindFolder),
          (SenseFavCustomKind.url, SenseFavoritesStrings.formKindUrl),
        ], (v) => _kind = v),
        const SizedBox(height: 7),
        SenseFavField(
            key: const ValueKey('sense-fav-form-path'), controller: _path, hint: _pathHint, maxLength: 1024),
        const SizedBox(height: 7),
        _select(const ValueKey('sense-fav-form-scope'), _scope, const [
          (SenseFavCustomScope.pc, SenseFavoritesStrings.formScopePc),
          (SenseFavCustomScope.project, SenseFavoritesStrings.formScopeProject),
          (SenseFavCustomScope.all, SenseFavoritesStrings.formScopeAll),
        ], (v) => _scope = v),
        const SizedBox(height: 7),
        Text(SenseFavoritesStrings.formNote,
            style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim)),
        if (_error != null) ...[
          const SizedBox(height: 5),
          Text(_error!,
              key: const ValueKey('sense-fav-form-error'),
              style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.warn)),
        ],
        const SizedBox(height: 7),
        Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
          SenseButton(
            key: const ValueKey('sense-fav-form-cancel'),
            label: SenseCommonStrings.cancel,
            size: SenseButtonSize.small,
            onPressed: widget.onCancel,
          ),
          SenseButton(
            key: const ValueKey('sense-fav-form-add'),
            label: _sending ? SenseFavoritesStrings.formSending : SenseFavoritesStrings.formAdd,
            size: SenseButtonSize.small,
            kind: SenseButtonKind.primary,
            onPressed: _sending ? null : _submit,
          ),
        ]),
      ]),
    );
  }
}
