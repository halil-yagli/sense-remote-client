// Sense Remote (Sürüm 12, #160–#163, #167): the "Sık kullanılanlar" list of the session bar
// (prototype `favHTML`). Same frame as the other bar lists (360 px, fixed title row with the
// count chip, thin scrollbar); inside:
//  - the system label ("Windows için kısayolların") and the search field,
//  - KISAYOLLARIM: the employee's own shortcuts, one click each, drag to sort, a key slot
//    (Ctrl+Alt+Shift+1–9, Mac Cmd+Option+Shift); rows that cannot be undone ask in place,
//    IP card / ping / window list open under the row,
//  - SON KULLANILANLAR: the last three used,
//  - EKLENEBİLECEK KISAYOLLAR: the catalogue in closable groups, a tick adds or removes;
//    "Özel kısayollar" has the request form (waits for a Yönetici, K8),
//  - a note that the choice is kept in the account per system.
// Without keyboard and mouse permission (or with "Yalnız izle") every row is grey (#160).
// Linux has no list yet: a placeholder (#163).
//
// The bar (OT) places [SenseFavoritesButton] as its fifth list and opens this under it; on a
// narrow window the button is a star with a tooltip (#167). The session event listener
// passes `sense_shortcut_result` to `SenseFavoritesEvents.handle`; the key handler passes
// key-downs to [SenseFavoritesHotkeys.handle].
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../components/button.dart';
import '../../../../components/caret.dart';
import '../../../../components/scrollbar.dart';
import '../../../../diag_log.dart';
import '../../../../strings/favorites.dart';
import '../../../../tokens/sense_tokens.dart';
import '../../../../tokens/theme.dart';
import '../session_list.dart' show SenseStateChip, kSenseListRadius, kSenseListWidth;
import 'catalog.dart';
import 'favorites_model.dart';
import 'favorites_rows.dart';

export 'catalog.dart' show SenseFavOs;
export 'favorites_io.dart' show SenseFavoritesEvents, SenseFavoritesIo;
export 'favorites_model.dart' show SenseFavoritesModel, SenseFavIpInfo, senseFavIpInfoFrom;

/// `where` of the interface records written from the list (karar #103).
const String _where = 'session.favorites';

class SenseFavoritesList extends StatefulWidget {
  const SenseFavoritesList({
    super.key,
    required this.model,
    this.onNotify,
    this.onClose,
    this.maxHeight,
  });

  final SenseFavoritesModel model;

  /// Short notification (T7 toast). The model's own results go to `model.onNotice`.
  final ValueChanged<String>? onNotify;

  /// Closes the list after a shortcut ran (the prototype closes it).
  final VoidCallback? onClose;

  /// Room down to the bottom of the window.
  final double? maxHeight;

  @override
  State<SenseFavoritesList> createState() => _SenseFavoritesListState();
}

class _SenseFavoritesListState extends State<SenseFavoritesList> {
  final _scroll = ScrollController();
  final _query = TextEditingController();
  SenseFavGroup? _openGroup;
  String? _ask;
  String? _pane;
  String? _keyPick;
  bool _form = false;

  SenseFavoritesModel get _m => widget.model;

