// Sense Remote (Sürüm 12, #162, ST 0–18): the one dialog pattern that replaces RustDesk's
// stock boxes. Same frame as the locked popup design (onaylı popup: Bilgisayar durumu,
// [SensePopupShell]): title + live line in the header, a status box with the message, the
// screen's own fields, and the buttons right-aligned in the footer (`.crb`). No separate
// "done" window (T7); one popup at a time (the dialog manager closes the others).
//
// Also here, because every stock path needs them and they must not depend on common.dart:
//  - [senseMsgBoxLevel]: RustDesk msgbox type → Sense level (icon colours from the tokens);
//  - [SenseDialogField], [SenseDialogCheck]: the field (`.afield`) and check row (`.chk`);
//  - [SenseNotice] / [senseShowNotice]: the top notice with one button (`.recnote`, #159);
//  - [senseShowOverlayToast]: the white pill for messages without a [SenseToastHost] (BotToast).
import 'dart:async';

import 'package:flutter/material.dart' show Material, MaterialType, TextField, InputDecoration, OutlineInputBorder;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';
import 'glyph.dart';
import 'popup_shell.dart';
import 'status_box.dart';
import 'toast.dart';

/// RustDesk msgbox type → Sense level. Null = neutral (no colour).
///  error / re-input-password → hot · success → ok · waits and elevation → warn.
SenseLevel? senseMsgBoxLevel(String type) {
  final t = type.toLowerCase();
  if (t.contains('error') || t == 're-input-password') return SenseLevel.hot;
  if (t.contains('success')) return SenseLevel.ok;
  if (t == 'wait-uac' ||
      t == 'wait-remote-accept-nook' ||
      t == 'on-uac' ||
      t == 'on-foreground-elevated' ||
      t.contains('warn')) {
    return SenseLevel.warn;
  }
  return null;
}

/// One footer button.
class SenseDialogAction {
  const SenseDialogAction(this.label, this.onPressed, {this.kind = SenseButtonKind.normal, this.key});

  final String label;

  /// Null = not available (drawn faded).
  final VoidCallback? onPressed;
  final SenseButtonKind kind;
  final Key? key;
}

/// The dialog. Give it to the dialog manager centred (common.dart `senseDialog`).
class SenseDialog extends StatelessWidget {
  const SenseDialog({
    super.key,
    required this.title,
    this.live,
    this.level,
    this.headline,
    this.message,
    this.children = const [],
    this.actions = const [],
    this.onCancel,
    this.onSubmit,
    this.width = SenseSizes.popupWidthMedium,
    this.animateIn = true,
  });

  /// Header title (13/600).
  final String title;

  /// Grey live line next to the title ("8 sn önce", "Uzak masaüstü").
  final String? live;

  /// Colours the status box (null = neutral line frame).
  final SenseLevel? level;

  /// First line of the status box (coloured by [level]); null = no box.
  final String? headline;

  /// Text under the headline (or alone when there is no headline).
  final String? message;

  /// The screen's own fields under the box.
  final List<Widget> children;
  final List<SenseDialogAction> actions;

  /// Esc and "×".
  final VoidCallback? onCancel;

  /// Enter.
  final VoidCallback? onSubmit;
  final double width;
  final bool animateIn;

  static const double gap = 10;
  static const double buttonGap = 6;

