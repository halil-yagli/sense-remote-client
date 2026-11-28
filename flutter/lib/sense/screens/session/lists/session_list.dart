// Sense Remote: one bar list (YH O7; prototype `.menu`, `.mtop`, `.mq`, `.mcg`, `.it`).
// 360 px, hangs from the bar under its button; fixed title row with the state chip;
// the "SIK KULLANILAN" box (black, frame in the status colour); closable categories
// below, one open at a time, each showing its value while closed; thin scrollbar,
// reaches down to the bottom of the window. A choice keeps the list open and shows a
// short notification (the caller's [onNotify]).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/accordion.dart';
import '../../../components/button.dart';
import '../../../components/inline_confirm.dart';
import '../../../components/scrollbar.dart';
import '../../../components/segment.dart';
import '../../../components/toggle.dart';
import '../../../diag_log.dart';
import '../../../strings/session.dart';
import '../../../tokens/sense_tokens.dart';
import '../../../tokens/theme.dart';
import 'backend.dart' show SenseResolution;
import 'list_model.dart';

/// `where` of the interface records written from the lists (karar #103).
const String _where = 'session.list';

/// List width (YH O7: 360 px).
const double kSenseListWidth = 360;

/// Bottom corners of a list (prototype 14 px).
const double kSenseListRadius = 14;

class SenseSessionList extends StatefulWidget {
  const SenseSessionList({
    super.key,
    required this.spec,
    this.onNotify,
    this.maxHeight,
  });

  final SenseListSpec spec;

  /// Short notification after a choice (T7 toast).
  final ValueChanged<String>? onNotify;

  /// Room down to the bottom of the window.
  final double? maxHeight;

  @override
  State<SenseSessionList> createState() => _SenseSessionListState();
}

class _SenseSessionListState extends State<SenseSessionList> {
  final _scroll = ScrollController();
  String? _open;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _notify(String m) => widget.onNotify?.call(m);

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spec.frequent.isNotEmpty) _FrequentBox(spec: spec, notify: _notify),
        if (spec.sections.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
            child: SenseAccordion(
              openId: _open,
              onChanged: (id) => setState(() => _open = id),
              items: [
                for (final s in spec.sections)
                  SenseAccordionItem(
                    id: s.id,
                    title: s.title,
                    summary: s.summary,
                    level: s.level,
                    builder: (_) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [for (final e in s.entries) SenseListEntryView(entry: e, notify: _notify)],
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
    return Container(
      key: const ValueKey('sense-session-list'),
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
          _Header(title: spec.title, chip: spec.chip, level: spec.chipLevel),
          Flexible(
            child: SenseScrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.only(bottom: 10),
                child: body,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, this.chip, this.level});
  final String title;
  final String? chip;
  final SenseLevel? level;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: const BoxDecoration(
        color: SenseColors.surface,
        border: Border(bottom: BorderSide(color: SenseColors.line)),
      ),
      child: Row(children: [
        Expanded(
          child: Text(title,
              style: SenseTextStyles.of(size: SenseFontSize.popupTitle, weight: SenseFontWeight.bold)),
        ),
        if (chip != null) SenseStateChip(label: chip!, level: level),
      ]),
    );
  }
}

/// The small state chip (`.cst`): grey, orange or red.
class SenseStateChip extends StatelessWidget {
  const SenseStateChip({super.key, required this.label, this.level});
  final String label;
  final SenseLevel? level;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (level) {
      SenseLevel.warn => (SenseColors.warn.withOpacity(0.15), SenseColors.warn),
      SenseLevel.hot => (SenseColors.hot.withOpacity(0.18), SenseColors.dangerText),
      _ => (SenseColors.raised, SenseColors.textMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
      child: Text(label,
          maxLines: 1,
          style: SenseTextStyles.of(size: SenseFontSize.hintSmall, weight: SenseFontWeight.medium, color: fg)),
    );
  }
}

class _FrequentBox extends StatelessWidget {
  const _FrequentBox({required this.spec, required this.notify});
  final SenseListSpec spec;
  final ValueChanged<String> notify;

  @override
  Widget build(BuildContext context) {
    final level = spec.frequentLevel;
    final border = switch (level) {
      SenseLevel.warn => SenseColors.warn.withOpacity(0.5),
      SenseLevel.hot => SenseColors.hot.withOpacity(0.6),
      _ => SenseColors.line,
    };
    return Container(
      key: const ValueKey('sense-list-frequent'),
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      decoration: BoxDecoration(
        color: SenseColors.bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Text(SenseSessionStrings.frequent.toUpperCase(),
                style: SenseTextStyles.of(
                    size: SenseFontSize.caps,
                    color: SenseColors.textDim,
                    letterSpacingEm: SenseLetterSpacing.capsWide)),
          ),
          for (final e in spec.frequent) SenseListEntryView(entry: e, notify: notify),
        ],
      ),
    );
  }
}

