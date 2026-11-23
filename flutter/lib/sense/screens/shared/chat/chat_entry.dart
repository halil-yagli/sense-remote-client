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
      final where = j.mine ? SenseChatStrings.sentSaved : senseSavedText(j.path);
      return '$kind · ${senseFileSize(j.total)} · $where';
    case SenseFileState.err:
      return '$kind · ${senseFileSize(j.total)} · ${SenseChatStrings.failed}';
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
/// folder chosen in Ayarlar › Gelen dosyalar.
String senseSavedText(String path) {
  final p = path.replaceAll('\\', '/').toLowerCase();
  if (p.isEmpty || p.contains('/downloads/') || p.contains('/indirilenler/')) {
    return SenseChatStrings.savedDownloads;
  }
  return SenseChatStrings.savedIncoming;
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
