// Sense Remote (#114): the note that comes when a recording stops:
// "Kayıt kaydedildi · Klasörü aç". The core sends `sense_record_saved` with the folder that
// holds the recording's files (one folder per recording); the button opens it in Explorer /
// Finder. Shown as a pill at the bottom centre of the session window for [holdDuration].
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../common.dart' show globalKey;
import '../../tokens/sense_tokens.dart';

abstract final class SenseRecordStrings {
  static const String saved = 'Kayıt kaydedildi';
  static const String openFolder = 'Klasörü aç';
}

/// Opens [dir] in the system file manager.
Future<void> senseOpenRecordFolder(String dir) async {
  if (dir.isEmpty) return;
  await launchUrl(Uri.directory(dir));
}

abstract final class SenseRecordNotice {
  static const Duration holdDuration = Duration(seconds: 10);
  static OverlayEntry? _entry;
  static Timer? _timer;

  /// Event `sense_record_saved` of the core. False when [evt] is not that event.
  static bool handle(Map<String, dynamic> evt) {
    if (evt['name'] != 'sense_record_saved') return false;
    final dir = (evt['dir'] ?? '').toString();
    if (dir.isNotEmpty) show(dir);
    return true;
  }

  static void show(String dir, {Future<void> Function(String dir)? open}) {
    final overlay = globalKey.currentState?.overlay;
    if (overlay == null) return;
    hide();
    final opener = open ?? senseOpenRecordFolder;
    _entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 0,
        right: 0,
        bottom: 22,
        child: Center(
          child: SenseRecordNoticeBar(
            onOpen: () {
              opener(dir);
              hide();
            },
          ),
        ),
      ),
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

/// The pill: text and one button.
class SenseRecordNoticeBar extends StatelessWidget {
  const SenseRecordNoticeBar({super.key, required this.onOpen});

  final VoidCallback onOpen;

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
          const Text('${SenseRecordStrings.saved} · ', style: style),
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