/// One entry row.
class SenseListEntryView extends StatelessWidget {
  const SenseListEntryView({super.key, required this.entry, required this.notify});
  final SenseListEntry entry;
  final ValueChanged<String> notify;

  static const double _lead = 14;
  static const EdgeInsets _pad = EdgeInsets.symmetric(horizontal: 12, vertical: 6);

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final Widget row = switch (e) {
      SenseActionEntry a => _action(a),
      SenseToggleEntry t => _toggle(t),
      SenseChoiceEntry c => c.style == SenseChoiceStyle.segment ? _segment(c) : _radios(c),
      SenseSliderEntry s => _slider(context, s),
      SenseInfoEntry i => _info(i),
      SenseTilesEntry t => _tiles(t),
      SenseSizeInputEntry z => _SizeInputRow(entry: z, notify: notify),
    };
    return KeyedSubtree(key: ValueKey('sense-entry-${e.id}'), child: row);
  }

  Widget _label(String label, String? hint, {Color color = SenseColors.text}) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: label, style: SenseTextStyles.of(color: color)),
        if (hint != null)
          TextSpan(
              text: ' · $hint',
              style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Rows the person may not use: faded, lock + "Yetkin yok · panelden", no action.
  Widget _locked(Widget child) => Tooltip(
        message: SenseSessionStrings.noRights,
        child: Opacity(
          opacity: SenseUi.disabledOpacity,
          child: IgnorePointer(child: child),
        ),
      );

  Widget _lockTag() => Row(mainAxisSize: MainAxisSize.min, children: [
        const SenseLockIcon(),
        const SizedBox(width: 4),
        Text(SenseSessionStrings.noRights,
            style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted)),
      ]);

  /// The reason a choice / slider row is grey (rows with a label line carry it inline).
  bool _showWhy(SenseListEntry e) => e.disabled && !e.noRights && e.why != null;

  Widget _whyLine(String why) => Padding(
        padding: const EdgeInsets.fromLTRB(12 + _lead + 10, 0, 12, 6),
        child: Text(why,
            key: const ValueKey('sense-why'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
      );

  Widget _action(SenseActionEntry e) {
    Widget line(VoidCallback? tap) {
      final enabled = tap != null && !e.noRights;
      final content = Container(
        padding: _pad,
        constraints: const BoxConstraints(minHeight: 30),
        child: Row(children: [
          SizedBox(
            width: _lead,
            child: Text('›',
                textAlign: TextAlign.center,
                style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textDim)),
          ),
          const SizedBox(width: 10),
          Expanded(child: _label(e.label, e.shownHint)),
          if (e.noRights) _lockTag(),
          if (!e.noRights && e.tag != null) _Tag(label: e.tag!, level: e.tagLevel),
        ]),
      );
      final interactive = SenseInteractive(
        onTap: enabled ? tap : null,
        semanticLabel: e.label,
        builder: (context, s) => ColoredBox(
          color: s.hovered && enabled ? SenseColors.hover : SenseColors.bg.withOpacity(0),
          child: content,
        ),
      );
      if (e.noRights) return _locked(interactive);
      return Opacity(opacity: enabled ? 1 : SenseUi.disabledOpacity, child: interactive);
    }

    final onTap = e.onTap;
    if (onTap == null) return line(null);
    void run() {
      senseUiButton(e.id, where: _where);
      onTap();
      notify(e.toast ?? e.label);
    }

    if (e.confirmQuestion != null) {
      // Sürüm 12 (#158): the row asks in place in the prototype's `.it.asking` layout —
      // question, detail, buttons right-aligned under them; the row grows, nothing slides.
      return SenseInlineConfirm(
        question: e.confirmQuestion!,
        detail: e.confirmDetail,
        confirmLabel: e.confirmLabel ?? e.label,
        confirmKind: e.confirmPrimary ? SenseButtonKind.primary : SenseButtonKind.danger,
        onConfirm: run,
        builder: (context, ask) => line(ask),
        askingBuilder: (context, strip) => Container(
          key: ValueKey('sense-asking-${e.id}'),
          color: senseAskRowColor,
          padding: const EdgeInsets.fromLTRB(12 + _lead + 10, 8, 12, 10),
          child: strip,
        ),
      );
    }
    return line(run);
  }

  Widget _toggle(SenseToggleEntry e) {
    final change = e.onChanged;
    final row = Padding(
      padding: _pad,
      child: Row(children: [
        const SizedBox(width: _lead + 10),
        Expanded(child: _label(e.label, e.shownHint)),
        if (e.noRights) ...[_lockTag(), const SizedBox(width: 8)],
        SenseToggle(
          compact: true,
          value: e.value,
          semanticLabel: e.label,
          onChanged: change == null || e.noRights
              ? null
              : (v) {
                  senseUiSetting(e.id, e.value, v, where: _where);
                  change(v);
                  final fallback = '${e.label} · ${v ? SenseSessionStrings.on : SenseSessionStrings.off}';
                  final later = e.toastAfterChange?.call();
                  if (later is Future<String?>) {
                    // B5: the toast waits for the real result of the change.
                    later.then((m) => notify(m ?? fallback)).catchError((Object _) => notify(fallback));
                  } else {
                    // An empty text means the row's owner shows its own note (recording, #136).
                    final text = (later as String?) ?? fallback;
                    if (text.isNotEmpty) notify(text);
                  }
                },
        ),
      ]),
    );
    return e.noRights ? _locked(row) : row;
  }

  Widget _segment(SenseChoiceEntry e) {
    final change = e.onChanged;
    final row = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 52),
          child: Text(e.label, style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SenseSegment<String>(
            semanticLabel: e.label,
            options: [
              for (final o in e.options) SenseSegmentOption(value: o.value, label: o.label, enabled: o.enabled),
            ],
            value: e.value,
            onChanged: change == null || e.noRights
                ? null
                : (v) {
                    senseUiSetting(e.id, e.value, v, where: _where);
                    change(v);
                    final label = e.options.firstWhere((o) => o.value == v).label;
                    notify('${e.label} · $label');
                  },
          ),
        ),
      ]),
    ),
      if (_showWhy(e)) _whyLine(e.why!),
    ]);
    return e.noRights ? _locked(row) : row;
  }

  Widget _radios(SenseChoiceEntry e) {
    final change = e.onChanged;
    final rows = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final o in e.options)
          SenseInteractive(
            key: ValueKey('sense-radio-${e.id}-${o.value}'),
            onTap: change == null || e.noRights || !o.enabled
                ? null
                : () {
                    senseUiSetting(e.id, e.value, o.value, where: _where);
                    change(o.value);
                    notify('${e.label} · ${o.label}');
                  },
            selected: o.value == e.value,
            semanticLabel: o.label,
            builder: (context, s) => Container(
              color: s.hovered ? SenseColors.hover : null,
              padding: _pad,
              constraints: const BoxConstraints(minHeight: 30),
              child: Row(children: [
                _Radio(selected: o.value == e.value),
                const SizedBox(width: 10),
                Expanded(child: _label(o.label, null)),
              ]),
            ),
          ),
        if (_showWhy(e)) _whyLine(e.why!),
      ],
    );
    return e.noRights ? _locked(rows) : rows;
  }

  Widget _slider(BuildContext context, SenseSliderEntry e) {
    return _SliderRow(entry: e, notify: notify);
  }

  Widget _info(SenseInfoEntry e) {
    return Padding(
      padding: _pad,
      child: Row(children: [
        SizedBox(
          width: _lead,
          child: Text('i',
              textAlign: TextAlign.center,
              style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textDim)),
        ),
        const SizedBox(width: 10),
        Expanded(child: _label(e.label, e.detail)),
      ]),
    );
  }

  /// Sürüm 10 (#111): tiles wrap into rows of [kSenseTilesPerRow]; "Tümü birlikte" is the
  /// last tile of the list (list_specs) so it always lands at the end and stays visible —
  /// the old single row drew a fixed 4 slots and dropped the 5th tile on a 4-screen PC.
  Widget _tiles(SenseTilesEntry e) {
    final pick = e.onPick;
    final rows = <List<SenseTile>>[];
    for (var i = 0; i < e.tiles.length; i += kSenseTilesPerRow) {
      final end = i + kSenseTilesPerRow;
      rows.add(e.tiles.sublist(i, end > e.tiles.length ? e.tiles.length : end));
    }
    Widget row(List<SenseTile> tiles) => Row(children: [
          for (var i = 0; i < kSenseTilesPerRow; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: i < tiles.length
                  ? _TileButton(
                      tile: tiles[i],
                      selected: tiles[i].value == e.value,
                      onTap: pick == null
                          ? null
                          : () {
                              pick(tiles[i].value);
                              // B13: the one that is already shown needs no notice.
                              if (tiles[i].value == e.value) return;
                              notify(tiles[i].value < 0
                                  ? SenseSessionStrings.allScreens
                                  : SenseSessionStrings.screenN(tiles[i].value + 1));
                            },
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ]);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 6),
          row(rows[r]),
        ],
      ]),
    );
  }
}

