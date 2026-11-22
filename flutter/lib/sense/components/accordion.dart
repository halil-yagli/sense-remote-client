// Sense Remote: closable category (YH T7 "Kapanır kategori", prototype `.cg`,
// `accTog`, `accRestore`). Header: ▶ + title + one-line summary on the right +
// status dot. At one level only one category is open; the header that was
// pressed stays where it was on screen (#45): when a category above closes, the
// list scrolls by the same amount instead of the page jumping.
// The caret changes from ▶ to ▼ without turning (T4: no rotation).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import 'blink.dart';

/// One category.
class SenseAccordionItem {
  const SenseAccordionItem({
    required this.id,
    required this.title,
    this.summary,
    this.level,
    required this.builder,
  });

  /// Stable key (also the test key: `sense-acc-<id>`).
  final String id;
  final String title;

  /// One line on the right ("i7-12700 · %23 · 58 °C"); ellipsised.
  final String? summary;

  /// Status of the category (worst value inside, T6). Null: no dot, no colour.
  final SenseLevel? level;
  final WidgetBuilder builder;
}

/// Look of the category box.
enum SenseAccordionDensity {
  /// Inside a popup (`.cg`): black box, 8 × 10 header, 12.5 px title.
  popup,

  /// On an app page (`.amain .cg`): surface box, 11 × 12 header, 13 px title.
  page,
}

class SenseAccordion extends StatefulWidget {
  const SenseAccordion({
    super.key,
    required this.items,
    this.openId,
    this.initialOpenId,
    this.onChanged,
    this.density = SenseAccordionDensity.popup,
    this.spacing = 6,
    this.keepHeaderInPlace = true,
  });

  final List<SenseAccordionItem> items;

  /// Controlled open item. When null the accordion keeps its own state,
  /// starting from [initialOpenId].
  final String? openId;
  final String? initialOpenId;

  /// Called with the newly open id, or null when the open one closed.
  final ValueChanged<String?>? onChanged;
  final SenseAccordionDensity density;

  /// Gap between categories (prototype margin 6 px).
  final double spacing;

  /// Keeps the pressed header at the same screen position (#45).
  final bool keepHeaderInPlace;

  @override
  State<SenseAccordion> createState() => _SenseAccordionState();
}

class _SenseAccordionState extends State<SenseAccordion> {
  late String? _open = widget.openId ?? widget.initialOpenId;
  final Map<String, GlobalKey> _headerKeys = {};

  String? get _current => _open;

  @override
  void didUpdateWidget(SenseAccordion old) {
    super.didUpdateWidget(old);
    if (widget.openId != old.openId) _open = widget.openId;
  }

  GlobalKey _keyFor(String id) => _headerKeys.putIfAbsent(id, () => GlobalKey());

  double? _headerY(String id) {
    final box = _headerKeys[id]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return box.localToGlobal(Offset.zero).dy;
  }

