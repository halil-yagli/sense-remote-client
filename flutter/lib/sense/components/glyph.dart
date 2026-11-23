// Sense Remote: small marks that used to be typed as text (G1).
// Poppins has no ✓ ✕ ✎ ← → ↑ ↓ ⋮ ▾, so a typed mark fell back to the system font
// (other stroke weight; a missing-glyph box on Linux / older macOS and in goldens).
// These are drawn from the Material icon font instead. Screens may also use
// `Icons.*` directly; this only keeps the size and colour next to text in one place.
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../tokens/sense_tokens.dart';
import 'caret.dart';

enum SenseGlyphKind {
  /// ✓ done / selected.
  check,

  /// ✕ wrong / remove.
  cross,

  /// ✎ edit.
  pen,

  /// ← previous.
  left,

  /// → next.
  right,

  /// ↑ upload / sent.
  up,

  /// ↓ download / received.
  down,

  /// ⋮⋮ drag handle.
  drag,

  /// ▾ list / menu opener (drawn, like `SenseSelect`).
  caretDown,
}

class SenseGlyph extends StatelessWidget {
  const SenseGlyph(
    this.kind, {
    super.key,
    this.size = SenseFontSize.bodySmall,
    this.color,
    this.semanticLabel,
  });

  final SenseGlyphKind kind;

  /// Edge in logical px; match the font size of the text next to it.
  final double size;

  /// Null = the surrounding text colour (`DefaultTextStyle`), else secondary text.
  final Color? color;

  /// Read by screen readers; null = decorative (excluded).
  final String? semanticLabel;

  static const Map<SenseGlyphKind, IconData> _icons = {
    SenseGlyphKind.check: Icons.check_rounded,
    SenseGlyphKind.cross: Icons.close_rounded,
    SenseGlyphKind.pen: Icons.edit_outlined,
    SenseGlyphKind.left: Icons.arrow_back_rounded,
    SenseGlyphKind.right: Icons.arrow_forward_rounded,
    SenseGlyphKind.up: Icons.arrow_upward_rounded,
    SenseGlyphKind.down: Icons.arrow_downward_rounded,
    SenseGlyphKind.drag: Icons.drag_indicator_rounded,
  };

  /// The Material icon of [kind]; null for [SenseGlyphKind.caretDown] (drawn).
  static IconData? iconOf(SenseGlyphKind kind) => _icons[kind];

  /// For use inside `Text.rich` ("Ağ ↓ 12 · ↑ 3"): sits on the text's middle line.
  static WidgetSpan span(SenseGlyphKind kind, {double size = SenseFontSize.bodySmall, Color? color}) =>
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: SenseGlyph(kind, size: size, color: color),
      );

  @override
  Widget build(BuildContext context) {
    final c = color ?? DefaultTextStyle.of(context).style.color ?? SenseColors.textSecondary;
    final Widget mark = kind == SenseGlyphKind.caretDown
        ? SenseCaret(direction: SenseCaretDirection.down, size: size, color: c, small: true)
        : Icon(_icons[kind], size: size, color: c);
    final label = semanticLabel;
    if (label == null) return ExcludeSemantics(child: mark);
    return Semantics(label: label, child: ExcludeSemantics(child: mark));
  }
}