/// Tiles per row in the Ekranlar list (prototype `.tiles`, 4 columns).
const int kSenseTilesPerRow = 4;

class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.level});
  final String label;
  final SenseLevel? level;

  @override
  Widget build(BuildContext context) {
    final hot = level == SenseLevel.hot;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: hot ? SenseColors.hot.withOpacity(0.18) : SenseColors.lineStrong,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label,
          style: SenseTextStyles.of(
              size: SenseFontSize.capsSmall,
              weight: SenseFontWeight.bold,
              color: hot ? SenseColors.dangerText : SenseColors.textSecondary)),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? SenseColors.text : SenseColors.lineStrong, width: 1.5),
      ),
      padding: const EdgeInsets.all(2),
      child: selected
          ? const DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: SenseColors.text))
          : null,
    );
  }
}

class _TileButton extends StatelessWidget {
  const _TileButton({required this.tile, required this.selected, required this.onTap});
  final SenseTile tile;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SenseInteractive(
      key: ValueKey('sense-tile-${tile.value}'),
      onTap: onTap,
      selected: selected,
      semanticLabel: tile.title,
      builder: (context, s) {
        final bg = selected ? SenseColors.text : (s.hovered ? SenseColors.hover : SenseColors.surface);
        final fg = selected ? SenseColors.bg : SenseColors.text;
        return Container(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: selected ? SenseColors.text : SenseColors.line),
            borderRadius: BorderRadius.circular(SenseRadii.button),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tile.title,
                style: SenseTextStyles.of(size: SenseFontSize.categoryTitle, weight: SenseFontWeight.bold, color: fg)),
            Text(tile.sub ?? ' ',
                style: SenseTextStyles.of(
                    size: SenseFontSize.capsSmall, color: selected ? SenseColors.lineStrong : SenseColors.textDim)),
          ]),
        );
      },
    );
  }
}