  @override
  Widget build(BuildContext context) {
    final body = <Widget>[];
    final head = headline;
    final text = message;
    if (head != null) {
      body.add(SenseStatusBox(
        level: level ?? SenseLevel.unknown,
        title: head,
        children: [
          if (text != null && text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(text, style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textSecondary)),
            ),
        ],
      ));
    } else if (text != null && text.isNotEmpty) {
      body.add(Text(text, style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textSecondary)));
    }
    for (final c in children) {
      if (body.isNotEmpty) body.add(const SizedBox(height: gap));
      body.add(c);
    }
    final footer = actions.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: buttonGap,
              runSpacing: buttonGap,
              children: [
                for (final a in actions)
                  SenseButton(key: a.key, label: a.label, onPressed: a.onPressed, kind: a.kind),
              ],
            ),
          );
    final shell = SensePopupShell(
      title: title,
      subtitle: live,
      onClose: onCancel,
      animateIn: animateIn,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: body),
      footer: footer,
    );
    return CallbackShortcuts(
      bindings: {
        if (onCancel != null) const SingleActivator(LogicalKeyboardKey.escape): onCancel!,
        if (onSubmit != null) const SingleActivator(LogicalKeyboardKey.enter): onSubmit!,
        if (onSubmit != null) const SingleActivator(LogicalKeyboardKey.numpadEnter): onSubmit!,
      },
      child: Focus(
        autofocus: true,
        child: ConstrainedBox(
          key: const Key('sense-dialog'),
          constraints: BoxConstraints(maxWidth: width, minWidth: width),
          child: shell,
        ),
      ),
    );
  }
}

/// Input field of the dialogs and cards (`.afield`): black ground, line border, a small
/// lock for passwords. [obscure] hides what is typed.
class SenseDialogField extends StatelessWidget {
  const SenseDialogField({
    super.key,
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.autofocus = false,
    this.error = false,
    this.onSubmitted,
    this.onChanged,
    this.maxLength,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final bool autofocus;

  /// Red border (wrong password / code).
  final bool error;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final int? maxLength;
  final TextInputType? keyboardType;

  static const double padH = 10;
  static const double padV = 8;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(SenseRadii.button),
      borderSide: BorderSide(color: error ? SenseColors.dangerText : SenseColors.line),
    );
    return Material(
      type: MaterialType.transparency,
      child: TextField(
        controller: controller,
        autofocus: autofocus,
        obscureText: obscure,
        enableInteractiveSelection: !obscure,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: keyboardType ?? (obscure ? TextInputType.visiblePassword : TextInputType.text),
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        maxLength: maxLength,
        style: SenseTextStyles.bodySmall,
        cursorColor: SenseColors.text,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted),
          counterText: '',
          isDense: true,
          filled: true,
          fillColor: SenseColors.bg,
          contentPadding: const EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          enabledBorder: border,
          border: border,
          focusedBorder: border.copyWith(
              borderSide: BorderSide(color: error ? SenseColors.dangerText : SenseColors.textDim)),
        ),
      ),
    );
  }
}

/// Check row (`.chk`): a 14 px box with a tick and the label.
class SenseDialogCheck extends StatelessWidget {
  const SenseDialogCheck({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  static const double box = 14;

  @override
  Widget build(BuildContext context) {
    final change = onChanged;
    return SenseInteractive(
      onTap: change == null ? null : () => change(!value),
      toggled: value,
      semanticLabel: label,
      builder: (context, s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: box,
            height: box,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: value ? SenseColors.text : SenseColors.bg,
              border: Border.all(color: value || s.hovered || s.focused ? SenseColors.text : SenseColors.lineStrong),
              borderRadius: BorderRadius.circular(SenseRadii.button / 2),
            ),
            child: value ? const SenseGlyph(SenseGlyphKind.check, size: SenseFontSize.hint, color: SenseColors.bg) : null,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(label, style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textSecondary)),
          ),
        ]),
      ),
    );
  }
}