  @override
  void initState() {
    super.initState();
    // The window whose list was opened last takes the hotkeys.
    SenseFavoritesHotkeys.activate(_m);
    _m.onNotice ??= widget.onNotify;
    if (!_m.loaded && !_m.loading && _m.os != null) _m.load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  void _notify(String m) => widget.onNotify?.call(m);

  void _resetSteps() {
    _ask = null;
    _pane = null;
    _keyPick = null;
  }

  void _tap(SenseFavItem it) {
    if (!_m.inputAllowed) return;
    if (it.pending) {
      _notify(SenseFavoritesStrings.pendingRun(it.name));
      return;
    }
    if (it.ask != null) {
      setState(() {
        _resetSteps();
        _ask = it.id;
      });
      return;
    }
    if (it.pane != SenseFavPane.none) {
      final open = _pane != it.id;
      setState(() {
        _resetSteps();
        _pane = open ? it.id : null;
      });
      if (open) {
        senseUiButton('fav.${it.id}', where: _where);
        _m.opened(it.id);
      }
      return;
    }
    _run(it.id);
  }

  void _run(String id) {
    senseUiButton('fav.$id', where: _where);
    setState(_resetSteps);
    _m.run(id);
    widget.onClose?.call();
  }

  bool _matches(SenseFavItem it, String q) {
    if (q.isEmpty) return true;
    return _lower('${it.name} ${it.description}').contains(q);
  }

  /// Turkish lower case for the search (İ → i, I → ı).
  static String _lower(String s) => s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _m,
      builder: (context, _) {
        final os = _m.os;
        final chip = os == SenseFavOs.linux ? SenseFavoritesStrings.linuxChip : SenseFavoritesStrings.count(_m.mine.length);
        return Container(
          key: const ValueKey('sense-favorites-list'),
          width: kSenseListWidth,
          constraints: BoxConstraints(maxHeight: widget.maxHeight ?? double.infinity),
          decoration: BoxDecoration(
            color: SenseColors.surface,
            border: const Border(
              left: BorderSide(color: SenseColors.line),
              right: BorderSide(color: SenseColors.line),
              bottom: BorderSide(color: SenseColors.line),
            ),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(kSenseListRadius)),
            boxShadow: [BoxShadow(color: SenseColors.bg.withOpacity(0.7), blurRadius: 60, offset: const Offset(0, 24))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(chip: os == null ? null : chip),
              Flexible(
                child: SenseScrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _body(os),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _hint(String text, {double v = 8, Key? key}) => Padding(
        key: key,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: v),
        child: Text(text,
            textAlign: TextAlign.center,
            style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textDim)),
      );

  Widget _osLabel(SenseFavOs os) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            key: const ValueKey('sense-fav-os'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: SenseColors.raised,
              border: Border.all(color: SenseColors.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(os.headerLabel,
                style: SenseTextStyles.of(size: SenseFontSize.hintSmall, weight: SenseFontWeight.bold)),
          ),
        ),
      );

  Widget _footer() => Container(
        key: const ValueKey('sense-fav-footer'),
        margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        padding: const EdgeInsets.only(top: 8),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: SenseColors.line))),
        child: Text(_m.accountSaves ? SenseFavoritesStrings.footer : SenseFavoritesStrings.footerLocal,
            style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim, height: 1.45)),
      );

  Widget _body(SenseFavOs? os) {
    if (os == null) {
      return _hint(SenseFavoritesStrings.osWaiting, v: 22, key: const ValueKey('sense-fav-os-waiting'));
    }
    if (os == SenseFavOs.linux) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        _osLabel(os),
        _hint(SenseFavoritesStrings.linuxLater, v: 22, key: const ValueKey('sense-fav-linux')),
        _footer(),
      ]);
    }
    final passive = !_m.inputAllowed;
    final q = _lower(_query.text.trim());
    final mine = _m.mine;
    final recent = _m.recent;
    final mineIds = {for (final it in mine) it.id};
    // A recent row that is not in Kısayollarım shows its question / pane under the chips.
    SenseFavItem? recentExtra;
    for (final it in recent) {
      if (!mineIds.contains(it.id) && (it.id == _ask || it.id == _pane)) recentExtra = it;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      _osLabel(os),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
        child: SenseFavField(
          key: const ValueKey('sense-fav-search'),
          controller: _query,
          hint: SenseFavoritesStrings.searchHint,
          maxLength: 60,
          onChanged: (_) => setState(() {}),
        ),
      ),
      const SenseFavSectionTitle(SenseFavoritesStrings.mine),
      Container(
        key: const ValueKey('sense-fav-mine'),
        margin: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        decoration: BoxDecoration(
          color: SenseColors.bg,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
        ),
        child: _m.loading && mine.isEmpty
            ? _hint(SenseFavoritesStrings.loading)
            : mine.isEmpty
                ? _hint(SenseFavoritesStrings.mineEmpty, key: const ValueKey('sense-fav-mine-empty'))
                : _mineList(mine, passive),
      ),
      if (passive)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
          child: Text(SenseFavoritesStrings.needsInput,
              key: const ValueKey('sense-fav-passive'),
              style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.warn)),
        ),
      if (recent.isNotEmpty) ...[
        const SenseFavSectionTitle(SenseFavoritesStrings.recent, top: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final it in recent) SenseFavRecentChip(item: it, passive: passive, onTap: () => _tap(it)),
          ]),
        ),
        if (recentExtra != null) _extras(recentExtra),
      ],
      const SenseFavSectionTitle(SenseFavoritesStrings.addable, top: 12),
      ..._catalog(q),
      _footer(),
    ]);
  }

  /// The question, key slots and pane under a row.
  Widget _extras(SenseFavItem it) {
    if (_ask == it.id && it.ask != null) {
      return SenseFavAskRow(
        ask: it.ask!,
        onCancel: () => setState(() => _ask = null),
        onConfirm: () => _run(it.id),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_keyPick == it.id)
        SenseFavKeyPicker(
          current: _m.keyOf(it.id),
          label: _m.keyLabel,
          onPick: (n) {
            senseUiSetting('fav.key.${it.id}', _m.keyOf(it.id), n, where: _where);
            _m.setKey(it.id, n);
            setState(() => _keyPick = null);
          },
        ),
      if (_pane == it.id) _paneOf(it),
    ]);
  }

  Widget _paneOf(SenseFavItem it) => switch (it.pane) {
        // Sürüm 12 (#171): the Host answers with its own values (`res`).
        SenseFavPane.ip => SenseFavHostIpPane(
            fallback: _m.ipInfo?.call() ?? const SenseFavIpInfo(),
            load: () => _m.hostIpInfo(it.id),
          ),
        SenseFavPane.ping => SenseFavPingPane(onPing: (a) => _m.ping(it.id, a)),
        SenseFavPane.windows => SenseFavWindowsPane(
            load: () => _m.windows(it.id),
            close: (w) => _m.closeWindow(it.id, w),
            mac: _m.os == SenseFavOs.mac,
          ),
        SenseFavPane.none => const SizedBox.shrink(),
      };

  Widget _mineList(List<SenseFavItem> mine, bool passive) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: mine.length,
      proxyDecorator: (child, _, __) => Opacity(opacity: 0.6, child: child),
      onReorder: (from, to) {
        senseUiSetting('fav.order', from, to, where: _where);
        _m.reorder(from, to);
      },
      itemBuilder: (context, i) {
        final it = mine[i];
        if (_ask == it.id && it.ask != null) {
          return KeyedSubtree(key: ValueKey('sense-fav-mine-${it.id}'), child: _extras(it));
        }
        final k = _m.keyOf(it.id);
        return Column(
          key: ValueKey('sense-fav-mine-${it.id}'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SenseFavMineRow(
              item: it,
              index: i,
              keyLabel: k == null ? null : _m.keyLabel(k),
              passive: passive,
              paneOpen: _pane == it.id,
              onRun: () => _tap(it),
              onKeyTap: () => setState(() {
                final open = _keyPick != it.id;
                _resetSteps();
                _keyPick = open ? it.id : null;
              }),
            ),
            _extras(it),
          ],
        );
      },
    );
  }

  List<Widget> _catalog(String q) {
    final all = _m.all;
    final out = <Widget>[];
    for (final g in kSenseFavGroupOrder) {
      final rows = [for (final it in all) if (it.group == g && _matches(it, q)) it];
      final custom = g == SenseFavGroup.custom;
      // An empty group is left out; Özel kısayollar stays for its form (unless searching).
      if (rows.isEmpty && (!custom || q.isNotEmpty)) continue;
      final open = q.isNotEmpty || _openGroup == g;
      final chosen = [for (final it in all) if (it.group == g && _m.isChosen(it.id)) it].length;
      out.add(SenseFavGroupBox(
        key: ValueKey('sense-fav-g-${g.name}'),
        group: g,
        open: open,
        chosenCount: chosen,
        count: rows.length,
        onToggle: () => setState(() => _openGroup = _openGroup == g ? null : g),
        children: [
          for (final it in rows)
            SenseFavCatalogRow(
              item: it,
              chosen: _m.isChosen(it.id),
              onToggle: () {
                senseUiSetting('fav.pick.${it.id}', _m.isChosen(it.id), !_m.isChosen(it.id), where: _where);
                _m.toggle(it.id);
              },
            ),
          if (custom)
            _form
                ? SenseFavCustomFormView(
                    os: _m.os ?? SenseFavOs.win,
                    onCancel: () => setState(() => _form = false),
                    onSubmit: (f) async {
                      final err = await _m.requestCustom(f);
                      if (err == null && mounted) setState(() => _form = false);
                      return err;
                    },
                  )
                : SenseFavAddLine(onTap: () => setState(() {
                      _form = true;
                      _openGroup = SenseFavGroup.custom;
                    })),
        ],
      ));
    }
    if (out.isEmpty) out.add(_hint(SenseFavoritesStrings.noMatch, key: const ValueKey('sense-fav-no-match')));
    return out;
  }
}