/// Slider row (`.slider`): label, white track, value; writes once on release.
class _SliderRow extends StatefulWidget {
  const _SliderRow({required this.entry, required this.notify});
  final SenseSliderEntry entry;
  final ValueChanged<String> notify;

  @override
  State<_SliderRow> createState() => _SliderRowState();
}

class _SliderRowState extends State<_SliderRow> {
  double? _drag;

  @override
  void didUpdateWidget(_SliderRow old) {
    super.didUpdateWidget(old);
    if (old.entry.value != widget.entry.value) _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final change = e.onChanged;
    final enabled = change != null && !e.noRights;
    final v = (_drag ?? e.value).clamp(e.min, e.max).toDouble();
    final why = e.disabled && !e.noRights ? e.why : null;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(12 + 24, 2, 12, 8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
        Text(e.label, style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              activeTrackColor: SenseColors.text,
              inactiveTrackColor: SenseColors.lineStrong,
              thumbColor: SenseColors.text,
              overlayColor: SenseColors.text.withOpacity(0.08),
              disabledActiveTrackColor: SenseColors.textMuted,
              disabledInactiveTrackColor: SenseColors.line,
              disabledThumbColor: SenseColors.textMuted,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: v,
              min: e.min,
              max: e.max,
              onChanged: enabled ? (x) => setState(() => _drag = x) : null,
              onChangeEnd: enabled
                  ? (x) {
                      // On release only, never on every step of the drag.
                      senseUiSetting(e.id, e.value, x, where: _where);
                      change!(x);
                      widget.notify('${e.label} · ${e.format(x)}');
                    }
                  : null,
            ),
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(e.format(v),
              textAlign: TextAlign.right,
              style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textSecondary)),
        ),
      ]),
        if (why != null)
          Text(why,
              key: const ValueKey('sense-why'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
      ]),
    );
    if (e.noRights) {
      return Tooltip(
        message: SenseSessionStrings.noRights,
        child: Opacity(opacity: SenseUi.disabledOpacity, child: IgnorePointer(child: row)),
      );
    }
    // Switched off by its parent option (Özel kalite kapalı): faded, like locked rows.
    if (!enabled) return Opacity(opacity: SenseUi.disabledOpacity, child: row);
    return row;
  }
}

