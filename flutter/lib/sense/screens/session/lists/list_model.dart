// Sense Remote: what one bar list shows (YH O3–O7), independent of how it is drawn.
// The four list builders (list_specs.dart) fill these from the session backend; the
// list widget (session_list.dart) draws them. Every entry names the RustDesk menu item
// it stands for ([SenseListEntry.rustdesk]), so the correspondence table of O7 is
// checked by a test ("RustDesk'in her oturum seçeneği bir listede").
import 'package:flutter/foundation.dart';

import '../../../tokens/sense_tokens.dart';

sealed class SenseListEntry {
  const SenseListEntry({
    required this.id,
    required this.label,
    required this.rustdesk,
    this.hint,
    this.noRights = false,
  });

  /// Stable id (tests, keys).
  final String id;
  final String label;

  /// The RustDesk menu item(s) this entry stands for (TK9 §3), e.g. "Insert Lock".
  final String rustdesk;

  /// Soft text after the label ("· Mac", "· fare ve klavye gitmez").
  final String? hint;

  /// The person may not use it (panel rights, plan §2.1): shown locked, not hidden.
  final bool noRights;
}

/// A row that does something once (`.it` + `›`).
class SenseActionEntry extends SenseListEntry {
  const SenseActionEntry({
    required super.id,
    required super.label,
    required super.rustdesk,
    required this.onTap,
    super.hint,
    super.noRights,
    this.tag,
    this.tagLevel,
    this.confirmQuestion,
    this.confirmLabel,
    this.toast,
  });

  /// Null = not available right now (faded).
  final VoidCallback? onTap;

  /// Small tag on the right ("teknik").
  final String? tag;
  final SenseLevel? tagLevel;

  /// Irreversible: the row asks in place first (T7 "yerinde ikinci adım").
  final String? confirmQuestion;
  final String? confirmLabel;

  /// Toast after the action ran (O7: "seçimde açık kalır + bildirim").
  final String? toast;
}

/// A switch row.
class SenseToggleEntry extends SenseListEntry {
  const SenseToggleEntry({
    required super.id,
    required super.label,
    required super.rustdesk,
    required this.value,
    required this.onChanged,
    super.hint,
    super.noRights,
    this.onLevel,
    this.toastAfterChange,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Sürüm 10 (#116): toast read right after [onChanged] ran; null keeps the default
  /// "label · Açık/Kapalı" (e.g. "yeni bağlantıda geçerli" when the change waits).
  final String? Function()? toastAfterChange;

  /// Status colour of the switch when on (O6: Giriş kilitli orange, Kayıt red); the
  /// frequent box takes the colour of the worst one.
  final SenseLevel? onLevel;
}

class SenseChoice {
  const SenseChoice(this.value, this.label, {this.enabled = true});
  final String value;
  final String label;
  final bool enabled;
}

enum SenseChoiceStyle { segment, radio }

/// Segment ("Sığdır | 1:1") or a radio list (codecs).
class SenseChoiceEntry extends SenseListEntry {
  const SenseChoiceEntry({
    required super.id,
    required super.label,
    required super.rustdesk,
    required this.options,
    required this.value,
    required this.onChanged,
    this.style = SenseChoiceStyle.segment,
    super.hint,
    super.noRights,
  });

  final List<SenseChoice> options;
  final String? value;
  final ValueChanged<String>? onChanged;
  final SenseChoiceStyle style;

  String? get valueLabel {
    for (final o in options) {
      if (o.value == value) return o.label;
    }
    return null;
  }
}

/// A slider with its value on the right (custom scale, quality, fps, trackpad).
class SenseSliderEntry extends SenseListEntry {
  const SenseSliderEntry({
    required super.id,
    required super.label,
    required super.rustdesk,
    required this.min,
    required this.max,
    required this.value,
    required this.format,
    required this.onChanged,
    super.hint,
    super.noRights,
  });

  final double min;
  final double max;
  final double value;
  final String Function(double) format;

  /// Called when the drag ends (the setting is written once).
  final ValueChanged<double>? onChanged;
}

/// Read-only row (keyboard shortcuts).
class SenseInfoEntry extends SenseListEntry {
  const SenseInfoEntry({
    required super.id,
    required super.label,
    required super.rustdesk,
    this.detail,
  });

  final String? detail;
}

/// Two number fields and "Uygula" (custom resolution of a virtual display, R5). The size
/// is applied only when [senseCustomSizeValid] accepts it; nothing is written while typing.
class SenseSizeInputEntry extends SenseListEntry {
  const SenseSizeInputEntry({
    required super.id,
    required super.label,
    required super.rustdesk,
    required this.width,
    required this.height,
    required this.onApply,
    this.min = kSenseCustomSizeMin,
    this.max = kSenseCustomSizeMax,
    super.hint,
    super.noRights,
  });

  /// The fields start with these (the current size), or empty.
  final int? width;
  final int? height;
  final int min;
  final int max;

  /// Null = not available right now (faded).
  final void Function(int width, int height)? onApply;
}

/// Limits of the custom resolution fields (RustDesk allows four digits; a virtual display
/// below 320 px or above 8K is not useful).
const int kSenseCustomSizeMin = 320;
const int kSenseCustomSizeMax = 7680;

/// The text of both fields is a size inside the limits.
bool senseCustomSizeValid(String w, String h, {int min = kSenseCustomSizeMin, int max = kSenseCustomSizeMax}) {
  final x = int.tryParse(w.trim()), y = int.tryParse(h.trim());
  return x != null && y != null && x >= min && x <= max && y >= min && y <= max;
}

class SenseTile {
  const SenseTile(this.value, this.title, this.sub);
  final int value;
  final String title;
  final String? sub;
}

/// The display tiles of the Ekranlar list (1 ana · 2 · 3 · Tümü).
class SenseTilesEntry extends SenseListEntry {
  const SenseTilesEntry({
    required super.id,
    required super.label,
    required super.rustdesk,
    required this.tiles,
    required this.value,
    required this.onPick,
  });

  final List<SenseTile> tiles;
  final int value;
  final ValueChanged<int>? onPick;
}

/// A closable category under the frequent box.
class SenseListSection {
  const SenseListSection({
    required this.id,
    required this.title,
    required this.entries,
    this.summary,
  });

  final String id;
  final String title;
  final String? summary;
  final List<SenseListEntry> entries;

  /// Worst status of the switches that are on (T6: closed category shows it).
  SenseLevel? get level => senseEntriesLevel(entries);
}

/// One list.
class SenseListSpec {
  const SenseListSpec({
    required this.title,
    required this.frequent,
    required this.sections,
    this.chip,
    this.chipLevel,
  });

  final String title;

  /// The state chip next to the title ("Ekran 1", "Dengeli", "Kayıt").
  final String? chip;
  final SenseLevel? chipLevel;
  final List<SenseListEntry> frequent;
  final List<SenseListSection> sections;

  /// Colour of the frequent box frame (O7: "çerçeve durum renginde").
  SenseLevel? get frequentLevel => senseEntriesLevel(frequent);

  /// All entries, frequent first (tests).
  Iterable<SenseListEntry> get allEntries sync* {
    yield* frequent;
    for (final s in sections) {
      yield* s.entries;
    }
  }
}

SenseLevel? senseEntriesLevel(Iterable<SenseListEntry> entries) {
  final levels = <SenseLevel>[
    for (final e in entries)
      if (e is SenseToggleEntry && e.value && e.onLevel != null) e.onLevel!,
  ];
  if (levels.isEmpty) return null;
  return senseWorstLevel(levels);
}
