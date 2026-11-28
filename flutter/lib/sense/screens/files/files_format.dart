// Sense Remote (#155): sizes, dates and labels of the remote files window, in the
// prototype's spelling ("742 MB", "4,2 KB", "1,92 GB", "28 Kas 2026 00:38").
import '../../../consts.dart';
import '../../../models/file_model.dart';
import '../../strings/files.dart';

/// Decimal units like the prototype `fmSize`; Turkish decimal comma.
String senseFileSize(num bytes) {
  final b = bytes.toDouble();
  String fixed(double v, int digits) => v.toStringAsFixed(digits).replaceAll('.', ',');
  if (b < 1e3) return '${b.round()} B';
  if (b < 1e6) return '${fixed(b / 1e3, 1)} KB';
  if (b < 1e9) return '${fixed(b / 1e6, b < 1e7 ? 1 : 0)} MB';
  return '${fixed(b / 1e9, 2)} GB';
}

/// "28 Kas 2026 00:38" from a local time.
String senseFileDate(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.day)} ${SenseFilesStrings.months[t.month - 1]} ${t.year} ${two(t.hour)}:${two(t.minute)}';
}

/// Modified date of an entry; drives and entries without a time show nothing.
String senseEntryDate(Entry e) => e.isDrive || e.modifiedTime <= 0 ? '' : senseFileDate(e.lastModified());

/// "Windows", "macOS", "Linux" from a RustDesk platform name.
String senseOsName(String platform) {
  switch (platform) {
    case kPeerPlatformWindows:
      return 'Windows';
    case kPeerPlatformMacOS:
      return 'macOS';
    case kPeerPlatformLinux:
      return 'Linux';
    case kPeerPlatformAndroid:
      return 'Android';
    default:
      return platform;
  }
}

/// Last part of a path, for both separators.
String senseBaseName(String path) {
  final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
  final i = trimmed.lastIndexOf(RegExp(r'[\\/]'));
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}

/// Breadcrumb parts of a folder path: ("C:", "C:\"), ("Users", "C:\Users") …
/// The first crumb (Bu bilgisayar / Sürücüler) is added by the panel.
List<(String label, String path)> senseCrumbs(String path, {required bool windows}) {
  if (path.isEmpty || path == '/') return const [];
  final out = <(String, String)>[];
  if (windows) {
    final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    var acc = '';
    for (final p in parts) {
      acc = acc.isEmpty ? '$p\\' : (acc.endsWith('\\') ? '$acc$p' : '$acc\\$p');
      out.add((p, acc));
    }
  } else {
    var acc = '';
    for (final p in path.split('/').where((p) => p.isNotEmpty)) {
      acc = '$acc/$p';
      out.add((p, acc));
    }
  }
  return out;
}