class _Header extends StatelessWidget {
  const _Header({this.chip});
  final String? chip;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        decoration: const BoxDecoration(
          color: SenseColors.surface,
          border: Border(bottom: BorderSide(color: SenseColors.line)),
        ),
        child: Row(children: [
          Expanded(
            child: Text(SenseFavoritesStrings.title,
                style: SenseTextStyles.of(size: SenseFontSize.popupTitle, weight: SenseFontWeight.bold)),
          ),
          if (chip != null) SenseStateChip(key: const ValueKey('sense-fav-count'), label: chip!),
        ]),
      );
}

/// The bar button of the list (fifth list, after Eylemler). [compact]: a narrow window
/// (#167) shows a star with the tooltip "Sık kullanılanlar" instead of the name, so it
/// never reads like Klavye › Kısayollar. The ▾ shows at every width (FO-B9).
class SenseFavoritesButton extends StatelessWidget {
  const SenseFavoritesButton({super.key, required this.compact, this.open = false, this.onTap});

  final bool compact;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SenseInteractive(
      key: const ValueKey('sense-bar-menu-favorites'),
      onTap: onTap,
      semanticLabel: SenseFavoritesStrings.title,
      tooltip: compact ? SenseFavoritesStrings.starTooltip : null,
      selected: open,
      builder: (context, s) {
        final fg = open || s.hovered ? SenseColors.text : SenseColors.textSecondary;
        return Container(
          height: SenseSizes.sessionToolbarHeight,
          padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 10),
          color: open ? SenseColors.raised : (s.hovered ? SenseColors.hover : null),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (compact)
              Icon(Icons.star_rounded,
                  key: const ValueKey('sense-fav-star'), size: SenseFontSize.categoryTitle + 2, color: fg)
            else
              Text(SenseFavoritesStrings.title,
                  maxLines: 1, style: SenseTextStyles.of(weight: SenseFontWeight.medium, color: fg)),
            const SizedBox(width: 6),
            const SenseCaret(direction: SenseCaretDirection.down, size: 10, small: true),
          ]),
        );
      },
    );
  }
}

