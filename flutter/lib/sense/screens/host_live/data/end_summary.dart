// Sense Remote: what the Host's "Bağlantı sona erdi" card says (FH-A3; prototype `hostEndCard`):
// who ended it, how long it lasted, how many messages and files the chat held ("sohbet
// silindi", #56). The numbers are taken while the connection is live: when it ends the chat
// is dropped from memory, so the card could not count it afterwards. Counts only, never the
// content (no chat text, no file names).

import '../../shared/chat/chat_entry.dart';

class SenseHostEndInfo {
  const SenseHostEndInfo({this.duration, this.messages = 0, this.files = 0, this.byHost = false});

  /// How long the connection lasted; null = not known.
  final Duration? duration;
  final int messages;
  final int files;

  /// This computer's own "Bağlantıyı bitir" ended it.
  final bool byHost;
}

/// Messages and files of a chat's entries.
({int messages, int files}) senseHostChatCounts(Iterable<SenseChatEntry> entries) {
  var messages = 0, files = 0;
  for (final e in entries) {
    if (e is SenseChatText) messages++;
    if (e is SenseChatFileEntry) files++;
  }
  return (messages: messages, files: files);
}

class _Rec {
  Duration? duration;
  int messages = 0;
  int files = 0;
  bool byHost = false;
  bool wasLive = false;
}

class SenseHostEndTracker {
  final Map<int, _Rec> _recs = {};

  /// One reading of a connection. While it is [live] the duration and counts follow it; on the
  /// reading where it is first seen ended the duration is frozen from [connectedFor] and the
  /// counts are read one last time (the chat is still in memory then). [chat] is the
  /// connection's chat entries, null when it has none.
  void observe(int id,
      {required bool live, Duration? connectedFor, Iterable<SenseChatEntry>? chat}) {
    final r = _recs.putIfAbsent(id, _Rec.new);
    if (live) {
      r.wasLive = true;
      r.duration = connectedFor;
    } else if (r.wasLive) {
      r.wasLive = false;
      r.duration = connectedFor ?? r.duration;
    }
    if (chat != null) {
      final n = senseHostChatCounts(chat);
      r.messages = n.messages;
      r.files = n.files;
    }
  }

  /// "Bağlantıyı bitir" was pressed here for [id].
  void markEndedByHost(int id) => (_recs[id] ??= _Rec()).byHost = true;

  SenseHostEndInfo? infoFor(int id) {
    final r = _recs[id];
    if (r == null) return null;
    return SenseHostEndInfo(
        duration: r.duration, messages: r.messages, files: r.files, byHost: r.byHost);
  }

  /// Drops what belongs to connections that are no longer in the list.
  void forget(Set<int> keep) => _recs.removeWhere((id, _) => !keep.contains(id));
}