/// Custom resolution row (R5): label, width × height fields, "Uygula". Digits only; the
/// size is applied when both fields are inside the limits, otherwise the limits are said
/// in place (no dialog, T7).
class _SizeInputRow extends StatefulWidget {
  const _SizeInputRow({required this.entry, required this.notify});
  final SenseSizeInputEntry entry;
  final ValueChanged<String> notify;

  @override
  State<_SizeInputRow> createState() => _SizeInputRowState();
}

class _SizeInputRowState extends State<_SizeInputRow> {
  late final TextEditingController _w = TextEditingController(text: widget.entry.width?.toString() ?? '');
  late final TextEditingController _h = TextEditingController(text: widget.entry.height?.toString() ?? '');
  bool _wrong = false;

  @override
  void dispose() {
    _w.dispose();
    _h.dispose();
    super.dispose();
  }

  void _apply() {
    final e = widget.entry;
    final apply = e.onApply;
    if (apply == null) return;
    if (!senseCustomSizeValid(_w.text, _h.text, min: e.min, max: e.max)) {
      setState(() => _wrong = true);
      return;
    }
    final w = int.parse(_w.text.trim()), h = int.parse(_h.text.trim());
    setState(() => _wrong = false);
    senseUiSetting(e.id, '-', '$w×$h', where: _where);
    final trial = e.trial;
    if (trial != null) {
      // Sürüm 12 (FO-A7/B7): tried; the box below asks "Koru" for 15 s.
      trial.start(SenseResolution(w, h), note: widget.notify);
      return;
    }
    apply(w, h);
    widget.notify('${e.label} · $w×$h');
  }

