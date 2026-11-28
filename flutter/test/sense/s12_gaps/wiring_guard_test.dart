// Sense Remote (Sürüm 12, TS): the wiring the unit and golden tests cannot see.
//
// The screens, the cards and the Rust core each have their own tests. What none of them can
// catch is a join that was never made or that drifted: the screenshot path that must never
// ask where to save, the card layer a window must mount, the hotkey hook, and the names the
// Dart side and the core must spell the same (peer messages, events, the frame-rate limits).
// These are reads of the source files, not widget runs; they are fast and need no device.
//
// Paths are relative to `flutter/` (where `flutter test` runs). Core checks skip when
// `../src` is not in the checkout.
import 'dart:io';

import 'package:flutter_hbb/sense/screens/session/data/frame_rate.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

/// The text from [start] up to (not including) [end]; fails the test with a clear reason when
/// a marker is gone (the file was reshaped: update the marker, do not delete the guard).
String _between(String source, String start, String end) {
  final a = source.indexOf(start);
  expect(a, isNonNegative, reason: 'marker not found: $start');
  final b = source.indexOf(end, a + start.length);
  expect(b, isNonNegative, reason: 'marker not found: $end');
  return source.substring(a, b);
}

const _core = '../src/sense/peer_msg.rs';
final String? _noCore = File(_core).existsSync() ? null : 'the core (../src) is not in this checkout';

Iterable<String> _all(RegExp re, String text) => re.allMatches(text).map((m) => m.group(1)!);

