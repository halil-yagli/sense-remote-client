// Sense Remote (Sürüm 12, ST 7): the body of the Sense TCP tunnel window. Prototype `auxTun`:
// the rule table (Yerel · Uzak · Durum · Kapat; "Dinleniyor" green, "Dinlenemiyor" orange with
// the reason), the empty list, the add form (Yerel port, Uzak adres, Tünel ekle, "N dinleniyor")
// with its check, and the note. A plain widget: rules, errors and actions come from the page.
import 'package:flutter/material.dart' show InputDecoration, Material, MaterialType, TextField;
import 'package:flutter/widgets.dart';

import '../../sense.dart';
import '../../strings/tunnel.dart';
import '../terminal/aux_parts.dart';
import 'tunnel_rules.dart';

const double _kColLocal = 150, _kColStatus = 220, _kColAction = 90, _kColGap = 10;

class SenseTunnelView extends StatefulWidget {
  const SenseTunnelView({
    super.key,
    required this.computer,
    required this.rules,
    required this.onAdd,
    required this.onRemove,
    this.errors = const {},
  });

  /// The computer's name (never its ID).
  final String computer;
  final List<SenseTunnelRule> rules;

  /// Local port → why it is not listening.
  final Map<int, String> errors;
  final ValueChanged<SenseTunnelRule> onAdd;
  final ValueChanged<int> onRemove;

  @override
  State<SenseTunnelView> createState() => _SenseTunnelViewState();
}

class _SenseTunnelViewState extends State<SenseTunnelView> {
  final _local = TextEditingController();
  final _remote = TextEditingController();
  final _localFocus = FocusNode();
  String? _error;

  @override
  void dispose() {
    _local.dispose();
    _remote.dispose();
    _localFocus.dispose();
    super.dispose();
  }

  void _add() {
    final r = senseTunnelValidate(_local.text, _remote.text, widget.rules);
    if (r.rule == null) {
      setState(() => _error = r.error);
      return;
    }
    setState(() => _error = null);
    _local.clear();
    _remote.clear();
    widget.onAdd(r.rule!);
    _localFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final listening = widget.rules.where((r) => !widget.errors.containsKey(r.localPort)).length;
    return Material(
      type: MaterialType.transparency,
      child: ColoredBox(
      color: SenseColors.bg,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                key: const Key('sense-tunnel-table'),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: SenseColors.surface,
                  border: Border.all(color: SenseColors.line),
                  borderRadius: BorderRadius.circular(SenseRadii.popup),
                ),
                child: widget.rules.isEmpty ? _empty() : _table(),
              ),
            ),
            const SizedBox(height: 10),
            _form(listening),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  key: const Key('sense-tunnel-error'),
                  style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.warn, height: 1.5)),
            ],
            const SizedBox(height: 10),
            Text(SenseTunnelStrings.note,
                style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textDim, height: 1.5)),
          ],
        ),
      ),
      ),
    );
  }

  Widget _empty() => Center(
        key: const Key('sense-tunnel-empty'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(SenseTunnelStrings.emptyTitle,
                  style: SenseTextStyles.of(size: SenseFontSize.categoryTitle, weight: SenseFontWeight.bold)),
              const SizedBox(height: 6),
              Text(SenseTunnelStrings.emptyBody(widget.computer),
                  textAlign: TextAlign.center,
                  style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted, height: 1.6)),
            ]),
          ),
        ),
      );

  Widget _row({required List<Widget> cells, required bool header, Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: header ? SenseColors.raised : null,
          border: const Border(bottom: BorderSide(color: SenseColors.line)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: _kColLocal, child: cells[0]),
          const SizedBox(width: _kColGap),
          Expanded(child: cells[1]),
          const SizedBox(width: _kColGap),
          SizedBox(width: _kColStatus, child: cells[2]),
          const SizedBox(width: _kColGap),
          SizedBox(width: _kColAction, child: Align(alignment: Alignment.centerRight, child: cells[3])),
        ]),
      );

  Widget _table() {
    final head = SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim);
    final cell = SenseTextStyles.of(size: SenseFontSize.bodySmall);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _row(header: true, cells: [
        Text(SenseTunnelStrings.colLocal, style: head),
        Text(SenseTunnelStrings.colRemote, style: head),
        Text(SenseTunnelStrings.colStatus, style: head),
        const SizedBox.shrink(),
      ]),
      Expanded(
        child: ListView(padding: EdgeInsets.zero, children: [
          for (final r in widget.rules)
            _row(key: Key('sense-tunnel-rule-${r.localPort}'), header: false, cells: [
              Text('127.0.0.1:${r.localPort}', maxLines: 1, overflow: TextOverflow.ellipsis, style: cell),
              Text(SenseTunnelStrings.remote(widget.computer, r.remote),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: cell),
              _status(widget.errors[r.localPort]),
              SenseButton(
                key: Key('sense-tunnel-close-${r.localPort}'),
                label: SenseTunnelStrings.close,
                size: SenseButtonSize.small,
                onPressed: () => widget.onRemove(r.localPort),
              ),
            ]),
        ]),
      ),
    ]);
  }

  Widget _status(String? error) {
    final ok = error == null;
    final color = ok ? SenseColors.ok : SenseColors.warn;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      ),
      const SizedBox(width: SenseUi.iconGap),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(ok ? SenseTunnelStrings.listening : SenseTunnelStrings.notListening,
              style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: color)),
          if (!ok) ...[
            const SizedBox(height: 2),
            Text(error!, style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim)),
          ],
        ]),
      ),
    ]);
  }

  Widget _field(String label, TextEditingController c, String hint, double width,
          {FocusNode? focus, required Key key}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim)),
        const SizedBox(height: 4),
        Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          decoration: BoxDecoration(
            color: SenseColors.bg,
            border: Border.all(color: SenseColors.line),
            borderRadius: BorderRadius.circular(SenseRadii.button),
          ),
          child: SenseTunnelInput(key: key, controller: c, hint: hint, focusNode: focus, onSubmitted: _add),
        ),
      ]);

  Widget _form(int listening) => Container(
        key: const Key('sense-tunnel-form'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.popup),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          _field(SenseTunnelStrings.localPort, _local, SenseTunnelStrings.localPortHint, 120,
              focus: _localFocus, key: const Key('sense-tunnel-local')),
          const SizedBox(width: 8),
          _field(SenseTunnelStrings.remoteAddress, _remote, SenseTunnelStrings.remoteAddressHint, 200,
              key: const Key('sense-tunnel-remote')),
          const SizedBox(width: 8),
          SenseButton(
            key: const Key('sense-tunnel-add'),
            label: SenseTunnelStrings.add,
            size: SenseButtonSize.small,
            kind: SenseButtonKind.primary,
            onPressed: _add,
          ),
          const Spacer(),
          SenseAuxBadge(key: const Key('sense-tunnel-count'), label: SenseTunnelStrings.listeningCount(listening)),
        ]),
      );
}

/// One-line input of the add form (Enter adds).
class SenseTunnelInput extends StatelessWidget {
  const SenseTunnelInput({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    this.focusNode,
  });

  final TextEditingController controller;
  final String hint;
  final VoidCallback onSubmitted;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      style: SenseTextStyles.of(size: SenseFontSize.bodySmall),
      cursorColor: SenseColors.text,
      maxLines: 1,
      decoration: InputDecoration.collapsed(
        hintText: hint,
        hintStyle: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textDim),
      ),
      onSubmitted: (_) => onSubmitted(),
    );
  }
}