/// Ctrl+Alt+Shift+1–9 (Mac: Cmd+Option+Shift+1–9) run the shortcut in that slot (K4, #71).
/// The key handler of the session calls [handle] with every key-down before it goes to
/// the remote computer; true = used here, do not send it on. The Rust shortcut matcher may
/// send `sense_fav_<n>` instead ([handleAction]).
abstract final class SenseFavoritesHotkeys {
  /// Action id prefix for the matcher (`sense_fav_1` … `sense_fav_9`).
  static const String actionPrefix = 'sense_fav_';

  /// Tests set the Controller's system here; null = the real one.
  @visibleForTesting
  static bool? macOverride;

  static bool get _mac => macOverride ?? defaultTargetPlatform == TargetPlatform.macOS;

  /// The session window in front takes the keys.
  static void activate(SenseFavoritesModel m) => SenseFavoritesHotkeysRegistry.active = m;

  static void deactivate(SenseFavoritesModel m) {
    if (identical(SenseFavoritesHotkeysRegistry.active, m)) SenseFavoritesHotkeysRegistry.active = null;
  }

  // Not const: PhysicalKeyboardKey has no primitive equality.
  static final Map<PhysicalKeyboardKey, int> _digits = {
    PhysicalKeyboardKey.digit1: 1,
    PhysicalKeyboardKey.digit2: 2,
    PhysicalKeyboardKey.digit3: 3,
    PhysicalKeyboardKey.digit4: 4,
    PhysicalKeyboardKey.digit5: 5,
    PhysicalKeyboardKey.digit6: 6,
    PhysicalKeyboardKey.digit7: 7,
    PhysicalKeyboardKey.digit8: 8,
    PhysicalKeyboardKey.digit9: 9,
    PhysicalKeyboardKey.numpad1: 1,
    PhysicalKeyboardKey.numpad2: 2,
    PhysicalKeyboardKey.numpad3: 3,
    PhysicalKeyboardKey.numpad4: 4,
    PhysicalKeyboardKey.numpad5: 5,
    PhysicalKeyboardKey.numpad6: 6,
    PhysicalKeyboardKey.numpad7: 7,
    PhysicalKeyboardKey.numpad8: 8,
    PhysicalKeyboardKey.numpad9: 9,
  };

  /// The slot of a key with its modifiers, or null. Windows: Ctrl+Alt+Shift without Win;
  /// Mac: Cmd+Option+Shift without Ctrl. The physical key, so Shift's "!" still counts.
  static int? slotFor(PhysicalKeyboardKey key,
      {required bool ctrl, required bool alt, required bool shift, required bool meta, required bool mac}) {
    final n = _digits[key];
    if (n == null || !alt || !shift) return null;
    final primary = mac ? meta && !ctrl : ctrl && !meta;
    return primary ? n : null;
  }

  /// A key event from the session's key handler.
  static bool handle(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final hk = HardwareKeyboard.instance;
    final n = slotFor(e.physicalKey,
        ctrl: hk.isControlPressed,
        alt: hk.isAltPressed,
        shift: hk.isShiftPressed,
        meta: hk.isMetaPressed,
        mac: _mac);
    if (n == null) return false;
    return SenseFavoritesHotkeysRegistry.active?.runSlot(n) ?? false;
  }

  /// A matcher action (`sense_fav_<n>`); false when it is not one of ours or the slot is empty.
  static bool handleAction(String action) {
    if (!action.startsWith(actionPrefix)) return false;
    final n = int.tryParse(action.substring(actionPrefix.length));
    if (n == null || n < 1 || n > 9) return false;
    return SenseFavoritesHotkeysRegistry.active?.runSlot(n) ?? false;
  }
}