void main() {
  group('#159 screenshot: saved without a question', () {
    // Lazy: a missing marker must fail inside a test, not while the file is being collected.
    late final String model = _read('lib/models/model.dart');
    late final String handler =
        _between(model, '\n  _handleScreenshot(', '\n  /// Sense Remote (Sürüm 12, #159): the screenshot goes straight');
    late final String saver = _between(model, 'Future<void> _senseSaveScreenshot(', '\n  _handlePrinterRequest(');

    test('the Sense branch is first and returns before any stock box or save picker', () {
      expect(
        RegExp(r'if \(kSenseDialogs\) \{\s*_senseSaveScreenshot\(evt, sessionId, peerId\);\s*return;\s*\}').hasMatch(handler),
        isTrue,
        reason: 'kSenseDialogs → _senseSaveScreenshot → return',
      );
      final branch = handler.indexOf('if (kSenseDialogs)');
      expect(branch, lessThan(handler.indexOf('FilePicker')));
      expect(branch, lessThan(handler.indexOf('msgBox(')));
    });

    test('the stock "Save as…" picker stays as the fallback (nothing deleted)', () {
      expect(handler, contains('FilePicker.platform.saveFile'));
      expect(handler, contains('screenshot-action-tip'));
    });

    test('the Sense path never asks: no picker, no stock box, no dialog', () {
      for (final banned in ['FilePicker', 'saveFile', 'msgBox(', 'dialogManager', 'showLoading']) {
        expect(saver.contains(banned), isFalse, reason: 'the Sense screenshot path must not use $banned');
      }
    });

    test('it saves to Downloads under the computed name and offers "Klasörü aç"', () {
      expect(saver, contains('getDownloadsDirectory()'));
      expect(saver, contains('senseScreenshotFileName('));
      expect(saver, contains('senseScreenshotTarget(dir, name'));
      expect(saver, contains(r"action: '0:$path'"));
      expect(saver, contains('SenseConnectStrings.screenshotSaved'));
      expect(saver, contains('SenseConnectStrings.openFolder'));
      expect(saver, contains('senseRevealFile(path)'));
    });

    test('with no Downloads folder the pending screenshot is cancelled, not left hanging', () {
      expect(saver, contains("action: '2'"));
      expect(saver, contains('SenseConnectStrings.screenshotNoFolder'));
    });
  });

  group('#164 the connecting cards are mounted by each window', () {
    test('screen session, terminal and tunnel windows attach their own kind', () {
      expect(
        RegExp(r'SenseConnectCards\.attach\(widget\.id,\s*kind: SenseConnectKind\.screen').hasMatch(_read('lib/desktop/pages/remote_page.dart')),
        isTrue,
      );
      expect(
        RegExp(r'SenseConnectCards\.attach\(widget\.id,\s*kind: SenseConnectKind\.terminal').hasMatch(_read('lib/desktop/pages/terminal_page.dart')),
        isTrue,
      );
      expect(
        RegExp(r'SenseConnectCards\.attach\(widget\.id,\s*kind: SenseConnectKind\.tunnel').hasMatch(_read('lib/desktop/pages/port_forward_page.dart')),
        isTrue,
      );
    });

    test('every window that attaches also removes the card controller when it closes', () {
      for (final f in ['remote_page', 'terminal_page', 'port_forward_page']) {
        expect(_read('lib/desktop/pages/$f.dart'), contains('SenseConnectCards.remove('), reason: f);
      }
    });

    // Plan §2.5 (DK): "UD ve TT kendi pencerelerinde SenseConnectCards.attach çağırır". The file
    // window still opens with the stock "Connecting..." loading box, so a failed login there
    // (offline, wrong password, busy) reaches the stock box instead of a Sense card. The test
    // switches itself on the day the window attaches the card.
    final filesAttach = _read('lib/desktop/pages/file_manager_page.dart').contains('SenseConnectCards.attach');
    test('the file transfer window mounts the card layer (SenseConnectKind.file)', () {
      expect(_read('lib/desktop/pages/file_manager_page.dart'), contains('SenseConnectKind.file'));
      expect(_read('lib/desktop/pages/file_manager_page.dart'), isNot(contains("showLoading(translate('Connecting...')")));
    }, skip: filesAttach ? false : 'OPEN (UD): file_manager_page.dart does not attach SenseConnectCards yet');
  });

  group('#160 hotkeys reach the favourites before the remote', () {
    test('Ctrl+Alt+Shift+1–9 is taken in handleKeyEvent ahead of the view-only and remote branches', () {
      final head = _between(_read('lib/models/input_model.dart'), 'KeyEventResult handleKeyEvent(KeyEvent e) {', 'if (isViewCamera)');
      final hook = head.indexOf('SenseFavoritesHotkeys.handle(e)');
      expect(hook, isNonNegative);
      expect(hook, lessThan(head.indexOf('if (isViewOnly)')));
    });
  });

  group('names the Dart side and the core must spell the same', () {
    test('every Sense peer message the UI names exists in the core (peer_msg.rs)', () {
      final rust = _all(RegExp(r'"(sense\.[a-z-]+)"'), _read(_core)).toSet();
      final dart = <String>{};
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        dart.addAll(_all(RegExp(r"'(sense\.[a-z-]+)'"), f.readAsStringSync()));
      }
      expect(dart, isNotEmpty, reason: 'the UI sends at least host-chat-visible and shortcut-run');
      expect(dart.difference(rust), isEmpty, reason: 'the UI sends a message the core does not know');
    }, skip: _noCore);

    test('every `sense_*` event the Dart side listens for is emitted by the core', () {
      final emitted = <String>{};
      for (final f in Directory('../src').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.rs'))) {
        emitted.addAll(_all(RegExp(r'"(sense_[a-z_]*[a-z])"'), f.readAsStringSync()));
      }
      final heard = <String>{};
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        heard.addAll(_all(RegExp(r"'(sense_[a-z_]*[a-z])'"), f.readAsStringSync()));
      }
      expect(heard, containsAll(['sense_shortcut_result', 'sense_term_admin_result', 'sense_prefs_changed']));
      expect(heard.difference(emitted), isEmpty, reason: 'listened for, never sent');
    }, skip: _noCore);
  });

  group('U168c the frame-rate limits are the core\'s', () {
    final rust = File('../src/sense/fps_policy.rs').existsSync() ? _read('../src/sense/fps_policy.rs') : null;
    final skipReason = rust == null ? 'fps_policy.rs is not in this checkout' : null;

    test('stock and direct caps equal STOCK_FPS_CAP / DIRECT_FPS_CAP', () {
      int cap(String name) => int.parse(RegExp('pub const $name: usize = (\\d+);').firstMatch(rust!)!.group(1)!);
      expect(kSenseDefaultFpsCap, cap('STOCK_FPS_CAP'));
      expect(kSenseDirectFpsCap, cap('DIRECT_FPS_CAP'));
    }, skip: skipReason);

    test('the own-rate range under "Özel kalite" equals the core\'s REQUEST_RANGE', () {
      final m = RegExp(r'REQUEST_RANGE[^=]*=\s*(\d+)\.\.=(\d+);').firstMatch(rust!)!;
      final lo = int.parse(m.group(1)!), hi = int.parse(m.group(2)!);
      int cap(int fps) => senseSessionFpsCap(imageQuality: 'custom', customFps: fps, direct: true);
      expect(cap(lo), lo);
      expect(cap(hi), hi);
      expect(cap(lo - 1), kSenseDefaultFpsCap, reason: 'below the range: the default');
      expect(cap(hi + 1), kSenseDefaultFpsCap, reason: 'above the range: the default');
    }, skip: skipReason);
  });
}
