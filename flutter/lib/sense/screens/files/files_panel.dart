// Sense Remote (#155): one side of the remote files window — "Bu bilgisayar" or the
// remote computer. Prototype `.fmp`: header (name + system tag), path row (Geri, Bir üst
// klasör, Yenile, breadcrumb), columns, 34 px rows (selected = hover + lineStrong +
// white inset edge), empty / error / loading states and the footer.
//
// Data and actions are the stock FileController (no Rust change). Kept from the stock
// view (UZ §5, "C" items): Ctrl / Shift multi-select, keyboard navigation (arrows, page,
// Home/End, Enter, Ctrl+A, type-ahead), sort by column, typed path, new folder, rename,
// delete, show hidden files, select / unselect all, search in the folder, home folder,
// drag and drop (between the panels, and from the desktop onto the remote panel).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../desktop/pages/file_manager_page.dart' show navigateSelection, pageDelta;
import '../../../models/file_model.dart';
import '../../sense.dart';
import '../../strings/files.dart';
import '../shared/aux_window/aux_menu.dart';
import 'files_format.dart';

/// Row height and list padding (`.fmr`, `.fmlist`).
const double kSenseFileRowHeight = 34;
const double _kListPadV = 4, _kListPadH = 6;
const double _kColIcon = 22, _kColSize = 84, _kColDate = 118, _kColGap = 10;
const double _kIconButton = 30;

/// What is dragged from one panel to the other.
class SenseFilesDrag {
  const SenseFilesDrag({required this.fromRemote, required this.count});

  final bool fromRemote;
  final int count;
}

class SenseFilesPanel extends StatefulWidget {
  const SenseFilesPanel({
    super.key,
    required this.controller,
    required this.isRemote,
    required this.title,
    required this.tag,
    this.connected = true,
    this.onSelectionStart,
    this.onDropFromOther,
    this.doubleClickMs = 300,
    this.windows = false,
  });

  final FileController controller;
  final bool isRemote;

  /// "Bu bilgisayar" or the remote computer's name.
  final String title;

  /// "Windows · uzak".
  final String tag;

  /// False while the remote side is not connected yet: "Bağlanıyor" state.
  final bool connected;

  /// The person started selecting here: the other panel drops its selection.
  final VoidCallback? onSelectionStart;

  /// Files dragged from the other panel were dropped here.
  final VoidCallback? onDropFromOther;

  /// System double-click time (stock `bind.getDoubleClickTime()`).
  final int doubleClickMs;

  /// Paths of this side are Windows paths (breadcrumb).
  final bool windows;

  @override
  State<SenseFilesPanel> createState() => SenseFilesPanelState();
}

class SenseFilesPanelState extends State<SenseFilesPanel> {
  final _focus = FocusNode(debugLabel: 'sense-files-list');
  final _scroll = ScrollController();
  final _pathText = TextEditingController();
  final _pathFocus = FocusNode(debugLabel: 'sense-files-path');
  final _folderText = TextEditingController();
  final _folderFocus = FocusNode(debugLabel: 'sense-files-new-folder');