  /// Sürüm 12 (FO-A7/B7, prototype `.cres.warn`): the size being tried, the seconds left,
  /// Geri al / Koru. Orange frame: the image may be wrong until the person says.
  Widget _trialBox(SenseResolutionTrial t) {
    final size = t.trying!;
    return Container(
      key: ValueKey('sense-size-trial-${widget.entry.id}'),
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: SenseColors.warn.withOpacity(0.07),
        border: Border.all(color: SenseColors.warn.withOpacity(0.55)),
        borderRadius: BorderRadius.circular(SenseRadii.button),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(SenseSessionStrings.resolutionTrialQuestion(size.width, size.height),
            style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.bold)),
        const SizedBox(height: 6),
        Text(SenseSessionStrings.resolutionTrialLeft(t.secondsLeft),
            key: ValueKey('sense-size-trial-left-${widget.entry.id}'),
            style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted)),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(spacing: kSenseAskGap, runSpacing: kSenseAskGap, children: [
            SenseButton(
              key: ValueKey('sense-size-undo-${widget.entry.id}'),
              label: SenseSessionStrings.resolutionUndo,
              size: SenseButtonSize.small,
              onPressed: t.undo,
            ),
            SenseButton(
              key: ValueKey('sense-size-keep-${widget.entry.id}'),
              label: SenseSessionStrings.resolutionKeep,
              size: SenseButtonSize.small,
              kind: SenseButtonKind.primary,
              autofocus: true,
              onPressed: t.keep,
            ),
          ]),
        ),
      ]),
    );
  }

  OutlineInputBorder _border(Color c) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c));

  Widget _field(TextEditingController c, String label, bool enabled) => SizedBox(
        width: 58,
        child: Material(
          type: MaterialType.transparency,
          child: TextField(
            key: ValueKey('sense-size-${widget.entry.id}-$label'),
            controller: c,
            enabled: enabled,
            maxLines: 1,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            style: SenseTextStyles.of(size: SenseFontSize.bodySmall),
            cursorColor: SenseColors.text,
            onChanged: (_) {
              if (_wrong) setState(() => _wrong = false);
            },
            onSubmitted: (_) => _apply(),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: SenseColors.surface,
              hintText: label,
              hintStyle: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim),
              contentPadding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
              enabledBorder: _border(_wrong ? SenseColors.warn : SenseColors.lineStrong),
              focusedBorder: _border(_wrong ? SenseColors.warn : SenseColors.text),
              disabledBorder: _border(SenseColors.line),
              border: _border(SenseColors.lineStrong),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final trial = widget.entry.trial;
    if (trial == null) return _row(context);
    return ListenableBuilder(
      listenable: trial,
      builder: (context, _) => trial.active ? _trialBox(trial) : _row(context),
    );
  }

  Widget _row(BuildContext context) {
    final e = widget.entry;
    final enabled = e.onApply != null && !e.noRights;
    final trial = e.trial != null;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(12 + 24, 4, 12, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(text: e.label, style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
            if (e.shownHint != null)
              TextSpan(
                  text: ' · ${e.shownHint}',
                  style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        Row(children: [
          _field(_w, SenseSessionStrings.customResolutionWidth, enabled),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('×', style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted)),
          ),
          _field(_h, SenseSessionStrings.customResolutionHeight, enabled),
          const Spacer(),
          SenseButton(
            key: ValueKey('sense-size-apply-${e.id}'),
            label: trial ? SenseSessionStrings.customResolutionTry : SenseSessionStrings.customResolutionApply,
            size: SenseButtonSize.small,
            onPressed: enabled ? _apply : null,
          ),
        ]),
        if (_wrong)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(SenseSessionStrings.customResolutionRange(e.min, e.max),
                key: ValueKey('sense-size-wrong-${e.id}'),
                style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.warn)),
          )
        else if (trial)
          // Sürüm 12 (FO-A7): the limits are said before the try (prototype `.cres small`).
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(SenseSessionStrings.customResolutionNote(e.min, e.max),
                key: ValueKey('sense-size-note-${e.id}'),
                style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted)),
          ),
      ]),
    );
    if (e.noRights) {
      return Tooltip(
        message: SenseSessionStrings.noRights,
        child: Opacity(opacity: SenseUi.disabledOpacity, child: IgnorePointer(child: row)),
      );
    }
    return enabled ? row : Opacity(opacity: SenseUi.disabledOpacity, child: row);
  }
}
