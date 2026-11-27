// Sense Remote: what the shared chat shows (YH O10, O12; H4 the same). Plain
// values, kept only in memory (S12, #56): nothing here is written to disk.

import '../../../strings/chat.dart';

/// Direction of a file transfer: "out" = this side sends (arrow up), "in" =
/// this side receives (arrow down).
enum SenseFileDir { out, incoming }

/// Transfer state as the bridge reports it (§2.6 `state`).
enum SenseFileState { run, ok, err, resume }

enum SenseFileKind { image, video, doc }

/// One file transfer (`session_sense_file_jobs` row, §2.6).
class SenseFileJob {
  const SenseFileJob({
    required this.id,
    required this.name,
    required this.kind,
    required this.dir,
    required this.done,
    required this.total,
    required this.state,
    this.path = '',
    this.error = '',
    this.folder = '',
    this.dirName = '',
    this.confirm = '',
  });

  final String id;
  final String name;
  final SenseFileKind kind;
  final SenseFileDir dir;

  /// Bytes so far / all bytes.
  final int done;
  final int total;
  final SenseFileState state;

  /// Where the received file was saved (empty while running or when sending).
  final String path;

  /// Why it failed (#122): `stalled`, `permission`, `refused`, `not_saved`,
  /// `receiver`, `link_lost_not_resumed`, `failed`; empty otherwise.
  final String error;

  /// Where the file landed (#122): `downloads`, `chosen` (Ayarlar › Gelen
  /// dosyalar, named by [dirName]) or empty while unknown.
  final String folder;
  final String dirName;

  /// Sending side (#122): `yes` = the receiver said it saved the file, `wait`
  /// = sent, no answer yet (no folder is claimed), empty = unknown.
  final String confirm;

  /// The name a received file was saved under ("a (1).png" when "a.png" was
  /// taken); the sent name otherwise.
  String get savedName {
    if (mine || path.isEmpty) return name;
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    final leaf = i < 0 ? path : path.substring(i + 1);
    return leaf.isEmpty ? name : leaf;
  }

  bool get finished => state == SenseFileState.ok;
  bool get mine => dir == SenseFileDir.out;

  /// 0..1.
  double get progress {
    if (finished) return 1;
    if (total <= 0) return 0;
    return (done / total).clamp(0.0, 1.0);
  }

  /// Parses one job of the bridge JSON. Unknown or broken fields fall back to
  /// safe values; a job without an id is dropped (null).
  static SenseFileJob? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final name = raw['name']?.toString() ?? '';
    int toInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    return SenseFileJob(
      id: id,
      name: name,
      kind: senseFileKind(raw['kind']?.toString(), name),
      dir: raw['dir'] == 'in' ? SenseFileDir.incoming : SenseFileDir.out,
      done: toInt(raw['done']),
      total: toInt(raw['total']),
      state: switch (raw['state']) {
        'ok' => SenseFileState.ok,
        'err' => SenseFileState.err,
        'resume' => SenseFileState.resume,
        _ => SenseFileState.run,
      },
      path: raw['path']?.toString() ?? '',
      error: raw['error']?.toString() ?? '',
      folder: raw['folder']?.toString() ?? '',
      dirName: raw['dir_name']?.toString() ?? '',
      confirm: raw['confirm']?.toString() ?? '',
    );
  }
}

/// Kind from the bridge's `kind` ("image" / "video" / anything else), or from the
/// file extension when it is missing.
SenseFileKind senseFileKind(String? kind, String name) {
  switch (kind) {
    case 'image':
      return SenseFileKind.image;
    case 'video':
      return SenseFileKind.video;
    case 'doc':
      return SenseFileKind.doc;
  }
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  const images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp', 'tif', 'tiff'};
  const videos = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', 'wmv'};
  if (images.contains(ext)) return SenseFileKind.image;
  if (videos.contains(ext)) return SenseFileKind.video;
  return SenseFileKind.doc;
}

