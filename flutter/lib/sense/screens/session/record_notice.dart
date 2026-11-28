// Sense Remote (#114, #136): the session recording's notes.
//
// - Recording stopped and its files are complete: "Bu bilgisayara kaydedildi · Klasörü aç". The core sends
//   `sense_record_saved` {dir, file} (one folder per recording, `file` its first file); the
//   button shows the file selected in Explorer / Finder (the folder when that is not possible).
// - Recording could not start or go on: "Kayıt başlatılamadı · <neden>" (`sense_record_state`
//   with state `failed`); a recording that left no file: `empty`.
// - `sense_record_state` also keeps the real state per peer in [SenseRecordNotice.statusOf]
//   (`started` only once a file really opened), for the session's recording switch (tarama B5).
// Shown as a pill at the bottom centre of the session window for [SenseRecordNotice.holdDuration].
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../common.dart' show globalKey;
import '../../tokens/sense_tokens.dart';

abstract final class SenseRecordStrings {
  /// Sürüm 12 (#156): says where the file is (the Controller, not the Host).
  static const String saved = 'Bu bilgisayara kaydedildi';
  static const String openFolder = 'Klasörü aç';
  static const String failed = 'Kayıt başlatılamadı';
  static const String empty = 'Kayıt dosyası oluşmadı';

  /// The reason after "Kayıt başlatılamadı · " for a core reason code.
  static String failure(String reason) => switch (reason) {
        'izin_yok' => 'bu bilgisayarda kayıt izni yok',
        'klasor' => 'kayıt klasörü açılamadı',
        'dosya' => 'dosya oluşturulamadı',
        'kodek' => 'bu görüntü biçimi kaydedilemiyor',
        _ => 'beklenmeyen bir hata oldu',
      };

  static const String emptyReason = 'kayıt çok kısaydı ya da görüntü gelmedi';
}

/// Opens [dir] in the system file manager.
Future<void> senseOpenRecordFolder(String dir) async {
  if (dir.isEmpty) return;
  await launchUrl(Uri.directory(dir));
}

/// Shows [file] selected in Explorer / Finder; the folder [dir] when there is no file or the
/// file manager could not be asked.
Future<void> senseRevealRecording(String dir, String file) async {
  if (file.isNotEmpty) {
    try {
      if (Platform.isWindows) {
        // explorer.exe always exits with 1, so its result says nothing; `/select,` and the path
        // as two arguments keep a path with spaces intact.
        await Process.start('explorer.exe', ['/select,', file]);
        return;
      }
      if (Platform.isMacOS) {
        final r = await Process.run('open', ['-R', file]);
        if (r.exitCode == 0) return;
      }
    } catch (_) {
      // Fall back to the folder.
    }
  }
  await senseOpenRecordFolder(dir);
}

/// The real recording state of one peer's session (`sense_record_state`).
@immutable
class SenseRecordStatus {
  const SenseRecordStatus(this.state, {this.reason = '', this.display = 0, this.part = 1});

  /// `starting` (switch on, no file yet) | `started` (a file really opened) | `failed` |
  /// `stopped` | `empty` (stopped, no file left).
  final String state;
  final String reason;
  final int display;
  final int part;

  bool get started => state == 'started';
  bool get failed => state == 'failed';
}

abstract final class SenseRecordNotice {
  static const Duration holdDuration = Duration(seconds: 10);
  static OverlayEntry? _entry;
  static Timer? _timer;
  static final Map<String, ValueNotifier<SenseRecordStatus?>> _status = {};

  /// The last recording state the core sent for [peerId] (null before any).
  static ValueNotifier<SenseRecordStatus?> statusOf(String peerId) =>
      _status.putIfAbsent(peerId, () => ValueNotifier<SenseRecordStatus?>(null));

  /// Events `sense_record_saved` and `sense_record_state` of the core. False for other events.
  static bool handle(Map<String, dynamic> evt,
      {Future<void> Function(String dir, String file)? reveal}) {
    switch (evt['name']) {
      case 'sense_record_saved':
        final dir = (evt['dir'] ?? '').toString();
        final file = (evt['file'] ?? '').toString();
        if (dir.isNotEmpty) {
          final opener = reveal ?? senseRevealRecording;
          show(dir, open: (d) => opener(d, file));
        }
        return true;
      case 'sense_record_state':
        final status = parseStatus(evt);
        final id = (evt['id'] ?? '').toString();
        // A failure stops the recording, which then reports `stopped` and `empty`: the failure
        // (and its note) stays until the next start.
        final wasFailed = id.isNotEmpty && (statusOf(id).value?.failed ?? false);
        if (wasFailed && (status.state == 'stopped' || status.state == 'empty')) return true;
        if (id.isNotEmpty) statusOf(id).value = status;
        if (status.failed) {
          showText('${SenseRecordStrings.failed} · ${SenseRecordStrings.failure(status.reason)}');
        } else if (status.state == 'empty') {
          showText('${SenseRecordStrings.empty} · ${SenseRecordStrings.emptyReason}');
        }
        return true;
    }
    return false;
  }

  /// [SenseRecordStatus] from a `sense_record_state` event (fields come as strings or numbers).
  static SenseRecordStatus parseStatus(Map<String, dynamic> evt) {
    int n(Object? v, int d) => int.tryParse('${v ?? ''}') ?? d;
    return SenseRecordStatus(
      (evt['state'] ?? '').toString(),
      reason: (evt['reason'] ?? '').toString(),
      display: n(evt['display'], 0),
      part: n(evt['part'], 1),
    );
  }

  static void show(String dir, {Future<void> Function(String dir)? open}) {
    final opener = open ?? senseOpenRecordFolder;
    _insert(SenseRecordNoticeBar(
      onOpen: () {
        opener(dir);
        hide();
      },
    ));
  }

  /// A note without a button (failure, empty recording).
  static void showText(String text) => _insert(SenseRecordNoticeBar(text: text));

  static void _insert(Widget bar) {
    final overlay = globalKey.currentState?.overlay;
    if (overlay == null) return;
    hide();
    _entry = OverlayEntry(
      builder: (_) => Positioned(left: 0, right: 0, bottom: 22, child: Center(child: bar)),
    );
    overlay.insert(_entry!);
    _timer = Timer(holdDuration, hide);
  }

  static void hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

/// The pill: text and, when [onOpen] is set, the "Klasörü aç" button.
class SenseRecordNoticeBar extends StatelessWidget {
  const SenseRecordNoticeBar({super.key, this.onOpen, this.text = SenseRecordStrings.saved});

  final VoidCallback? onOpen;
  final String text;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      fontFamily: SenseFont.family,
      fontSize: SenseFontSize.bodySmall,
      fontWeight: SenseFontWeight.medium,
      color: SenseColors.bg,
      decoration: TextDecoration.none,
    );
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: const Key('sense-record-notice'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: SenseColors.text,
          borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(onOpen == null ? text : '$text · ', style: style),
          if (onOpen != null)
            GestureDetector(
              key: const Key('sense-record-notice-open'),
              behavior: HitTestBehavior.opaque,
              onTap: onOpen,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  SenseRecordStrings.openFolder,
                  style: style.copyWith(
                    fontWeight: SenseFontWeight.bold,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