  void _toggle(String id) {
    final next = _current == id ? null : id;
    final before = widget.keepHeaderInPlace ? _headerY(id) : null;
    setState(() => _open = next);
    widget.onChanged?.call(next);
    if (before == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final after = _headerY(id);
      final ctx = _headerKeys[id]?.currentContext;
      if (after == null || ctx == null) return;
      final delta = after - before;
      if (delta.abs() <= 1) return;
      final position = Scrollable.maybeOf(ctx)?.position;
      if (position == null) return;
      final target = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      position.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = _current;
    final children = <Widget>[];
    for (var i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (i > 0) children.add(SizedBox(height: widget.spacing));
      children.add(SenseCategory(
        key: ValueKey('sense-acc-${item.id}'),
        headerKey: _keyFor(item.id),
        title: item.title,
        summary: item.summary,
        level: item.level,
        density: widget.density,
        open: open == item.id,
        onToggle: () => _toggle(item.id),
        builder: item.builder,
      ));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// One category box; [SenseAccordion] builds these. Usable alone for a single
/// closable section.
class SenseCategory extends StatefulWidget {
  const SenseCategory({
    super.key,
    this.headerKey,
    required this.title,
    this.summary,
    this.level,
    this.density = SenseAccordionDensity.popup,
    required this.open,
    required this.onToggle,
    required this.builder,
  });

  final Key? headerKey;
  final String title;
  final String? summary;
  final SenseLevel? level;
  final SenseAccordionDensity density;
  final bool open;
  final VoidCallback onToggle;
  final WidgetBuilder builder;

  /// Left stripe of a warn / hot category (prototype `border-left:3px`).
  static const double stripe = 3;
  static const double dot = 8;
  static const double caretSize = 9;
  static const double titleMinWidth = 90;

  /// Summary text colour (`.cg.warn .cs` #d9a35c, `.cg.hot .cs` #e8858d): the
  /// status colour softened towards the secondary text.
  static Color summaryColor(SenseLevel? level) {
    switch (level) {
      case SenseLevel.warn:
        return Color.lerp(SenseColors.warn, SenseColors.textSecondary, 0.35)!;
      case SenseLevel.hot:
        return Color.lerp(SenseColors.dangerText, SenseColors.textSecondary, 0.35)!;
      case SenseLevel.ok:
      case SenseLevel.unknown:
      case null:
        return SenseColors.textMuted;
    }
  }

  static Color titleColor(SenseLevel? level) {
    switch (level) {
      case SenseLevel.warn:
        return SenseColors.warn;
      case SenseLevel.hot:
        return SenseColors.dangerText;
      case SenseLevel.ok:
      case SenseLevel.unknown:
      case null:
        return SenseColors.text;
    }
  }

  @override
  State<SenseCategory> createState() => _SenseCategoryState();
}

class _SenseCategoryState extends State<SenseCategory> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final page = widget.density == SenseAccordionDensity.page;
    final level = widget.level;
    final hot = level == SenseLevel.hot;
    final stripeColor = switch (level) {
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.hot,
      _ => null,
    };
    final base = page ? SenseColors.surface : SenseColors.bg;

    final header = Semantics(
      button: true,
      expanded: widget.open,
      label: widget.title,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onToggle();
            return null;
          }),
        },
        child: GestureDetector(
          key: widget.headerKey,
          behavior: HitTestBehavior.opaque,
          onTap: widget.onToggle,
          child: Container(
            color: (_hover || _focus) ? SenseColors.hover.withOpacity(0.5) : null,
            padding: page
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 11)
                : const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              ExcludeSemantics(
                child: Text(
                  widget.open ? '▼' : '▶',
                  style: const TextStyle(
                    fontFamily: SenseFont.family,
                    fontSize: SenseCategory.caretSize,
                    color: SenseColors.textDim,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(minWidth: page ? 0 : SenseCategory.titleMinWidth),
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: SenseFont.family,
                    fontSize: page ? SenseFontSize.categoryTitle : SenseFontSize.categoryTitleSmall,
                    fontWeight: SenseFontWeight.bold,
                    color: SenseCategory.titleColor(level),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.summary ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: SenseFont.family,
                    fontSize: SenseFontSize.categorySummary,
                    color: SenseCategory.summaryColor(level),
                  ),
                ),
              ),
              if (level != null && level != SenseLevel.unknown) ...[
                const SizedBox(width: 8),
                SenseStatusDot(color: level.color, size: SenseCategory.dot, glow: hot),
              ],
            ]),
          ),
        ),
      ),
    );

    // Flutter cannot round a border whose sides differ in colour, so the 3 px
    // warn/hot stripe is laid over the left edge and clipped by the corners.
    final radius = BorderRadius.circular(page ? SenseRadii.categoryLarge : SenseRadii.category);
    final edge = _focus ? SenseColors.text : SenseColors.line;
    final box = Container(
      decoration: BoxDecoration(
        color: hot ? null : base,
        gradient: hot
            ? LinearGradient(
                colors: [Color.alphaBlend(SenseColors.hot.withOpacity(0.1), base), base],
                stops: const [0, 0.45],
              )
            : null,
        border: Border.all(color: edge),
        borderRadius: radius,
      ),
      padding: EdgeInsets.only(left: stripeColor != null ? SenseCategory.stripe - 1 : 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (widget.open)
            Padding(
              padding: page
                  ? const EdgeInsets.fromLTRB(12, 0, 12, 10)
                  : const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Builder(builder: widget.builder),
            ),
        ],
      ),
    );
    if (stripeColor == null) return box;
    return ClipRRect(
      borderRadius: radius,
      child: Stack(children: [
        box,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: SenseCategory.stripe,
          child: ColoredBox(key: const Key('sense-acc-stripe'), color: stripeColor),
        ),
      ]),
    );
  }
}
