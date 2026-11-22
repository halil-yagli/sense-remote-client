// Sense Remote: edit a short text in place (YH T7; prototype `.mefld`, `.pen`, `.nmedit`).
// Used for the computer name and place on the Host (#33). Click (or Enter) opens a field
// in the same spot; Enter or leaving the field saves, Esc cancels. No dialog.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';

// Prototype: field corner 6, padding 3×6, at least 180 px wide; pen 11 px.
const double _kFieldRadius = 6, _kFieldPadV = 3, _kFieldPadH = 6, _kFieldMinWidth = 180;
const double _kPen = SenseFontSize.hint;

class SenseInlineEdit extends StatefulWidget {
  const SenseInlineEdit({
    super.key,
    required this.value,
    required this.onSubmitted,
    this.enabled = true,
    this.tooltip,
    this.maxLength = 64,
    this.style,
  });

  final String value;

  /// Called with the trimmed new text; not called when it is empty or unchanged.
  final ValueChanged<String> onSubmitted;

  /// False = plain text (e.g. locked), no pen.
  final bool enabled;
  final String? tooltip;
  final int maxLength;

  /// Text style of both the label and the field; default 13 px · 600.
  final TextStyle? style;

  @override
  State<SenseInlineEdit> createState() => _SenseInlineEditState();
}

class _SenseInlineEditState extends State<SenseInlineEdit> {
  bool _editing = false;
  final TextEditingController _text = TextEditingController();
  final FocusNode _field = FocusNode(debugLabel: 'sense-inline-edit');

  TextStyle get _style => widget.style ?? SenseTextStyles.categoryTitle;

  @override
  void initState() {
    super.initState();
    _field.addListener(() {
      if (!_field.hasFocus && _editing) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _field.dispose();
    super.dispose();
  }

  void _start() {
    _text
      ..text = widget.value
      ..selection = TextSelection(baseOffset: 0, extentOffset: widget.value.length);
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _field.requestFocus();
    });
  }

  void _commit() {
    if (!_editing) return;
    final next = _text.text.trim();
    setState(() => _editing = false);
    if (next.isNotEmpty && next != widget.value) widget.onSubmitted(next);
  }

  void _cancel() {
    if (!_editing) return;
    setState(() => _editing = false);
  }

  double _fieldWidth(double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: _text.text, style: _style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final want = painter.width + _kFieldPadH * 2 + _kPen * 2;
    painter.dispose();
    return math.min(math.max(want, _kFieldMinWidth), maxWidth);
  }

  Widget _editor() => LayoutBuilder(builder: (context, box) {
        final max = box.maxWidth.isFinite ? box.maxWidth : _kFieldMinWidth * 2;
        return CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: _fieldWidth(max),
              child: TextField(
                controller: _text,
                focusNode: _field,
                maxLength: widget.maxLength,
                maxLines: 1,
                style: _style,
                cursorColor: SenseColors.text,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _commit(),
                decoration: InputDecoration(
                  isDense: true,
                  counterText: '',
                  filled: true,
                  fillColor: SenseColors.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: _kFieldPadV, horizontal: _kFieldPadH),
                  enabledBorder: _border(),
                  focusedBorder: _border(),
                  border: _border(),
                ),
              ),
            ),
          ),
        );
      });

  OutlineInputBorder _border() => OutlineInputBorder(
        borderRadius: BorderRadius.circular(_kFieldRadius),
        borderSide: const BorderSide(color: SenseColors.text),
      );

  @override
  Widget build(BuildContext context) {
    if (_editing) return _editor();
    final label = Text(widget.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: _style);
    if (!widget.enabled) return label;
    return SenseInteractive(
      onTap: _start,
      tooltip: widget.tooltip,
      mouseCursor: SystemMouseCursors.text,
      builder: (_, s) => SenseFocusRing(
        visible: s.focused,
        radius: _kFieldRadius,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: s.hovered ? SenseColors.lineStrong : Colors.transparent),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: label),
              const SizedBox(width: SenseUi.iconGap),
              Opacity(
                opacity: s.hovered || s.focused ? 1 : 0,
                child: CustomPaint(
                  size: const Size.square(_kPen),
                  painter: _PenPainter(s.hovered ? SenseColors.text : SenseColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PenPainter extends CustomPainter {
  _PenPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final paint = Paint()
      ..color = color
      ..strokeWidth = w * 0.14
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(w * 0.2, w * 0.8), Offset(w * 0.78, w * 0.22), paint);
    canvas.drawLine(Offset(w * 0.1, w * 0.9), Offset(w * 0.2, w * 0.8), paint..strokeWidth = w * 0.08);
  }

  @override
  bool shouldRepaint(_PenPainter old) => old.color != color;
}