  bool _editingPath = false;
  bool _searching = false;
  String _filter = '';
  final _searchText = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'sense-files-search');
  bool _creating = false;
  bool _dropHover = false;
  String? _folderError;
  int _anchor = -1;
  String? _cursorPath;
  int _lastClick = 0;
  String? _lastClickPath;
  String _typed = '';
  int _typedAt = 0;

  FileController get c => widget.controller;
  SelectedItems get _sel => c.selectedItems;
  String get _side => widget.isRemote ? 'remote' : 'local';

  @override
  void initState() {
    super.initState();
    _pathFocus.addListener(() {
      if (!_pathFocus.hasFocus && _editingPath) setState(() => _editingPath = false);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    _pathText.dispose();
    _pathFocus.dispose();
    _folderText.dispose();
    _folderFocus.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Entries shown: all, or those whose name contains the search text (stock search).
  List<Entry> _visible(List<Entry> all) {
    final f = _filter.trim().toLowerCase();
    if (f.isEmpty) return all;
    return all.where((e) => e.name.toLowerCase().contains(f)).toList(growable: false);
  }

  void startSearch() {
    setState(() {
      _searching = true;
      _editingPath = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _endSearch() {
    _searchText.clear();
    setState(() {
      _searching = false;
      _filter = '';
    });
    _focus.requestFocus();
  }

  // ---- selection ----

  void _select(List<Entry> entries, int i) {
    widget.onSelectionStart?.call();
    final e = entries[i];
    final kb = HardwareKeyboard.instance;
    if (kb.isShiftPressed && _anchor >= 0 && _anchor < entries.length) {
      final a = math.min(_anchor, i), b = math.max(_anchor, i);
      _sel.items.assignAll(entries.sublist(a, b + 1).where((x) => !x.isDrive));
    } else if (kb.isControlPressed || kb.isMetaPressed) {
      _sel.items.contains(e) ? _sel.remove(e) : _sel.add(e);
      _anchor = i;
    } else {
      _sel.items.assignAll([if (!e.isDrive) e]);
      _anchor = i;
    }
    _cursorPath = e.path;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastClickPath == e.path && now - _lastClick < widget.doubleClickMs) {
      _lastClick = 0;
      _open(e);
    } else {
      _lastClick = now;
      _lastClickPath = e.path;
    }
    _focus.requestFocus();
    setState(() {});
  }

  void _open(Entry e) {
    if (e.isFile) return;
    if (_searching) {
      _searchText.clear();
      _searching = false;
      _filter = '';
    }
    _sel.clear();
    _anchor = -1;
    _cursorPath = null;
    c.openDirectory(e.path);
  }

  void selectAll() {
    widget.onSelectionStart?.call();
    _sel.selectAll(_visible(c.directory.value.entries).where((e) => !e.isDrive).toList());
    setState(() {});
  }

  void unselectAll() {
    _sel.clear();
    _anchor = -1;
    setState(() {});
  }

  // ---- keyboard (stock bindings kept) ----

  void _move(int delta, bool extend) {
    final entries = _visible(c.directory.value.entries);
    final next = navigateSelection(entries, _sel.items, delta, extend);
    if (next.isEmpty) return;
    widget.onSelectionStart?.call();
    _sel.items.assignAll(next.where((e) => !e.isDrive));
    _cursorPath = next.last.path;
    _anchor = entries.indexOf(next.first);
    _reveal(entries.indexOf(next.last));
    setState(() {});
  }

  int _pageDelta(bool down) {
    final entries = _visible(c.directory.value.entries);
    final index = _sel.items.isEmpty ? -1 : entries.indexOf(_sel.items.last);
    if (!_scroll.hasClients) return down ? 1 : -1;
    final p = _scroll.position;
    final first = ((p.pixels - _kListPadV) / kSenseFileRowHeight).ceil();
    final last = ((p.pixels + p.viewportDimension - _kListPadV) / kSenseFileRowHeight).floor() - 1;
    return pageDelta(index >= 0 ? index : (down ? -1 : entries.length), first, last, down);
  }

  void _reveal(int index) {
    if (index < 0 || !_scroll.hasClients) return;
    final p = _scroll.position;
    final top = _kListPadV + index * kSenseFileRowHeight;
    final bottom = top + kSenseFileRowHeight;
    if (top < p.pixels) {
      _scroll.jumpTo(top);
    } else if (bottom > p.pixels + p.viewportDimension) {
      _scroll.jumpTo(math.min(p.maxScrollExtent, bottom - p.viewportDimension));
    }
  }

  void _openSelected() {
    final items = _sel.items;
    if (items.length == 1 && !items.first.isFile) {
      _open(items.first);
      return;
    }
    // A drive has no selection; Enter opens the row under the cursor.
    final cur = c.directory.value.entries.firstWhereOrNull((e) => e.path == _cursorPath);
    if (items.isEmpty && cur != null && cur.isDrive) _open(cur);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    final kb = HardwareKeyboard.instance;
    final shift = kb.isShiftPressed;
    final all = _visible(c.directory.value.entries).length;
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1, shift);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _move(1, shift);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _move(_pageDelta(false), shift);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _move(_pageDelta(true), shift);
    } else if (k == LogicalKeyboardKey.home) {
      _move(-all, shift);
    } else if (k == LogicalKeyboardKey.end) {
      _move(all, shift);
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _openSelected();
    } else if (k == LogicalKeyboardKey.keyA && (kb.isControlPressed || kb.isMetaPressed)) {
      selectAll();
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      // Stock: swallowed, so focus does not jump to the other panel.
    } else {
      final ch = event.character;
      if (ch == null || ch.trim().isEmpty || kb.isControlPressed || kb.isMetaPressed || kb.isAltPressed) {
        return KeyEventResult.ignored;
      }
      _typeAhead(ch.toLowerCase());
    }
    return KeyEventResult.handled;
  }

  /// Stock type-ahead: letters typed within a second jump to the first match.
  void _typeAhead(String ch) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _typed = now - _typedAt > 1000 ? ch : '$_typed$ch';
    _typedAt = now;
    final entries = _visible(c.directory.value.entries);
    final i = entries.indexWhere((e) => e.name.toLowerCase().startsWith(_typed));
    if (i < 0) return;
    widget.onSelectionStart?.call();
    _sel.items.assignAll([if (!entries[i].isDrive) entries[i]]);
    _cursorPath = entries[i].path;
    _anchor = i;
    _reveal(i);
    setState(() {});
  }

  // ---- actions ----

  void _startPath() {
    _pathText.text = c.directory.value.path;
    _pathText.selection = TextSelection(baseOffset: 0, extentOffset: _pathText.text.length);
    setState(() => _editingPath = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pathFocus.requestFocus();
    });
  }

  void _submitPath(String v) {
    setState(() => _editingPath = false);
    final p = v.trim();
    if (p.isNotEmpty) c.openDirectory(p);
  }

  void startNewFolder() {
    _folderText.clear();
    setState(() {
      _creating = true;
      _folderError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _folderFocus.requestFocus();
    });
  }

  void _createFolder() {
    final name = _folderText.text.trim();
    if (name.isEmpty) {
      setState(() => _creating = false);
      return;
    }
    final win = c.options.value.isWindows;
    if (!PathUtil.validName(name, win)) {
      setState(() => _folderError = SenseFilesStrings.invalidName);
      return;
    }
    c.createDir(PathUtil.join(c.directory.value.path, name, win));
    setState(() => _creating = false);
  }

  void _sort(SortBy by) {
    final asc = c.sortBy.value == by ? !c.sortAscending : true;
    c.changeSortStyle(by, ascending: asc);
    setState(() {});
  }

  void _toggleHidden() => c.toggleShowHidden();

  List<SenseAuxMenuItem> menuItems() {
    final selected = _sel.items.toList();
    final dir = c.directory.value;
    final canWrite = dir.path.isNotEmpty && !(widget.windows && dir.path == '/');
    return [
      SenseAuxMenuItem(
          key: Key('sense-files-$_side-menu-new'),
          label: SenseFilesStrings.newFolder,
          onTap: canWrite ? startNewFolder : null),
      SenseAuxMenuItem(
          key: Key('sense-files-$_side-menu-rename'),
          label: SenseFilesStrings.rename,
          onTap: selected.length == 1 ? () => c.renameAction(selected.single, c.isLocal) : null),
      SenseAuxMenuItem(
          key: Key('sense-files-$_side-menu-delete'),
          label: SenseFilesStrings.delete,
          danger: true,
          onTap: selected.isNotEmpty ? () => c.removeAction(_sel) : null),
      SenseAuxMenuItem(
          key: Key('sense-files-$_side-menu-hidden'),
          label: c.options.value.showHidden ? SenseFilesStrings.hideHidden : SenseFilesStrings.showHidden,
          onTap: _toggleHidden),
      SenseAuxMenuItem(label: SenseFilesStrings.selectAll, onTap: dir.entries.isEmpty ? null : selectAll),
      SenseAuxMenuItem(label: SenseFilesStrings.unselectAll, onTap: selected.isEmpty ? null : unselectAll),
      SenseAuxMenuItem(label: SenseFilesStrings.sortName, onTap: () => _sort(SortBy.name)),
      SenseAuxMenuItem(label: SenseFilesStrings.sortSize, onTap: () => _sort(SortBy.size)),
      SenseAuxMenuItem(label: SenseFilesStrings.sortModified, onTap: () => _sort(SortBy.modified)),
      SenseAuxMenuItem(label: SenseFilesStrings.typePath, onTap: _startPath),
      SenseAuxMenuItem(
          key: Key('sense-files-$_side-menu-search'), label: SenseFilesStrings.search, onTap: startSearch),
      SenseAuxMenuItem(label: SenseFilesStrings.home, onTap: c.goToHomeDirectory),
    ];
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final panel = Obx(() {
      final dir = c.directory.value;
      final entries = _visible(dir.entries);
      final selected = _sel.items.toList();
      final loading = c.loading.value;
      final error = c.readError.value;
      final canBack = c.history.isNotEmpty;
      final waiting = widget.isRemote && !widget.connected;
      Widget body;
      if (waiting || (loading && entries.isEmpty && error == null)) {
        body = _State(
          key: Key('sense-files-$_side-loading'),
          icon: null,
          title: waiting ? SenseAuxStrings.connecting : SenseFilesStrings.loading,
        );
      } else if (error != null) {
        body = _errorState(error, dir.path);
      } else if (entries.isEmpty && dir.path.isNotEmpty) {
        body = _State(
          key: Key('sense-files-$_side-empty'),
          icon: Icons.folder_outlined,
          title: SenseFilesStrings.emptyTitle,
          body: widget.isRemote ? SenseFilesStrings.emptyRemote : SenseFilesStrings.emptyLocal,
        );
      } else {
        body = _list(entries, selected);
      }
      return Container(
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: _dropHover ? SenseColors.text : SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.popup),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(loading && entries.isNotEmpty),
          _pathRow(dir, canBack),
          if (_creating) _newFolderRow(),
          Expanded(child: body),
          _footer(entries, selected, error == null && !waiting),
        ]),
      );
    });
    return DragTarget<SenseFilesDrag>(
      onWillAcceptWithDetails: (d) {
        final ok = d.data.fromRemote != widget.isRemote && widget.connected;
        if (ok != _dropHover) setState(() => _dropHover = ok);
        return ok;
      },
      onLeave: (_) => setState(() => _dropHover = false),
      onAcceptWithDetails: (_) {
        setState(() => _dropHover = false);
        widget.onDropFromOther?.call();
      },
      builder: (context, _, __) => Semantics(container: true, label: widget.title, child: panel),
    );
  }

  Widget _header(bool busy) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(children: [
        Flexible(
          child: Text(widget.title,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: SenseTextStyles.categoryTitle),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: SenseColors.raised,
            border: Border.all(color: SenseColors.line),
            borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
          ),
          child: Text(widget.tag,
              maxLines: 1, style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textSecondary)),
        ),
        const Spacer(),
        if (busy) const SenseSpinner(size: 12),
      ]),
    );
  }

  Widget _iconButton(String key, IconData icon, String tip, VoidCallback? onTap) {
    return SenseInteractive(
      key: Key('sense-files-$_side-$key'),
      onTap: onTap,
      tooltip: tip,
      semanticLabel: tip,
      builder: (context, s) => Container(
        width: _kIconButton,
        height: _kIconButton,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: s.hovered ? SenseColors.hover : SenseColors.bg,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.button),
        ),
        child: Icon(icon, size: 15, color: s.enabled ? SenseColors.text : SenseColors.textDim),
      ),
    );
  }

  Widget _pathRow(FileDirectory dir, bool canBack) {
    final crumbs = senseCrumbs(dir.path, windows: widget.windows);
    final rootLabel = widget.isRemote ? SenseFilesStrings.drives : SenseFilesStrings.thisComputer;
    final crumbStyle = SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textSecondary);
    final lastStyle =
        SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.medium, color: SenseColors.text);
    Widget crumb(String label, String path, bool last) => SenseInteractive(
          onTap: () => c.openDirectory(path),
          builder: (context, s) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: s.hovered ? SenseColors.hover : null,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(label, maxLines: 1, style: last ? lastStyle : crumbStyle),
          ),
        );
    final sep = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text('›', style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textDim)),
    );
    final Widget field = _searching
        ? Focus(
            onKeyEvent: (_, e) {
              if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                _endSearch();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              key: Key('sense-files-$_side-search-field'),
              controller: _searchText,
              focusNode: _searchFocus,
              style: SenseTextStyles.of(size: SenseFontSize.bodySmall),
              cursorColor: SenseColors.text,
              decoration: const InputDecoration.collapsed(hintText: SenseFilesStrings.searchHint),
              onChanged: (v) => setState(() => _filter = v),
            ),
          )
        : _editingPath
        ? TextField(
            key: Key('sense-files-$_side-path-field'),
            controller: _pathText,
            focusNode: _pathFocus,
            style: SenseTextStyles.of(size: SenseFontSize.bodySmall),
            cursorColor: SenseColors.text,
            decoration: const InputDecoration.collapsed(hintText: SenseFilesStrings.pathHint),
            onSubmitted: _submitPath,
          )
        : GestureDetector(
            key: Key('sense-files-$_side-crumbs'),
            behavior: HitTestBehavior.opaque,
            onDoubleTap: _startPath,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(children: [
                // The first crumb: "Bu bilgisayar" / "Sürücüler" = the root (drives on Windows).
                crumb(rootLabel, '/', crumbs.isEmpty),
                for (var i = 0; i < crumbs.length; i++) ...[
                  sep,
                  crumb(crumbs[i].$1, crumbs[i].$2, i == crumbs.length - 1),
                ],
              ]),
            ),
          );
    final parentOk = dir.path.isNotEmpty && dir.path != '/';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(children: [
        _iconButton('back', Icons.arrow_back_ios_new_rounded, SenseFilesStrings.back, canBack ? c.goBack : null),
        const SizedBox(width: 4),
        _iconButton('up', Icons.arrow_upward_rounded, SenseFilesStrings.up, parentOk ? c.goToParentDirectory : null),
        const SizedBox(width: 4),
        _iconButton('refresh', Icons.refresh_rounded, SenseFilesStrings.refresh, () {
          c.readError.value = null;
          c.refresh();
        }),
        const SizedBox(width: 4),
        Expanded(
          child: Container(
            height: _kIconButton,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: SenseColors.bg,
              border: Border.all(color: _editingPath || _searching ? SenseColors.lineStrong : SenseColors.line),
              borderRadius: BorderRadius.circular(SenseRadii.button),
            ),
            child: field,
          ),
        ),
        const SizedBox(width: 4),
        Builder(
          builder: (ctx) => _iconButton('more', Icons.more_horiz_rounded, SenseFilesStrings.more,
              () => senseAuxMenuShowBelow(ctx, menuItems())),
        ),
      ]),
    );
  }

  Widget _newFolderRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Container(
              height: _kIconButton,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: SenseColors.bg,
                border: Border.all(color: _folderError == null ? SenseColors.lineStrong : SenseColors.warn),
                borderRadius: BorderRadius.circular(SenseRadii.button),
              ),
              child: Focus(
                onKeyEvent: (_, e) {
                  if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                    setState(() => _creating = false);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  key: Key('sense-files-$_side-folder-field'),
                  controller: _folderText,
                  focusNode: _folderFocus,
                  style: SenseTextStyles.of(size: SenseFontSize.bodySmall),
                  cursorColor: SenseColors.text,
                  decoration: const InputDecoration.collapsed(hintText: SenseFilesStrings.newFolderHint),
                  onChanged: (_) {
                    if (_folderError != null) setState(() => _folderError = null);
                  },
                  onSubmitted: (_) => _createFolder(),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SenseButton(
            key: Key('sense-files-$_side-folder-cancel'),
            label: SenseCommonStrings.cancel,
            size: SenseButtonSize.small,
            onPressed: () => setState(() => _creating = false),
          ),
          const SizedBox(width: 6),
          SenseButton(
            key: Key('sense-files-$_side-folder-create'),
            label: SenseFilesStrings.create,
            size: SenseButtonSize.small,
            kind: SenseButtonKind.primary,
            onPressed: _createFolder,
          ),
        ]),
        if (_folderError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_folderError!, style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.warn)),
          ),
      ]),
    );
  }

  Widget _columns() {
    Widget head(String label, SortBy by, {TextAlign align = TextAlign.left}) {
      final on = c.sortBy.value == by;
      return SenseInteractive(
        key: Key('sense-files-$_side-sort-${by.name}'),
        onTap: () => _sort(by),
        builder: (context, s) => Row(
          mainAxisAlignment: align == TextAlign.right ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Flexible(
              child: Text(senseUpperTr(label),
                  maxLines: 1,
                  style: SenseTextStyles.of(
                      size: SenseFontSize.caps,
                      weight: SenseFontWeight.medium,
                      color: on || s.hovered ? SenseColors.textMuted : SenseColors.textDim,
                      letterSpacingEm: SenseLetterSpacing.capsWide)),
            ),
            if (on) ...[
              const SizedBox(width: 2),
              Icon(c.sortAscending ? Icons.arrow_drop_up_rounded : Icons.arrow_drop_down_rounded,
                  size: 14, color: SenseColors.textMuted),
            ],
          ],
        ),
      );
    }

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SenseColors.line), bottom: BorderSide(color: SenseColors.line)),
      ),
      child: Row(children: [
        const SizedBox(width: _kColIcon + _kColGap),
        Expanded(child: head(SenseFilesStrings.colName, SortBy.name)),
        const SizedBox(width: _kColGap),
        SizedBox(width: _kColSize, child: head(SenseFilesStrings.colSize, SortBy.size, align: TextAlign.right)),
        const SizedBox(width: _kColGap),
        SizedBox(width: _kColDate, child: head(SenseFilesStrings.colModified, SortBy.modified)),
      ]),
    );
  }

  Widget _list(List<Entry> entries, List<Entry> selected) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _columns(),
      Expanded(
        child: Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: SenseScrollbar(
            controller: _scroll,
            child: ListView.builder(
              key: Key('sense-files-$_side-list'),
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: _kListPadV, horizontal: _kListPadH),
              itemExtent: kSenseFileRowHeight,
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                final on = selected.contains(e) || (e.isDrive && e.path == _cursorPath);
                return _row(entries, i, on, selected.length);
              },
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _row(List<Entry> entries, int i, bool on, int selectedCount) {
    final e = entries[i];
    final row = SenseFileRow(
      key: Key('sense-files-$_side-row-${e.name}'),
      entry: e,
      selected: on,
      onTap: () => _select(entries, i),
      onSecondaryTap: (pos) {
        if (!_sel.items.contains(e) && !e.isDrive) {
          widget.onSelectionStart?.call();
          _sel.items.assignAll([e]);
          _anchor = i;
          setState(() {});
        }
        senseAuxMenuShow(context, pos, menuItems());
      },
    );
    if (!widget.connected || e.isDrive) return row;
    return Draggable<SenseFilesDrag>(
      data: SenseFilesDrag(fromRemote: widget.isRemote, count: on ? math.max(1, selectedCount) : 1),
      onDragStarted: () {
        if (!_sel.items.contains(e)) {
          widget.onSelectionStart?.call();
          _sel.items.assignAll([e]);
          _anchor = i;
          setState(() {});
        }
      },
      feedback: _DragChip(count: on ? math.max(1, selectedCount) : 1),
      child: row,
    );
  }

  Widget _errorState(SenseDirError error, String currentPath) {
    final path = c.readErrorPath.isEmpty ? SenseFilesStrings.drives : c.readErrorPath;
    final text = switch (error) {
      SenseDirError.denied => SenseFilesStrings.errorDenied(path),
      SenseDirError.timeout => SenseFilesStrings.errorTimeout,
      SenseDirError.unreadable => SenseFilesStrings.errorUnreadable,
      SenseDirError.other => SenseFilesStrings.errorOther,
    };
    return _State(
      key: Key('sense-files-$_side-error'),
      icon: Icons.warning_amber_rounded,
      warn: true,
      title: SenseFilesStrings.errorTitle,
      body: text,
      actions: [
        SenseButton(
          key: Key('sense-files-$_side-error-retry'),
          label: SenseFilesStrings.retry,
          size: SenseButtonSize.small,
          onPressed: () => c.openDirectory(c.readErrorPath, isBack: true),
        ),
        SenseButton(
          key: Key('sense-files-$_side-error-up'),
          label: SenseFilesStrings.goUp,
          size: SenseButtonSize.small,
          onPressed: () {
            // The last good folder is still loaded; without one, go home.
            c.readError.value = null;
            if (currentPath.isEmpty) c.goToHomeDirectory();
          },
        ),
      ],
    );
  }

  Widget _footer(List<Entry> entries, List<Entry> selected, bool show) {
    final muted = SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted);
    final strong = SenseTextStyles.of(size: SenseFontSize.hint, weight: SenseFontWeight.medium);
    final size = selected.where((e) => e.isFile).fold<int>(0, (a, e) => a + e.size);
    return Container(
      key: Key('sense-files-$_side-footer'),
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: SenseColors.line))),
      child: !show || entries.isEmpty
          ? Text('—', style: muted)
          : Text.rich(
              TextSpan(children: [
                TextSpan(text: SenseFilesStrings.items(entries.length), style: muted),
                TextSpan(text: ' · ', style: muted),
                if (selected.isNotEmpty)
                  TextSpan(
                      text: SenseFilesStrings.selected(selected.length, size > 0 ? senseFileSize(size) : null),
                      style: strong)
                else
                  TextSpan(text: SenseFilesStrings.selectHint, style: muted),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
    );
  }
}

