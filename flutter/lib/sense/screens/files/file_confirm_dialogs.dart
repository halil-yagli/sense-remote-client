// Sense Remote (Sürüm 12, #162, UD'nin bıraktığı): the two questions of the remote files
// window in the Sense dialog pattern ([SenseDialog]) instead of RustDesk's stock boxes —
// "the file is already there" (overwrite / skip / stop) and "delete?". The answers are the
// stock ones, so `models/file_model.dart` keeps its flow: overwrite true, skip null, stop
// false; delete true / false. "Do this for all" stays (the check row).
import 'package:flutter/widgets.dart';

import '../../components/button.dart';
import '../../components/sense_dialog.dart';
import '../../strings/common.dart';
import '../../strings/files.dart';
import '../../tokens/sense_tokens.dart';
import '../../tokens/theme.dart';

/// Which delete question ([senseFileDeleteDialog]).
enum SenseFileDeleteKind { file, emptyDir, dirFile }

/// "Bu dosya hedefte zaten var": Aktarımı durdur · Atla · Üzerine yaz (red).
Widget senseFileOverwriteDialog({
  required String path,
  required bool identical,
  required bool showRemember,
  required bool remember,
  required ValueChanged<bool> onRemember,
  required VoidCallback onStop,
  required VoidCallback onSkip,
  required VoidCallback onOverwrite,
  bool animateIn = true,
}) {
  return SenseDialog(
    animateIn: animateIn,
    title: SenseFilesStrings.overwriteTitle,
    live: SenseFilesStrings.title,
    level: SenseLevel.warn,
    headline: SenseFilesStrings.overwriteHeadline,
    message: path,
    onCancel: onStop,
    onSubmit: onOverwrite,
    children: [
      if (identical)
        Text(SenseFilesStrings.overwriteIdentical,
            key: const Key('sense-files-overwrite-identical'),
            style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textSecondary)),
      if (showRemember)
        SenseDialogCheck(
            key: const Key('sense-files-overwrite-remember'),
            label: SenseFilesStrings.overwriteRemember,
            value: remember,
            onChanged: onRemember),
    ],
    actions: [
      SenseDialogAction(SenseFilesStrings.overwriteStop, onStop, key: const Key('sense-files-overwrite-stop')),
      SenseDialogAction(SenseFilesStrings.overwriteSkip, onSkip, key: const Key('sense-files-overwrite-skip')),
      SenseDialogAction(SenseFilesStrings.overwriteGo, onOverwrite,
          kind: SenseButtonKind.danger, key: const Key('sense-files-overwrite-ok')),
    ],
  );
}

/// The headline of a delete question; [index]/[count] when a folder's files are asked one by one.
String senseFileDeleteHeadline(SenseFileDeleteKind kind, {int index = 0, int count = 0}) {
  final head = switch (kind) {
    SenseFileDeleteKind.file => SenseFilesStrings.deleteFile,
    SenseFileDeleteKind.emptyDir => SenseFilesStrings.deleteEmptyDir,
    SenseFileDeleteKind.dirFile => SenseFilesStrings.deleteDirFile,
  };
  return count > 1 ? SenseFilesStrings.deleteCount(head, index, count) : head;
}

/// "Bu dosya silinsin mi?": the path, "Silinen geri alınamaz.", Vazgeç · Sil (red).
Widget senseFileDeleteDialog({
  required String headline,
  required String path,
  required bool showRemember,
  required bool remember,
  required ValueChanged<bool> onRemember,
  required VoidCallback onCancel,
  required VoidCallback onDelete,
  bool animateIn = true,
}) {
  return SenseDialog(
    animateIn: animateIn,
    title: SenseFilesStrings.deleteTitle,
    live: SenseFilesStrings.title,
    level: SenseLevel.hot,
    headline: headline,
    message: path,
    onCancel: onCancel,
    onSubmit: onDelete,
    children: [
      Text(SenseFilesStrings.deleteIrreversible,
          style: SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.dangerText)),
      if (showRemember)
        SenseDialogCheck(
            key: const Key('sense-files-delete-remember'),
            label: SenseFilesStrings.deleteRemember,
            value: remember,
            onChanged: onRemember),
    ],
    actions: [
      SenseDialogAction(SenseCommonStrings.cancel, onCancel, key: const Key('sense-files-delete-cancel')),
      SenseDialogAction(SenseFilesStrings.delete, onDelete,
          kind: SenseButtonKind.danger, key: const Key('sense-files-delete-ok')),
    ],
  );
}
