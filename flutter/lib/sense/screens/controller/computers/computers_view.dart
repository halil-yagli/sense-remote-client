// Sense Remote: "Bilgisayarlar" of the Controller (YH C2; prototype `pcsView`;
// images a01, a02, a12). Header (title, "Panel bağlı · 6/8 çevrimiçi", search,
// Kimlikle bağlan in place), number tiles, location filter, project groups
// (one open at a time, the first open; all open while searching or filtering
// by location) and the four states: loading, error, empty, no search result.
//
// Pure view: data and callbacks in, so every state is a widget test / golden.
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/controller.dart';
import '../data/peers.dart';
import 'computer_tile.dart';
import 'project_group.dart';
import 'widgets.dart';

// Prototype `.amain` gap 10; `.ahead` gap 10, padding 4/0/8; search min 240;
// `.locbar` gap 6, label margin 4; chip 4×11, corner 16.
const double _kGap = 10, _kHeadBottom = 8, _kSearch = 240, _kLocGap = 6;
const double _kChipPadV = 4, _kChipPadH = 11, _kChipRadius = 16;

enum SenseListState { loading, error, ready }

class SenseComputersView extends StatefulWidget {
  const SenseComputersView({
    super.key,
    required this.projects,
    required this.onConnect,
    required this.now,
    this.state = SenseListState.ready,
    this.health,
    this.connectingId,
    this.canConnect = true,
    this.grantsMissing = false,
    this.onRetry,
    this.onTileOrder,
    this.onGroupOrder,
    this.initialQuery = '',
    this.initialLocation,
    this.initialIdOpen = false,
    this.ledOpenId,
  });

  /// Every group, unfiltered, in the person's order.
  final List<SenseProject> projects;
  final ValueChanged<String> onConnect;

  /// Unix seconds ("8 sn önce").
  final int now;
  final SenseListState state;

  /// Health per computer; null = none known (tests without a cache).
  final SenseHealthCache? health;

  /// The tile that shows "Bağlanıyor…".
  final String? connectingId;

  /// False when the person may not connect (grants): Bağlan is locked.
  final bool canConnect;

  /// The grants envelope could not be read ("Yetkiler panelden alınamadı").
  final bool grantsMissing;
  final VoidCallback? onRetry;

  /// New in-group order of a project (ids of all its computers).
  final void Function(SenseProject project, List<String> ids)? onTileOrder;

  /// New order of the groups (project keys).
  final void Function(List<String> keys)? onGroupOrder;

  /// Goldens and tests.
  final String initialQuery;
  final String? initialLocation;
  final bool initialIdOpen;

  /// Goldens: the LED box of this computer is shown open.
  final String? ledOpenId;

  @override
  State<SenseComputersView> createState() => _SenseComputersViewState();
}

class _SenseComputersViewState extends State<SenseComputersView> {
  late final TextEditingController _search = TextEditingController(text: widget.initialQuery);
  late String _query = widget.initialQuery;
  late String? _location = widget.initialLocation;
  late bool _idOpen = widget.initialIdOpen;

  /// The group the person opened (null with [_chosen] = all closed).
  String? _openKey;
  bool _chosen = false;
  List<String> _wanted = const [];

  @override
  void initState() {
    super.initState();
    widget.health?.addListener(_changed);
  }

  @override
  void didUpdateWidget(SenseComputersView old) {
    super.didUpdateWidget(old);
    if (old.health != widget.health) {
      old.health?.removeListener(_changed);
      widget.health?.addListener(_changed);
    }
    // A location that is no longer in the list is dropped.
    if (_location != null && !senseLocationsOf(widget.projects).any((l) => l.name == _location)) {
      _location = null;
    }
  }

