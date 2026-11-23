// Sense Remote: small pieces of the Controller pages (prototype `.afield`,
// `.ov`, Kimlikle bağlan box). Only library values; no colour or size by hand.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../sense.dart';
import '../../../strings/controller.dart';
import '../data/peers.dart' show senseIdFrom;

// Prototype `.afield`: height 32, side padding 10, gap 7, icon 14; `.ov` 8×10,
// corner 10; `.ov-h` gap 4.
const double _kFieldHeight = 32, _kFieldPadH = 10, _kFieldGap = 7, _kIcon = 14;
const double _kBoxPadV = 8, _kBoxPadH = 10, _kBoxTitleGap = 4;

/// Text field of the Controller pages (search, ID).
class SenseField extends StatelessWidget {
  const SenseField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.search = false,
    this.autofocus = false,
    this.focusNode,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Magnifier in front (search box).
  final bool search;
  final bool autofocus;
  final FocusNode? focusNode;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) => Container(
        height: _kFieldHeight,
        padding: const EdgeInsets.symmetric(horizontal: _kFieldPadH),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.category),
        ),
        child: Row(children: [
          if (search) ...[
            const Icon(Icons.search, size: _kIcon, color: SenseColors.textMuted),
            const SizedBox(width: _kFieldGap),
          ],
          Expanded(
            // TextField needs a Material ancestor; the Sense windows have none.
            child: Material(
              type: MaterialType.transparency,
              child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: autofocus,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              inputFormatters: inputFormatters,
              cursorColor: SenseColors.text,
              style: SenseTextStyles.of(size: SenseFontSize.bodySmall),
              decoration: InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                hintText: hint,
                hintMaxLines: 1,
                hintStyle: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted),
              ),
              ),
            ),
          ),
        ]),
      );
}

/// Message / form box (`.ov`, `.ov.hot`).
class SenseBox extends StatelessWidget {
  const SenseBox({super.key, this.title, this.titleLeading, this.level, this.children = const []});

  final String? title;
  final Widget? titleLeading;

  /// Hot = red frame and title (error); null = plain.
  final SenseLevel? level;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final hot = level == SenseLevel.hot;
    final warn = level == SenseLevel.warn;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: _kBoxPadV, horizontal: _kBoxPadH),
      decoration: BoxDecoration(
        color: SenseColors.bg,
        gradient: hot
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.6],
                colors: [Color.alphaBlend(SenseColors.hot.withOpacity(0.08), SenseColors.bg), SenseColors.bg],
              )
            : null,
        border: Border.all(
            color: hot
                ? SenseColors.hot.withOpacity(0.6)
                : warn
                    ? SenseColors.warn.withOpacity(0.5)
                    : SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: _kBoxTitleGap),
              child: Row(children: [
                if (titleLeading != null) ...[titleLeading!, const SizedBox(width: SenseUi.iconGap + 2)],
                Flexible(
                  child: Text(title!,
                      style: SenseTextStyles.of(
                          weight: SenseFontWeight.bold,
                          color: hot ? SenseColors.dangerText : (warn ? SenseColors.warn : SenseColors.text))),
                ),
              ]),
            ),
          ...children,
        ],
      ),
    );
  }
}

/// Explanation line under a box title (`.hmeta`).
class SenseMeta extends StatelessWidget {
  const SenseMeta(this.text, {super.key, this.color = SenseColors.textMuted});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(text, style: SenseTextStyles.of(size: SenseFontSize.hint, color: color));
}

/// Small faded hint (`.hint2`).
class SenseHint extends StatelessWidget {
  const SenseHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(text,
      style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted, height: 1.5));
}

/// Kimlikle bağlan, in place (not a window): ID field + Bağlan + explanation.
/// The password is asked by the connection window itself.
class SenseConnectByIdBox extends StatefulWidget {
  const SenseConnectByIdBox({super.key, required this.onConnect, this.enabled = true, this.disabledTip});

  final ValueChanged<String> onConnect;

  /// False when the person may not connect (grants).
  final bool enabled;
  final String? disabledTip;

  @override
  State<SenseConnectByIdBox> createState() => _SenseConnectByIdBoxState();
}

class _SenseConnectByIdBoxState extends State<SenseConnectByIdBox> {
  final _text = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.enabled) return;
    final id = senseIdFrom(_text.text);
    if (id == null) {
      setState(() => _invalid = true);
      return;
    }
    setState(() => _invalid = false);
    widget.onConnect(id);
  }

  @override
  Widget build(BuildContext context) => SenseBox(
        key: const Key('sense-id-box'),
        title: SenseControllerStrings.connectById,
        children: [
          const SizedBox(height: 2),
          Row(children: [
            Expanded(
              child: SenseField(
                key: const Key('sense-id-field'),
                controller: _text,
                hint: SenseControllerStrings.idHint,
                autofocus: true,
                onSubmitted: (_) => _submit(),
                onChanged: (_) {
                  if (_invalid) setState(() => _invalid = false);
                },
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]'))],
              ),
            ),
            const SizedBox(width: SenseUi.rowGap - 4),
            SenseButton(
              key: const Key('sense-id-connect'),
              label: widget.enabled ? SenseControllerStrings.connect : SenseControllerStrings.noRight,
              tooltip: widget.enabled ? null : widget.disabledTip,
              kind: SenseButtonKind.primary,
              size: SenseButtonSize.small,
              onPressed: widget.enabled ? _submit : null,
            ),
          ]),
          const SizedBox(height: SenseUi.iconGap),
          if (_invalid)
            SenseMeta(SenseControllerStrings.idInvalid, color: SenseColors.dangerText)
          else
            const SenseHint(SenseControllerStrings.idHelp),
        ],
      );
}
