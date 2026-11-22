// Sense Remote: switch, setting row and the "managed by the panel" lock (YH T7;
// prototype `.tgl`, `.sw`, `.srow`, `.srow.lock`, `.inline-ok`).
// On = white track, black knob; off = dark track, grey knob. A locked switch is faded,
// cannot be pressed and says "Panelden yönetilir" (C3, TK9 §4).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import '../tokens/theme.dart';
import 'button.dart';

// Texts of this file (only Turkish, T2). They move to strings/common.dart once A2b
// (owner of that file) is merged.
const String kSensePanelManaged = 'Panelden yönetilir';
const String kSenseSaved = 'Kaydedildi';

// Prototype `.tgl` 34×20 (knob 14, inset 3) and the compact `.sw` 28×16 (knob 12, inset 2).
const double _kTrackW = 34, _kTrackH = 20, _kKnob = 14, _kInset = 3;
const double _kTrackWCompact = 28, _kTrackHCompact = 16, _kKnobCompact = 12, _kInsetCompact = 2;

class SenseToggle extends StatelessWidget {
  const SenseToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.locked = false,
    this.compact = false,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
  });

  final bool value;

  /// Null = not available (faded, like [locked] but without the panel text).
  final ValueChanged<bool>? onChanged;

  /// Managed by the panel: faded, cannot be pressed, tooltip "Panelden yönetilir".
  final bool locked;

  /// The smaller `.sw` switch of the session menus (O3–O6).
  final bool compact;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final enabled = !locked && onChanged != null;
    final w = compact ? _kTrackWCompact : _kTrackW;
    final h = compact ? _kTrackHCompact : _kTrackH;
    final knob = compact ? _kKnobCompact : _kKnob;
    final inset = compact ? _kInsetCompact : _kInset;
    final motion = SenseMotion.popupOpen;
    return Opacity(
      opacity: enabled ? 1 : SenseUi.disabledOpacity,
      child: SenseInteractive(
        onTap: enabled ? () => onChanged!(!value) : null,
        focusNode: focusNode,
        autofocus: autofocus,
        semanticLabel: semanticLabel,
        toggled: value,
        tooltip: locked ? kSensePanelManaged : null,
        builder: (context, s) => SenseFocusRing(
          visible: s.focused,
          radius: h / 2,
          child: AnimatedContainer(
            duration: motion.duration,
            curve: motion.curve,
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: value
                  ? SenseColors.text
                  : (s.hovered ? SenseColors.lineStrong : SenseColors.line),
              borderRadius: BorderRadius.circular(h / 2),
            ),
            child: AnimatedAlign(
              duration: motion.duration,
              curve: motion.curve,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.all(inset),
                child: AnimatedContainer(
                  duration: motion.duration,
                  curve: motion.curve,
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value ? SenseColors.bg : SenseColors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Padlock + "Panelden yönetilir" (prototype `.srow .lk`).
class SenseLockedNote extends StatelessWidget {
  const SenseLockedNote({super.key});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SenseLockIcon(),
          const SizedBox(width: SenseUi.iconGap / 2),
          Text(kSensePanelManaged,
              style: SenseTextStyles.of(size: SenseFontSize.caps, color: SenseColors.textMuted)),
        ],
      );
}

/// Small padlock drawn in code (no icon font needed, same in goldens).
class SenseLockIcon extends StatelessWidget {
  const SenseLockIcon({super.key, this.size = SenseFontSize.caps, this.color = SenseColors.textMuted});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _LockPainter(color),
      );
}

class _LockPainter extends CustomPainter {
  _LockPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = w * 0.12;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final body = RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.15, h * 0.45, w * 0.7, h * 0.5), Radius.circular(w * 0.1));
    canvas.drawRRect(body, Paint()..color = color);
    final shackle = Path()
      ..moveTo(w * 0.3, h * 0.47)
      ..lineTo(w * 0.3, h * 0.3)
      ..arcToPoint(Offset(w * 0.7, h * 0.3), radius: Radius.circular(w * 0.2))
      ..lineTo(w * 0.7, h * 0.47);
    canvas.drawPath(shackle, paint);
  }

  @override
  bool shouldRepaint(_LockPainter old) => old.color != color;
}

/// Green "Kaydedildi" next to a setting (YH T4): fades in, stays, fades out.
/// Increase [trigger] after each save to show it again; 0 never shows it.
class SenseSavedNote extends StatefulWidget {
  const SenseSavedNote({super.key, this.trigger = 0});

  final int trigger;

  @override
  State<SenseSavedNote> createState() => _SenseSavedNoteState();
}

class _SenseSavedNoteState extends State<SenseSavedNote> {
  bool _on = false;
  Timer? _timer;

  @override
  void didUpdateWidget(SenseSavedNote old) {
    super.didUpdateWidget(old);
    if (widget.trigger != old.trigger && widget.trigger > 0) {
      _timer?.cancel();
      setState(() => _on = true);
      _timer = Timer(SenseMotion.savedFadeIn.duration + SenseMotion.savedHold.duration, () {
        if (mounted) setState(() => _on = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: _on ? 1 : 0,
        duration: SenseMotion.savedFadeIn.duration,
        curve: SenseMotion.savedFadeIn.curve,
        child: Text(kSenseSaved,
            style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.ok)),
      );
}

/// One setting line (`.srow`): label, optional description, control on the right.
/// [locked]: the label turns secondary and "Panelden yönetilir" is shown under it;
/// the caller must also lock the control itself.
class SenseSettingRow extends StatelessWidget {
  const SenseSettingRow({
    super.key,
    required this.label,
    this.description,
    this.control,
    this.locked = false,
    this.savedTrigger = 0,
    this.last = false,
  });

  final String label;
  final String? description;
  final Widget? control;
  final bool locked;
  final int savedTrigger;

  /// Last row of a group: no dashed line under it.
  final bool last;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: SenseUi.rowPadV),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: SenseTextStyles.of(
                        weight: SenseFontWeight.medium,
                        color: locked ? SenseColors.textSecondary : SenseColors.text)),
                if (description != null)
                  Text(description!,
                      style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
                if (locked) const SenseLockedNote(),
              ],
            ),
          ),
          SenseSavedNote(trigger: savedTrigger),
          if (control != null) ...[
            const SizedBox(width: SenseUi.rowGap),
            control!,
          ],
        ],
      ),
    );
    if (last) return row;
    return CustomPaint(painter: _DashedBottom(), child: row);
  }
}

class _DashedBottom extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Prototype `border-bottom:1px dashed #1b1b22`; nearest token is hover.
    final paint = Paint()
      ..color = SenseColors.hover
      ..strokeWidth = 1;
    const dash = 3.0;
    final y = size.height - 0.5;
    for (var x = 0.0; x < size.width; x += dash * 2) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, size.width), y), paint);
    }
  }

  @override
  bool shouldRepaint(_DashedBottom old) => false;
}

/// Setting row with a switch (most C3 rows).
class SenseToggleRow extends StatelessWidget {
  const SenseToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
    this.locked = false,
    this.savedTrigger = 0,
    this.last = false,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? description;
  final bool locked;
  final int savedTrigger;
  final bool last;

  @override
  Widget build(BuildContext context) => SenseSettingRow(
        label: label,
        description: description,
        locked: locked,
        savedTrigger: savedTrigger,
        last: last,
        control: SenseToggle(
          value: value,
          onChanged: onChanged,
          locked: locked,
          semanticLabel: label,
        ),
      );
}