String senseFileKindLabel(SenseFileKind k) => switch (k) {
      SenseFileKind.image => SenseChatStrings.kindImage,
      SenseFileKind.video => SenseChatStrings.kindVideo,
      SenseFileKind.doc => SenseChatStrings.kindDoc,
    };

/// "2,4 MB", "1,2 GB", "312 KB" (prototype `fmt`, Turkish decimal comma).
String senseFileSize(int bytes) {
  String one(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
  if (bytes >= 1000000000) return '${one(bytes / 1e9)} GB';
  if (bytes >= 1000000) return '${one(bytes / 1e6)} MB';
  final kb = (bytes / 1e3).round();
  return '${kb < 1 ? 1 : kb} KB';
}

/// "17:10".
String senseChatTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "01:35" (minutes may pass 99).
String senseCallClock(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The state line under the file name (O12):
///   "Video · İndiriliyor · %49 · 90,5 MB / 184,0 MB"
///   "Resim · 2,4 MB · Gönderildi, karşıda İndirilenler’e kaydedildi"
String senseFileLine(SenseFileJob j) {
  final kind = senseFileKindLabel(j.kind);
  switch (j.state) {
    case SenseFileState.ok:
      final where = j.mine
          ? senseSentText(j)
          : senseSavedText(j.path, folder: j.folder, dirName: j.dirName);
      return '$kind · ${senseFileSize(j.total)} · $where';
    case SenseFileState.err:
      final why = SenseChatStrings.failReason(j.error);
      final tail = why.isEmpty ? '' : ' · $why';
      return '$kind · ${senseFileSize(j.total)} · ${SenseChatStrings.failed}$tail';
    case SenseFileState.run:
    case SenseFileState.resume:
      final verb = j.state == SenseFileState.resume
          ? SenseChatStrings.resuming
          : (j.mine ? SenseChatStrings.sending : SenseChatStrings.receiving);
      final pct = (j.progress * 100).floor();
      return '$kind · $verb · %$pct · ${senseFileSize(j.done)} / ${senseFileSize(j.total)}';
  }
}

/// Saved-to text of a received file: İndirilenler unless the file went to the
/// folder chosen in Ayarlar › Gelen dosyalar (by its name when the core gives
/// it, #122; an older core gives only the path).
String senseSavedText(String path, {String folder = '', String dirName = ''}) {
  if (folder == 'downloads') return SenseChatStrings.savedDownloads;
  if (folder == 'chosen') {
    return dirName.isEmpty ? SenseChatStrings.savedIncoming : SenseChatStrings.savedIn(dirName);
  }
  final p = path.replaceAll('\\', '/').toLowerCase();
  if (p.isEmpty || p.contains('/downloads/') || p.contains('/indirilenler/')) {
    return SenseChatStrings.savedDownloads;
  }
  return SenseChatStrings.savedIncoming;
}

/// Sent text (#122): "kaydedildi" only on the receiver's own answer, with the
/// folder it really went to; without an answer just "Gönderildi".
String senseSentText(SenseFileJob j) {
  switch (j.confirm) {
    case 'wait':
      return SenseChatStrings.sent;
    case 'yes':
      if (j.folder == 'downloads') return SenseChatStrings.sentSaved;
      if (j.folder == 'chosen') {
        return j.dirName.isEmpty
            ? SenseChatStrings.sentSavedChosen
            : SenseChatStrings.sentSavedIn(j.dirName);
      }
      return SenseChatStrings.sentSavedThere;
  }
  // An older core says nothing about it: its old text.
  return SenseChatStrings.sentSaved;
}

/// A row of the chat: a text message or a file.
sealed class SenseChatEntry {
  const SenseChatEntry({required this.mine, required this.at});

  /// Written / sent by this side (white bubble on the right).
  final bool mine;
  final DateTime at;
}

class SenseChatText extends SenseChatEntry {
  const SenseChatText({required super.mine, required super.at, required this.text});

  final String text;
}

class SenseChatFileEntry extends SenseChatEntry {
  const SenseChatFileEntry({required super.mine, required super.at, required this.jobId});

  final String jobId;
}
