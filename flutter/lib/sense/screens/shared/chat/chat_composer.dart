// Sense Remote: the writing row of the chat (YH O10, O12; onaylı `.pfoot`,
// `.attach`, `.composer input`): ataç · "Mesaj yaz ya da dosya sürükle…" ·
// Gönder. Enter sends, Shift+Enter is a new line.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../sense.dart';
import '../../../strings/chat.dart';

abstract final class SenseChatComposerSize {
  static const EdgeInsets padding = EdgeInsets.symmetric(horizontal: 12, vertical: 10);
  static const double gap = 6;
  static const double attach = 34;
  static const double attachGlyph = 17;
  static const EdgeInsets inputPadding = EdgeInsets.symmetric(horizontal: 10, vertical: 7);
}

class SenseChatComposer extends StatefulWidget {
  const SenseChatComposer({
    super.key,
    required this.onSend,
    this.onAttach,
    this.controller,
    this.focusNode,
  });

  /// Called with the trimmed text; returns true when it was sent (the field
  /// is then cleared).
  final bool Function(String text) onSend;

  /// Ataç. Null hides it (no file side).
  final VoidCallback? onAttach;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  @override
  State<SenseChatComposer> createState() => _SenseChatComposerState();
}

class _SenseChatComposerState extends State<SenseChatComposer> {
  TextEditingController? _ownText;
  FocusNode? _ownFocus;
  bool _focused = false;

  TextEditingController get _text => widget.controller ?? (_ownText ??= TextEditingController());
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _ownText?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  void _send() {
    if (widget.onSend(_text.text)) _text.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: SenseChatComposerSize.padding,
      child: Row(children: [
        if (widget.onAttach != null) ...[
          SenseInteractive(
            key: const Key('sense-chat-attach'),
            onTap: widget.onAttach,
            tooltip: SenseChatStrings.attach,
            semanticLabel: SenseChatStrings.attach,
            builder: (context, s) => SenseFocusRing(
              visible: s.focused,
              child: Container(
                width: SenseChatComposerSize.attach,
                height: SenseChatComposerSize.attach,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: s.hovered ? SenseColors.hover : SenseColors.bg,
                  border: Border.all(color: SenseColors.line),
                  borderRadius: BorderRadius.circular(SenseRadii.button),
                ),
                child: CustomPaint(
                  size: const Size.square(SenseChatComposerSize.attachGlyph),
                  painter: SensePaperclipPainter(
                    color: s.hovered ? SenseColors.text : SenseColors.textMuted,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: SenseChatComposerSize.gap),
        ],
        Expanded(
          child: Container(
            padding: SenseChatComposerSize.inputPadding,
            decoration: BoxDecoration(
              color: SenseColors.bg,
              border: Border.all(color: _focused ? SenseColors.lineStrong : SenseColors.line),
              borderRadius: BorderRadius.circular(SenseRadii.button),
            ),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _send,
                const SingleActivator(LogicalKeyboardKey.numpadEnter): _send,
              },
              child: Material(
                type: MaterialType.transparency,
                child: TextField(
                key: const Key('sense-chat-input'),
                controller: _text,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                cursorColor: SenseColors.text,
                style: SenseTextStyles.body,
                decoration: InputDecoration.collapsed(
                  hintText: SenseChatStrings.hint,
                  hintStyle: SenseTextStyles.body.copyWith(color: SenseColors.textMuted),
                ),
              ),
              ),
            ),
          ),
        ),
        const SizedBox(width: SenseChatComposerSize.gap),
        SenseButton(
          key: const Key('sense-chat-send'),
          label: SenseChatStrings.send,
          kind: SenseButtonKind.on,
          onPressed: _send,
        ),
      ]),
    );
  }
}

/// The paperclip of the attach button (24 viewBox, 1.8 stroke).
class SensePaperclipPainter extends CustomPainter {
  const SensePaperclipPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final g = size.width / 24;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * g
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    Offset p(double x, double y) => Offset(x * g, y * g);
    final path = Path()
      ..moveTo(p(21, 11.5).dx, p(21, 11.5).dy)
      ..lineTo(p(12.4, 20.1).dx, p(12.4, 20.1).dy)
      ..arcToPoint(p(4.6, 12.3), radius: Radius.circular(5.5 * g))
      ..lineTo(p(13.2, 3.7).dx, p(13.2, 3.7).dy)
      ..arcToPoint(p(18.4, 8.9), radius: Radius.circular(3.7 * g))
      ..lineTo(p(9.8, 17.5).dx, p(9.8, 17.5).dy)
      ..arcToPoint(p(7.2, 14.9), radius: Radius.circular(1.8 * g))
      ..lineTo(p(15.1, 7).dx, p(15.1, 7).dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(SensePaperclipPainter old) => old.color != color;
}