  @override
  void dispose() {
    widget.health?.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool _isOpen(SenseProject p, int index) {
    if (_chosen) return p.key == _openKey;
    return index == 0 || _query.trim().isNotEmpty || _location != null;
  }

  void _toggle(SenseProject p, int index) => setState(() {
        final open = _isOpen(p, index);
        _chosen = true;
        _openKey = open ? null : p.key;
      });

  void _clearSearch() => setState(() {
        _search.clear();
        _query = '';
      });

  /// Health of the computers on screen (open groups), fetched in order.
  void _want(List<SenseProject> shown, List<bool> open) {
    final ids = [
      for (var i = 0; i < shown.length; i++)
        if (open[i]) ...shown[i].computers.map((c) => c.id),
    ];
    if (listEquals(ids, _wanted)) return;
    _wanted = ids;
    final cache = widget.health;
    if (cache == null || ids.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cache.want(ids);
    });
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.projects;
    // Sense Remote (D3a, panel #84): LED and "Dikkat isteyen" from the list's health_level.
    widget.health?.seed(senseUnique(all));
    final levels = widget.health?.levels ?? const <String, SenseLevel>{};
    final counts = senseCountsOf(all, levels);
    final ready = widget.state == SenseListState.ready || all.isNotEmpty;
    final children = <Widget>[
      _header(counts, ready),
      if (_idOpen)
        SenseConnectByIdBox(
          onConnect: widget.onConnect,
          enabled: widget.canConnect,
          disabledTip: SenseControllerStrings.noRightTip,
        ),
      if (widget.grantsMissing)
        const SenseBox(
          key: Key('sense-grants-missing'),
          title: SenseControllerStrings.grantsMissing,
          level: SenseLevel.warn,
          children: [SenseMeta(SenseControllerStrings.grantsMissingText)],
        ),
      ..._body(all, counts),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: _kGap),
          children[i],
        ],
      ],
    );
  }

  List<Widget> _body(List<SenseProject> all, SenseCounts counts) {
    if (all.isEmpty) {
      switch (widget.state) {
        case SenseListState.loading:
          return const [
            SenseBox(
              key: Key('sense-list-loading'),
              title: SenseControllerStrings.loading,
              titleLeading: SenseSpinner(size: 12),
            ),
          ];
        case SenseListState.error:
          return [
            SenseBox(
              key: const Key('sense-list-error'),
              title: SenseControllerStrings.errorTitle,
              level: SenseLevel.hot,
              children: [
                const SenseMeta(SenseControllerStrings.errorText),
                const SizedBox(height: SenseUi.rowPadV - 1),
                Wrap(spacing: SenseUi.iconGap, runSpacing: SenseUi.iconGap, children: [
                  SenseButton(
                    key: const Key('sense-list-retry'),
                    label: SenseControllerStrings.retry,
                    kind: SenseButtonKind.primary,
                    size: SenseButtonSize.small,
                    onPressed: widget.onRetry,
                  ),
                  if (!_idOpen)
                    SenseButton(
                      key: const Key('sense-list-error-id'),
                      label: SenseControllerStrings.connectById,
                      size: SenseButtonSize.small,
                      onPressed: () => setState(() => _idOpen = true),
                    ),
                ]),
              ],
            ),
          ];
        case SenseListState.ready:
          return const [
            SenseBox(
              key: Key('sense-list-empty'),
              title: SenseControllerStrings.emptyTitle,
              children: [SenseMeta(SenseControllerStrings.emptyText)],
            ),
          ];
      }
    }
    final shown = senseFilter(all, query: _query, location: _location);
    final out = <Widget>[_tiles(counts)];
    final locations = senseLocationsOf(all);
    if (locations.isNotEmpty) out.add(_locationBar(locations));
    if (shown.isEmpty) {
      _want(const [], const []);
      out.add(SenseBox(
        key: const Key('sense-list-nomatch'),
        title: SenseControllerStrings.noMatch(_query.trim()),
        children: [
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerLeft,
            child: SenseButton(
              key: const Key('sense-list-clear'),
              label: SenseControllerStrings.clearSearch,
              size: SenseButtonSize.small,
              onPressed: _clearSearch,
            ),
          ),
        ],
      ));
      return out;
    }
    final open = [for (var i = 0; i < shown.length; i++) _isOpen(shown[i], i)];
    _want(shown, open);
    for (var i = 0; i < shown.length; i++) {
      final p = shown[i];
      final full = all.firstWhere((x) => x.key == p.key, orElse: () => p);
      out.add(SenseProjectGroup(
        key: ValueKey('sense-pg-${p.key}'),
        project: p,
        open: open[i],
        onToggle: () => _toggle(p, i),
        level: senseGroupLevel(full, (id) => widget.health?.of(id)),
        tile: (c, {dropMark = false, ghost = false}) => _tile(c, dropMark: dropMark, ghost: ghost),
        onTileDrop: widget.onTileOrder == null ? null : (d, target) => _dropTile(full, d, target),
        onGroupDrop: widget.onGroupOrder == null || shown.length < 2
            ? null
            : (d) => widget.onGroupOrder!(senseMoveTo(all.map((x) => x.key).toList(), d.key, p.key)),
        groupDropAbove: true,
      ));
    }
    return out;
  }

  void _dropTile(SenseProject full, SenseTileDrag d, String target) {
    if (d.projectKey != full.key) {
      SenseToast.show(context, SenseControllerStrings.crossProject);
      return;
    }
    final ids = full.computers.map((c) => c.id).toList();
    final next = senseMoveBefore(ids, d.id, target);
    if (!listEquals(next, ids)) widget.onTileOrder!(full, next);
  }

  Widget _tile(SenseComputer c, {bool dropMark = false, bool ghost = false}) => SenseComputerTile(
        computer: c,
        now: widget.now,
        health: widget.health?.of(c.id),
        connecting: widget.connectingId == c.id,
        canConnect: widget.canConnect,
        onConnect: () => widget.onConnect(c.id),
        onLedHover: widget.health == null ? null : () => widget.health!.want([c.id], first: true),
        dropMark: dropMark,
        ghost: ghost,
        ledOpen: widget.ledOpenId == c.id,
      );

  Widget _header(SenseCounts counts, bool ready) => Padding(
        padding: const EdgeInsets.only(bottom: _kHeadBottom - _kGap + 4),
        child: Wrap(
          spacing: _kGap,
          runSpacing: _kGap,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
              Text(SenseControllerStrings.computers, style: SenseTextStyles.pageTitleBold),
              if (ready && widget.state != SenseListState.error) ...[
                const SizedBox(width: _kGap),
                Text(SenseControllerStrings.panelOnline(counts.online, counts.total),
                    key: const Key('sense-list-live'),
                    style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
              ],
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: _kSearch,
                child: SenseField(
                  key: const Key('sense-list-search'),
                  controller: _search,
                  hint: SenseControllerStrings.searchHint,
                  search: true,
                  onChanged: (v) => setState(() {
                    _query = v;
                    _chosen = false;
                  }),
                ),
              ),
              const SizedBox(width: _kGap),
              SenseButton(
                key: const Key('sense-list-id'),
                label: SenseControllerStrings.connectById,
                size: SenseButtonSize.small,
                onPressed: () => setState(() => _idOpen = !_idOpen),
              ),
            ]),
          ],
        ),
      );

  Widget _tiles(SenseCounts counts) => Container(
        key: const Key('sense-list-counts'),
        padding: const EdgeInsets.symmetric(vertical: SenseUi.rowPadV - 1, horizontal: _kGap),
        decoration: BoxDecoration(
          color: SenseColors.bg,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
        ),
        child: SenseStatGrid(children: [
          SenseStatTile(
              key: const Key('sense-count-online'),
              label: SenseControllerStrings.online,
              value: '${counts.online}',
              level: SenseLevel.ok),
          SenseStatTile(
              key: const Key('sense-count-offline'),
              label: SenseControllerStrings.offline,
              value: '${counts.offline}'),
          SenseStatTile(
              key: const Key('sense-count-attention'),
              label: SenseControllerStrings.attention,
              value: '${counts.attention}',
              level: counts.attention > 0 ? counts.attentionLevel : null),
          SenseStatTile(
              key: const Key('sense-count-projects'),
              label: SenseControllerStrings.projects,
              value: '${counts.projects}'),
        ]),
      );

  Widget _locationBar(List<({String name, int count})> locations) => Wrap(
        key: const Key('sense-list-locations'),
        spacing: _kLocGap,
        runSpacing: _kLocGap,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: _kLocGap - 2),
            child: Text(senseUpperTr(SenseControllerStrings.location),
                style: SenseTextStyles.of(
                    size: SenseFontSize.hint, color: SenseColors.textDim, letterSpacingEm: SenseLetterSpacing.caps)),
          ),
          _LocationChip(
            key: const Key('sense-loc-all'),
            label: SenseControllerStrings.all,
            selected: _location == null,
            onTap: () => setState(() {
              _location = null;
              _chosen = false;
            }),
          ),
          for (final l in locations)
            _LocationChip(
              key: Key('sense-loc-${l.name}'),
              label: l.name,
              count: l.count,
              selected: _location == l.name,
              onTap: () => setState(() {
                _location = _location == l.name ? null : l.name;
                _chosen = false;
              }),
            ),
        ],
      );
}

/// Location chip (`.locbar button`): selected white.
class _LocationChip extends StatelessWidget {
  const _LocationChip({super.key, required this.label, required this.selected, required this.onTap, this.count});

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SenseInteractive(
        onTap: onTap,
        selected: selected,
        semanticLabel: label,
        builder: (_, s) => SenseFocusRing(
          visible: s.focused,
          radius: _kChipRadius,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: _kChipPadV, horizontal: _kChipPadH),
            decoration: BoxDecoration(
              color: selected ? SenseColors.text : SenseColors.surface,
              border: Border.all(
                  color: selected ? SenseColors.text : (s.hovered ? SenseColors.lineStrong : SenseColors.line)),
              borderRadius: BorderRadius.circular(_kChipRadius),
            ),
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: label,
                  style: SenseTextStyles.of(
                      size: SenseFontSize.hintLarge,
                      weight: SenseFontWeight.medium,
                      color: selected
                          ? SenseColors.bg
                          : (s.hovered ? SenseColors.text : SenseColors.textSecondary))),
              if (count != null)
                TextSpan(
                    text: ' $count',
                    style: SenseTextStyles.of(
                        size: SenseFontSize.hintLarge,
                        color: SenseColors.textDim)),
            ])),
          ),
        ),
      );
}

