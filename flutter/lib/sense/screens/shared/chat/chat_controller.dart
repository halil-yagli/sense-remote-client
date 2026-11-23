// Sense Remote: state of one connection's chat (YH O10, O11 sesli, O12, S12).
// Shared by the Controller window (session/chat_icon) and the Host card (C5):
// both feed it the other side's messages and call events, and give it their
// own [SenseChatFiles] / [SenseChatCall].
//
// S12 (#56): everything lives in this object's memory only. Nothing is written
// to disk; [clear] (connection end) drops it and leaves only the counts for the
// audit line ("N mesaj, N dosya").

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_entry.dart';
import 'data/call.dart';
import 'data/files.dart';

/// Voice call phase (O11). [incoming] is the Host card's "sesli arıyor".
enum SenseCallPhase { idle, calling, incoming, active }

/// A new message or file from the other side, for the notification card.
class SenseChatIncoming {
  const SenseChatIncoming({required this.text, required this.isFile, required this.at});

  /// Message text, or the file name.
  final String text;
  final bool isFile;
  final DateTime at;
}

class SenseChatController extends ChangeNotifier {
  SenseChatController({
    required this.sendText,
    required this.files,
    required this.call,
    DateTime Function()? now,
    this.pollEvery = const Duration(milliseconds: 500),
  }) : _now = now ?? DateTime.now;

  /// Sends a text to the other side (Controller: `session_send_chat`; Host:
  /// `cm_send_chat`).
  final void Function(String text) sendText;
  final SenseChatFiles files;
  final SenseChatCall call;
  final DateTime Function() _now;

  /// File list refresh while the chat is alive.
  final Duration pollEvery;

  final List<SenseChatEntry> _entries = [];
  final Map<String, SenseFileJob> _jobs = {};
  final StreamController<SenseChatIncoming> _incoming = StreamController.broadcast();

  bool _open = false;
  int _unread = 0;
  SenseCallPhase _phase = SenseCallPhase.idle;
  DateTime? _callStart;
  Timer? _poll;
  bool _polling = false;
  bool _disposed = false;
  int _messageCount = 0;
  int _fileCount = 0;

  /// Oldest first.
  List<SenseChatEntry> get entries => List.unmodifiable(_entries);
  SenseFileJob? job(String id) => _jobs[id];

  /// The chat popup is open (not the icon).
  bool get isOpen => _open;
  int get unread => _unread;
  SenseCallPhase get phase => _phase;
  DateTime? get callStart => _callStart;
  DateTime now() => _now();

  /// A transfer is still running (icon: blinking white dot).
  bool get transferring => _jobs.values.any((j) => !j.finished && j.state != SenseFileState.err);

  /// Messages / files of this connection, for the audit line (#56).
  int get messageCount => _messageCount;
  int get fileCount => _fileCount;

  /// New messages and files from the other side.
  Stream<SenseChatIncoming> get incoming => _incoming.stream;

  // ---- open / icon ----

  void open() {
    if (_open && _unread == 0) return;
    _open = true;
    _unread = 0;
    _changed();
  }

  /// "–": back to the icon (O10: no close).
  void minimize() {
    if (!_open) return;
    _open = false;
    _changed();
  }

  // ---- messages ----

  /// Sends what the person typed. Empty text is ignored.
  bool send(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    _entries.add(SenseChatText(mine: true, at: _now(), text: t));
    _messageCount++;
    sendText(t);
    _changed();
    return true;
  }

  /// A message from the other side.
  void receiveText(String text, {DateTime? at}) {
    final t = text.trim();
    if (t.isEmpty) return;
    final when = at ?? _now();
    _entries.add(SenseChatText(mine: false, at: when, text: t));
    _messageCount++;
    if (!_open) _unread++;
    _incoming.add(SenseChatIncoming(text: t, isFile: false, at: when));
    _changed();
  }

  // ---- files ----

  /// Ataç or drop. Each path becomes a file bubble as soon as the bridge gives
  /// it an id.
  Future<void> sendFiles(List<String> paths) async {
    if (paths.isEmpty) return;
    final ids = await files.send(paths);
    if (_disposed) return;
    final at = _now();
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      if (_hasFile(id)) continue;
      final name = i < paths.length ? _baseName(paths[i]) : id;
      _jobs.putIfAbsent(
        id,
        () => SenseFileJob(
          id: id,
          name: name,
          kind: senseFileKind(null, name),
          dir: SenseFileDir.out,
          done: 0,
          total: 0,
          state: SenseFileState.run,
        ),
      );
      _entries.add(SenseChatFileEntry(mine: true, at: at, jobId: id));
      _fileCount++;
    }
    _ensurePolling();
    _changed();
  }

  /// Takes the bridge's job list: updates bubbles, adds received files.
  void applyJobs(List<SenseFileJob> jobs) {
    var changed = false;
    for (final j in jobs) {
      final before = _jobs[j.id];
      _jobs[j.id] = j;
      if (!_hasFile(j.id)) {
        final at = _now();
        _entries.add(SenseChatFileEntry(mine: j.mine, at: at, jobId: j.id));
        _fileCount++;
        if (!j.mine) {
          if (!_open) _unread++;
          _incoming.add(SenseChatIncoming(text: j.name, isFile: true, at: at));
        }
        changed = true;
      } else if (before == null ||
          before.done != j.done ||
          before.state != j.state ||
          before.total != j.total ||
          before.path != j.path) {
        changed = true;
      }
    }
    if (changed) _changed();
  }

  /// Reads the job list once (also used by tests).
  Future<void> refreshFiles() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final list = await files.jobs();
      if (!_disposed) applyJobs(list);
    } finally {
      _polling = false;
    }
  }

  /// Starts reading the job list every [pollEvery] (received files appear
  /// without a send from this side).
  void startPolling() => _ensurePolling();

  void _ensurePolling() {
    if (_disposed || _poll != null || pollEvery <= Duration.zero) return;
    _poll = Timer.periodic(pollEvery, (_) => refreshFiles());
  }

  bool _hasFile(String id) => _entries.any((e) => e is SenseChatFileEntry && e.jobId == id);

  static String _baseName(String path) {
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  // ---- call ----

  Future<void> startCall() async {
    // From "incoming" it answers the other side's call (D3d2: the Host calls
    // the Controller); the call side starts it the same way.
    if (_phase != SenseCallPhase.idle && _phase != SenseCallPhase.incoming) return;
    _setPhase(SenseCallPhase.calling);
    await call.start();
  }

  Future<void> endCall() async {
    if (_phase == SenseCallPhase.idle) return;
    _setPhase(SenseCallPhase.idle);
    await call.end();
  }

  /// Call events from RustDesk (waiting / started / closed / incoming).
  void setPhase(SenseCallPhase p) => _setPhase(p);

  void _setPhase(SenseCallPhase p) {
    if (p == _phase) return;
    _phase = p;
    _callStart = p == SenseCallPhase.active ? _now() : (p == SenseCallPhase.idle ? null : _callStart);
    _changed();
  }

  /// Time in the call so far ("Görüşmede · 01:35").
  Duration get callElapsed {
    final s = _callStart;
    return s == null ? Duration.zero : _now().difference(s);
  }

  // ---- end of connection (S12) ----

  /// Drops every message, file row and call state. The counts stay for the
  /// audit line.
  void clear() {
    _entries.clear();
    _jobs.clear();
    _unread = 0;
    _open = false;
    _phase = SenseCallPhase.idle;
    _callStart = null;
    _poll?.cancel();
    _poll = null;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _entries.clear();
    _jobs.clear();
    _incoming.close();
    super.dispose();
  }
}
