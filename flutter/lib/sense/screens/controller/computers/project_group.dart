// Sense Remote: one project group of the Controller list (YH C2; prototype
// `.cg.pg`, `gDrag`, `tDrag`). Header: ⋮⋮ (drag to sort the groups) ▶ name,
// "N çevrimiçi · M kapalı" on the right; one colour for every header. A closed
// group with a computer in trouble breathes its frame very slowly (4.5 s).
// Inside, tiles in a grid; dragging a tile sorts it inside the group (personal
// order). Moving to another project is not done here (panel only).
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/controller.dart';
import '../data/peers.dart';
import 'computer_tile.dart';

// Prototype `.amain .cg-h` 11×12, `.cg-b` 0 12 10, `.pcgrid` gap 10 + 4 on top,
// `.grip` 12 px with −2 letter spacing; group drop line 2 px; pulse glow 14.
const double _kHeadV = 11, _kHeadH = 12, _kBodyBottom = 10, _kGridGap = 10, _kGridTop = 4;
const double _kGripGap = 2, _kDropLine = 2, _kPulseBlur = 14, _kPulseGlow = 0.08, _kPulseGlowHot = 0.09;
const double _kFeedbackOpacity = 0.85;

/// Data carried by a dragged tile.
class SenseTileDrag {
  const SenseTileDrag(this.projectKey, this.id);
  final String projectKey;
  final String id;
}

/// Data carried by a dragged group.
class SenseGroupDrag {
  const SenseGroupDrag(this.key);
  final String key;
}

/// Columns of the tile grid (`repeat(auto-fill, minmax(210px, 1fr))`).
int senseGridColumns(double width, double minTile) {
  final n = ((width + _kGridGap) / (minTile + _kGridGap)).floor();
  return n < 1 ? 1 : n;
}

/// Worst health of the online computers of a group (drives the pulse).
SenseLevel senseGroupLevel(SenseProject p, SenseComputerHealth? Function(String id) health) {
  final ls = [
    for (final c in p.computers)
      if (c.online && health(c.id) != null) health(c.id)!.level,
  ].where((l) => l == SenseLevel.warn || l == SenseLevel.hot);
  return ls.isEmpty ? SenseLevel.ok : senseWorstLevel(ls);
}

class SenseProjectGroup extends StatefulWidget {
  const SenseProjectGroup({
    super.key,
    required this.project,
    required this.open,
    required this.onToggle,
    required this.tile,
    this.level = SenseLevel.ok,
    this.onTileDrop,
    this.onGroupDrop,
    this.groupDropAbove = true,
  });

  final SenseProject project;
  final bool open;
  final VoidCallback onToggle;

  /// Builds one tile (the list page owns health, connecting and grants).
  final Widget Function(SenseComputer c, {bool dropMark, bool ghost}) tile;

  /// Worst health inside; a closed group pulses when warn or hot.
  final SenseLevel level;

  /// A tile was dropped on [target] of this group.
  final void Function(SenseTileDrag dragged, String target)? onTileDrop;

  /// A group was dropped on this one.
  final void Function(SenseGroupDrag dragged)? onGroupDrop;

  /// Where the drop line of a dragged group shows.
  final bool groupDropAbove;

  @override
  State<SenseProjectGroup> createState() => _SenseProjectGroupState();
}

