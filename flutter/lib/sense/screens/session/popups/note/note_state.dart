// Sense Remote (Sürüm 12, FO-A4, FO-A11): the session note of one connection window — its
// modes, its result, the facts the popup shows and what was done with the note (the ended card
// reads it: "Oturum notu kaydedildi …" or "Not ekle"). Pure Dart; no note text is logged.
import 'package:flutter/foundation.dart';

/// Where the note popup opens from (plan §2.5).
enum SenseNoteMode {
  /// "Bitir" was pressed: Vazgeç · Notsuz bitir · Notu kaydet ve bitir.
  ending,

  /// Eylemler › Oturuma not ekle: Kapat · Notu kaydet.
  mid,

  /// After the connection ended (the ended card's "Not ekle" uses its own field; this mode is
  /// for callers that want the popup there).
  afterEnd,
}

enum SenseNoteAction {
  /// "Notu kaydet" / "Notu kaydet ve bitir" (the text may be empty).
  saved,

  /// "Notsuz bitir".
  skipped,

  /// "Vazgeç" / "Kapat" / "×" / Esc, or another popup took the place.
  cancelled,
}

@immutable
class SenseNoteResult {
  const SenseNoteResult(this.action, [this.text = '']);

  static const SenseNoteResult cancelled = SenseNoteResult(SenseNoteAction.cancelled);

  final SenseNoteAction action;

  /// The note as typed, trimmed ("" when skipped or cancelled).
  final String text;

  /// The connection should end now (ending mode: saved or skipped).
  bool get ends => action != SenseNoteAction.cancelled;

  @override
  bool operator ==(Object other) => other is SenseNoteResult && other.action == action && other.text == text;

  @override
  int get hashCode => Object.hash(action, text);
}

/// What the popup's box shows: Bilgisayar, Süre, Bu oturumda.
@immutable
class SenseNoteFacts {
  const SenseNoteFacts({this.computer = '', this.duration = Duration.zero, this.messages = 0, this.files = 0});

  final String computer;
  final Duration duration;
  final int messages;
  final int files;
}

/// What happened to the note of a connection.
enum SenseNoteStatus { none, saved, skipped }

/// The note of each connection window (the tab key is the peer id). The window registers how a
/// note reaches the core (`session_send_note`, [setSender]); every entry point sends through
/// [send], so the ended card knows a note was saved.
abstract final class SenseSessionNotes {
  static final Map<String, void Function(String note)> _senders = {};
  static final Map<String, ValueNotifier<SenseNoteStatus>> _status = {};
  static final Map<String, String> _text = {};

  static void setSender(String id, void Function(String note) send) => _senders[id] = send;

  /// The window can send a note (the ended card offers "Not ekle" only then).
  static bool canSend(String id) => _senders.containsKey(id);

  static ValueListenable<SenseNoteStatus> status(String id) =>
      _status.putIfAbsent(id, () => ValueNotifier(SenseNoteStatus.none));

  /// The last note saved in this connection (prefills the popup).
  static String lastText(String id) => _text[id] ?? '';

  /// Sends [text] (trimmed) as this connection's note. An empty note is not sent and returns
  /// false; so does a window without a sender.
  static bool send(String id, String text) {
    final t = text.trim();
    final send = _senders[id];
    if (t.isEmpty || send == null) return false;
    send(t);
    _text[id] = t;
    (status(id) as ValueNotifier<SenseNoteStatus>).value = SenseNoteStatus.saved;
    return true;
  }

  /// "Notsuz bitir": the ended card does not offer "Not ekle" again.
  static void markSkipped(String id) {
    final s = status(id) as ValueNotifier<SenseNoteStatus>;
    if (s.value == SenseNoteStatus.none) s.value = SenseNoteStatus.skipped;
  }

  /// A new connection in the same window (Yeniden bağlan): a new note.
  static void reset(String id) {
    _text.remove(id);
    _status[id]?.value = SenseNoteStatus.none;
  }

  /// The window closed.
  static void forget(String id) {
    _senders.remove(id);
    _text.remove(id);
    _status.remove(id)?.dispose();
  }
}