/// A choice list in a dialog (Windows sessions, printers): one row each, the chosen one ticked.
class SenseDialogChoices extends StatelessWidget {
  const SenseDialogChoices({super.key, required this.labels, required this.selected, required this.onSelected});

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: SenseColors.bg,
        border: Border.all(color: SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.category),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < labels.length; i++)
          SenseInteractive(
            key: Key('sense-dialog-choice-$i'),
            onTap: () => onSelected(i),
            selected: i == selected,
            semanticLabel: labels[i],
            builder: (context, s) => Container(
              color: s.hovered ? SenseColors.hover : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(children: [
                SizedBox(
                  width: SenseFontSize.body + 4,
                  child: i == selected
                      ? const SenseGlyph(SenseGlyphKind.check, size: SenseFontSize.body, color: SenseColors.text)
                      : null,
                ),
                Expanded(
                  child: Text(labels[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SenseTextStyles.of(
                          size: SenseFontSize.bodySmall,
                          color: i == selected ? SenseColors.text : SenseColors.textSecondary)),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Top notice with one button (`.recnote`): "Bu bilgisayara kaydedildi · Klasörü aç".
class SenseNotice extends StatelessWidget {
  const SenseNotice({super.key, required this.text, this.level, this.actionLabel, this.onAction});

  final String text;

  /// ok = green text, hot = red text and border; null = white.
  final SenseLevel? level;
  final String? actionLabel;
  final VoidCallback? onAction;

  static const double top = 54;
  static const Duration hold = Duration(seconds: 8);
  static const Duration holdError = Duration(seconds: 6);

  @override
  Widget build(BuildContext context) {
    final hot = level == SenseLevel.hot;
    final color = switch (level) {
      SenseLevel.ok => SenseColors.ok,
      SenseLevel.hot => SenseColors.dangerText,
      SenseLevel.warn => SenseColors.warn,
      _ => SenseColors.text,
    };
    return Container(
      key: const Key('sense-notice'),
      padding: EdgeInsets.fromLTRB(14, 7, actionLabel == null ? 14 : 8, 7),
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(color: hot ? SenseColors.hot.withOpacity(0.55) : SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
        boxShadow: [BoxShadow(color: SenseColors.bg.withOpacity(0.5), blurRadius: 30, offset: const Offset(0, 10))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: Text(text,
              style: SenseTextStyles.of(size: SenseFontSize.bodySmall, weight: SenseFontWeight.bold, color: color)),
        ),
        if (actionLabel != null) ...[
          const SizedBox(width: 10),
          SenseButton(
            key: const Key('sense-notice-action'),
            label: actionLabel!,
            size: SenseButtonSize.small,
            onPressed: onAction,
          ),
        ],
      ]),
    );
  }
}

OverlayEntry? _notice;
Timer? _noticeTimer;

/// Shows [SenseNotice] at the top centre of [overlay]; a new one replaces the old (one at a time).
void senseShowNotice(
  OverlayState? overlay,
  String text, {
  SenseLevel? level,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  if (overlay == null) return;
  _noticeTimer?.cancel();
  _notice?.remove();
  late final OverlayEntry entry;
  void hide() {
    if (identical(_notice, entry)) {
      _notice = null;
      _noticeTimer?.cancel();
      _noticeTimer = null;
    }
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (context) => Positioned(
      top: SenseNotice.top,
      left: 0,
      right: 0,
      child: Center(
        child: SenseNotice(
          text: text,
          level: level,
          actionLabel: actionLabel,
          onAction: onAction == null
              ? null
              : () {
                  hide();
                  onAction();
                },
        ),
      ),
    ),
  );
  _notice = entry;
  overlay.insert(entry);
  _noticeTimer = Timer(level == SenseLevel.hot ? SenseNotice.holdError : SenseNotice.hold, hide);
  SemanticsService.announce(text, TextDirection.ltr);
}

OverlayEntry? _toast;
Timer? _toastTimer;

/// The white pill ([SenseToast]) at the bottom centre of [overlay], for messages that come
/// from the core without a [SenseToastHost] (stock `BotToast.showText`). Errors use [SenseNotice].
void senseShowOverlayToast(OverlayState? overlay, String text, {Duration? hold, bool error = false}) {
  if (overlay == null || text.isEmpty) return;
  if (error) {
    senseShowNotice(overlay, text, level: SenseLevel.hot);
    return;
  }
  _toastTimer?.cancel();
  _toast?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: 0,
      right: 0,
      bottom: SenseToast.bottomGap,
      child: IgnorePointer(child: Center(child: SenseToast(message: text))),
    ),
  );
  _toast = entry;
  overlay.insert(entry);
  _toastTimer = Timer(hold ?? SenseToastController.holdDuration, () {
    if (entry.mounted) entry.remove();
    if (identical(_toast, entry)) _toast = null;
  });
  SemanticsService.announce(text, TextDirection.ltr);
}