class _SenseProjectGroupState extends State<SenseProjectGroup> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: SenseMotion.groupPulse.duration);
  String? _dragging;
  bool _groupHover = false;

  bool get _pulsing => !widget.open && (widget.level == SenseLevel.warn || widget.level == SenseLevel.hot);

  bool get _still => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(SenseProjectGroup old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (_pulsing && !_still) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// Frame strength 0..1..0 over one loop (CSS keyframes 0 %, 50 %, 100 %).
  double _wave() {
    if (!_pulsing) return 0;
    if (_still) return 1;
    final t = _pulse.value;
    final half = t < 0.5 ? t * 2 : (1 - t) * 2;
    return SenseMotion.groupPulse.curve.transform(half);
  }

  List<BoxShadow>? _shadow(double w) {
    if (w <= 0) return null;
    final hot = widget.level == SenseLevel.hot;
    final color = hot ? SenseColors.hot : SenseColors.warn;
    final ring = hot ? SenseMotionParams.groupPulseHotOpacity : SenseMotionParams.groupPulseWarnOpacity;
    return [
      BoxShadow(color: color.withOpacity(ring * w), spreadRadius: 1),
      BoxShadow(color: color.withOpacity((hot ? _kPulseGlowHot : _kPulseGlow) * w), blurRadius: _kPulseBlur),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    final group = AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Container(
        key: Key('sense-group-${p.key}'),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.category),
          boxShadow: _shadow(_wave()),
        ),
        child: child,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(),
          if (widget.open) _grid(),
        ],
      ),
    );
    if (widget.onGroupDrop == null) return group;
    return DragTarget<SenseGroupDrag>(
      onWillAcceptWithDetails: (d) {
        final ok = d.data.key != p.key;
        if (ok != _groupHover) setState(() => _groupHover = ok);
        return ok;
      },
      onLeave: (_) => setState(() => _groupHover = false),
      onAcceptWithDetails: (d) {
        setState(() => _groupHover = false);
        widget.onGroupDrop!(d.data);
      },
      builder: (context, _, __) => Stack(clipBehavior: Clip.none, children: [
        group,
        if (_groupHover)
          Positioned(
            left: 0,
            right: 0,
            top: widget.groupDropAbove ? -_kDropLine - 1 : null,
            bottom: widget.groupDropAbove ? null : -_kDropLine - 1,
            child: const SizedBox(height: _kDropLine, child: ColoredBox(color: SenseColors.text)),
          ),
      ]),
    );
  }

  Widget _header() {
    final p = widget.project;
    // The grip only drags: a click on it does not open or close the group.
    final grip = SenseInteractive(
      onTap: () {},
      button: false,
      mouseCursor: SystemMouseCursors.grab,
      tooltip: SenseControllerStrings.dragToSort,
      builder: (_, s) => Padding(
        padding: const EdgeInsets.only(right: _kGripGap),
        child: Icon(Icons.drag_indicator,
            size: SenseFontSize.body,
            color: s.hovered ? SenseColors.textMuted : SenseColors.lineStrong),
      ),
    );
    final draggableGrip = widget.onGroupDrop == null
        ? grip
        : Draggable<SenseGroupDrag>(
            key: Key('sense-group-grip-${p.key}'),
            data: SenseGroupDrag(p.key),
            feedback: _GroupFeedback(name: p.name),
            childWhenDragging: Opacity(opacity: SenseUi.disabledOpacity, child: grip),
            child: grip,
          );
    return SenseInteractive(
      key: Key('sense-group-head-${p.key}'),
      onTap: widget.onToggle,
      semanticLabel: p.name,
      toggled: widget.open,
      builder: (_, s) => SenseFocusRing(
        visible: s.focused,
        radius: SenseRadii.category,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: _kHeadV, horizontal: _kHeadH),
          child: Row(children: [
            draggableGrip,
            const SizedBox(width: SenseUi.iconGap + 2),
            SenseCaret(direction: widget.open ? SenseCaretDirection.down : SenseCaretDirection.right),
            const SizedBox(width: SenseUi.iconGap + 2),
            Flexible(
              child: Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SenseTextStyles.of(size: SenseFontSize.categoryTitle, weight: SenseFontWeight.bold)),
            ),
            const SizedBox(width: SenseUi.rowGap),
            Expanded(
              child: Text(SenseControllerStrings.groupSummary(p.online, p.offline),
                  key: Key('sense-group-sum-${p.key}'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _grid() {
    final p = widget.project;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_kHeadH, _kGridTop, _kHeadH, _kBodyBottom),
      child: LayoutBuilder(builder: (context, box) {
        final window = MediaQuery.maybeSizeOf(context)?.width ?? SenseSizes.windowWidth;
        final cols = box.maxWidth.isFinite ? senseGridColumns(box.maxWidth, SenseLayout.tileMin(window)) : 1;
        final w = box.maxWidth.isFinite ? (box.maxWidth - _kGridGap * (cols - 1)) / cols : SenseSizes.tileMin;
        return Wrap(
          spacing: _kGridGap,
          runSpacing: _kGridGap,
          children: [
            for (final c in p.computers)
              SizedBox(
                key: ValueKey('sense-tile-${p.key}-${c.id}'),
                width: w,
                child: widget.onTileDrop == null ? widget.tile(c) : _draggable(c, w),
              ),
          ],
        );
      }),
    );
  }

  Widget _draggable(SenseComputer c, double width) {
    final p = widget.project;
    return DragTarget<SenseTileDrag>(
      onWillAcceptWithDetails: (d) => d.data.id != c.id,
      onAcceptWithDetails: (d) => widget.onTileDrop!(d.data, c.id),
      builder: (context, candidates, _) => Draggable<SenseTileDrag>(
        data: SenseTileDrag(p.key, c.id),
        onDragStarted: () => setState(() => _dragging = c.id),
        onDragEnd: (_) => setState(() => _dragging = null),
        onDraggableCanceled: (_, __) => setState(() => _dragging = null),
        feedback: SizedBox(
          width: width,
          child: Opacity(opacity: _kFeedbackOpacity, child: widget.tile(c)),
        ),
        child: widget.tile(c, dropMark: candidates.isNotEmpty, ghost: _dragging == c.id),
      ),
    );
  }
}

class _GroupFeedback extends StatelessWidget {
  const _GroupFeedback({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: _kHeadV, horizontal: _kHeadH),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.lineStrong),
          borderRadius: BorderRadius.circular(SenseRadii.category),
        ),
        child: Text(name,
            style: SenseTextStyles.of(size: SenseFontSize.categoryTitle, weight: SenseFontWeight.bold)),
      );
}
