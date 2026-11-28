// Sense Remote: what one bar list shows (YH O3–O7), independent of how it is drawn.
// The four list builders (list_specs.dart) fill these from the session backend; the
// list widget (session_list.dart) draws them. Every entry names the RustDesk menu item
// it stands for ([SenseListEntry.rustdesk]), so the correspondence table of O7 is
// checked by a test ("RustDesk'in her oturum seçeneği bir listede").
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../strings/session.dart';
import '../../../tokens/sense_tokens.dart';
import 'backend.dart' show SenseResolution;

sealed class SenseListEntry {
  const SenseListEntry({
    required this.id,
    required this.label,
    required this.rustdesk,
    this.hint,
    this.why,
    this.noRights = false,
  });

  /// Stable id (tests, keys).
  final String id;
  final String label;

  /// The RustDesk menu item(s) this entry stands for (TK9 §3), e.g. "Insert Lock".
  final String rustdesk;

  /// Soft text after the label ("· Mac", "· fare ve klavye gitmez").
  final String? hint;

  /// Sürüm 11 (B2/B15): why the row is grey right now ("Hayalet mod açıkken kullanılamaz").
  /// Shown instead of [hint] while the row cannot be used; every row that is grey for a
  /// reason other than rights carries one (list_specs test).
  final String? why;

  /// The person may not use it (panel rights, plan §2.1): shown locked, not hidden.
  final bool noRights;

  /// The row cannot be used right now (no action behind it). Rights are separate
  /// ([noRights]: lock + "Yetkin yok · panelden").
  bool get disabled;

  /// What the row says after its label: the reason while it is grey, else the hint.
  String? get shownHint => disabled && why != null ? why : hint;
}

/// A row that does something once (`.it` + `›`).
class SenseActionEntry extends SenseListEntry {
  const SenseActionEntry({
    required super.id,
    required super.label,
    required super.rustdesk,
    required this.onTap,
    super.hint,
    super.why,
    super.noRights,
    this.tag,
    this.tagLevel,
    this.confirmQuestion,
    this.confirmDetail,
    this.confirmLabel,
    this.confirmPrimary = false,
    this.toast,
  });

  /// Null = not available right now (faded).
  final VoidCallback? onTap;

  @override
  bool get disabled => onTap == null;

  /// Small tag on the right ("teknik").
  final String? tag;
  final SenseLevel? tagLevel;

  /// Irreversible: the row asks in place first (T7 "yerinde ikinci adım").
  final String? confirmQuestion;

  /// Sürüm 12 (#158): second line of the question (`.ask-d`), e.g. "Bağlantı kopar, …".
  final String? confirmDetail;
  final String? confirmLabel;

  /// The step can be taken back (lock): the confirm button is white (`.btn.pri`), not red.
  final bool confirmPrimary;

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
    super.why,
    super.noRights,
    this.onLevel,
    this.toastAfterChange,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  bool get disabled => onChanged == null;

  /// Sürüm 10 (#116): toast read right after [onChanged] ran; null keeps the default
  /// "label · Açık/Kapalı" (e.g. "yeni bağlantıda geçerli" when the change waits).
  /// Sürüm 11 (B5): may be a Future — the toast then waits for the real result (a recording
  /// that did not start says so instead of "Kayıt · açık").
  final FutureOr<String?> Function()? toastAfterChange;

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
    super.why,
    super.noRights,
  });

  final List<SenseChoice> options;
  final String? value;
  final ValueChanged<String>? onChanged;
  final SenseChoiceStyle style;

  @override
  bool get disabled => onChanged == null;

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
    super.why,
    super.noRights,
  });

  final double min;
  final double max;
  final double value;
  final String Function(double) format;

  /// Called when the drag ends (the setting is written once).
  final ValueChanged<double>? onChanged;

  @override
  bool get disabled => onChanged == null;
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

  @override
  bool get disabled => false;
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
    this.trial,
    super.hint,
    super.why,
    super.noRights,
  });

  /// The fields start with these (the current size), or empty.
  final int? width;
  final int? height;
  final int min;
  final int max;

  /// Null = not available right now (faded).
  final void Function(int width, int height)? onApply;

  /// Sürüm 12 (FO-A7/B7): with a trial the size is tried first and taken back by itself
  /// unless the person keeps it within [SenseResolutionTrial.seconds]; [onApply] is then
  /// not called (the trial applies).
  final SenseResolutionTrial? trial;

  @override
  bool get disabled => onApply == null;
}

/// Sürüm 12 (FO-A7/B7, prototype `cresApply`): a custom resolution is tried; if the person
/// does not say "Koru" within [seconds] the old one comes back by itself (a size the
/// remote screen cannot show must not leave the person without an image). Lives with the
/// session backend, so the countdown goes on when the list is closed.
class SenseResolutionTrial extends ChangeNotifier {
  SenseResolutionTrial(this._apply, this._current);

  /// How long the new size waits for "Koru".
  static const int seconds = 15;

  final void Function(SenseResolution r) _apply;
  final SenseResolution? Function() _current;
  Timer? _timer;
  SenseResolution? _previous;
  SenseResolution? _trying;
  int _left = 0;
  ValueChanged<String>? _note;

  /// A size is being tried.
  bool get active => _trying != null;

  /// The size being tried.
  SenseResolution? get trying => _trying;

  /// The size that comes back.
  SenseResolution? get previous => _previous;

  /// Seconds left before the old size comes back.
  int get secondsLeft => _left;

  /// Applies [next] and starts the countdown. The size to go back to is the current one (a
  /// second try keeps the first size); when it is not known [next] is applied without a
  /// trial. [note] gets the toast text of the end ("Eski çözünürlüğe dönüldü" /
  /// "Çözünürlük korundu: …").
  void start(SenseResolution next, {ValueChanged<String>? note}) {
    _timer?.cancel();
    final previous = (_trying != null && _previous != null) ? _previous : _current();
    _apply(next);
    if (previous == null || previous == next) {
      _clear();
      return;
    }
    _previous = previous;
    _trying = next;
    _left = seconds;
    _note = note;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _left--;
      if (_left <= 0) {
        undo();
      } else {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  /// "Koru": the size stays.
  void keep() {
    final t = _trying;
    if (t == null) return;
    final note = _note;
    _clear();
    note?.call(SenseSessionStrings.resolutionKept(t.label));
  }

  /// "Geri al" or the time ran out: the old size comes back.
  void undo() {
    final p = _previous;
    if (_trying == null || p == null) return;
    final note = _note;
    _clear();
    _apply(p);
    note?.call(SenseSessionStrings.resolutionReverted);
  }

  void _clear() {
    _timer?.cancel();
    _timer = null;
    _trying = null;
    _previous = null;
    _note = null;
    _left = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
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

  @override
  bool get disabled => onPick == null;
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