/// One row (`.fmr`): icon · name · size · modified.
class SenseFileRow extends StatelessWidget {
  const SenseFileRow({super.key, required this.entry, required this.selected, this.onTap, this.onSecondaryTap});

  final Entry entry;
  final bool selected;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final icon = e.isDrive
        ? Icons.storage_rounded
        : e.isFile
            ? Icons.insert_drive_file_outlined
            : Icons.folder_outlined;
    final small = SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted);
    return GestureDetector(
      onSecondaryTapUp: onSecondaryTap == null ? null : (d) => onSecondaryTap!(d.globalPosition),
      child: SenseInteractive(
        onTap: onTap,
        selected: selected,
        semanticLabel: e.name,
        tooltip: e.isFile ? null : SenseFilesStrings.openHint,
        mouseCursor: SystemMouseCursors.basic,
        builder: (context, s) => Container(
          decoration: BoxDecoration(
            color: selected || s.hovered ? SenseColors.hover : null,
            border: Border.all(color: selected ? SenseColors.lineStrong : Colors.transparent),
            borderRadius: BorderRadius.circular(SenseRadii.button),
          ),
          child: Stack(children: [
            if (selected)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  decoration: const BoxDecoration(
                    color: SenseColors.text,
                    borderRadius: BorderRadius.horizontal(left: Radius.circular(SenseRadii.button)),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: [
                SizedBox(
                  width: _kColIcon,
                  child: Icon(icon, size: 16, color: e.isFile ? SenseColors.textMuted : SenseColors.textSecondary),
                ),
                const SizedBox(width: _kColGap),
                Expanded(
                  child: Text(e.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: SenseTextStyles.body),
                ),
                const SizedBox(width: _kColGap),
                SizedBox(
                  width: _kColSize,
                  child: Text(e.isFile ? senseFileSize(e.size) : '',
                      maxLines: 1, textAlign: TextAlign.right, style: small),
                ),
                const SizedBox(width: _kColGap),
                SizedBox(
                  width: _kColDate,
                  child: Text(senseEntryDate(e), maxLines: 1, overflow: TextOverflow.clip, style: small),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _DragChip extends StatelessWidget {
  const _DragChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: SenseColors.raised,
        border: Border.all(color: SenseColors.lineStrong),
        borderRadius: BorderRadius.circular(SenseRadii.button),
      ),
      child: Text(SenseFilesStrings.dragCount(count),
          style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.medium)),
    );
  }
}

/// Empty / error / loading content of a panel (`.fmempty`).
class _State extends StatelessWidget {
  const _State({super.key, required this.icon, required this.title, this.body, this.actions = const [], this.warn = false});

  final IconData? icon;
  final String title;
  final String? body;
  final List<Widget> actions;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (icon == null)
            const SenseSpinner(size: 22)
          else
            Icon(icon, size: 28, color: warn ? SenseColors.warn : SenseColors.textDim),
          const SizedBox(height: 10),
          Text(title,
              textAlign: TextAlign.center,
              style: SenseTextStyles.of(
                  size: SenseFontSize.categoryTitle,
                  weight: SenseFontWeight.bold,
                  color: warn ? SenseColors.warn : SenseColors.text)),
          if (body != null) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(body!,
                  textAlign: TextAlign.center,
                  style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted, height: 1.5)),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: actions),
          ],
        ]),
      ),
    );
  }
}
