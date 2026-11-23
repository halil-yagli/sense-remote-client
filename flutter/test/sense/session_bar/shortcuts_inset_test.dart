// Sense Remote: the Sense shortcut defaults (YH O5 Kısayollar) and the space above the
// remote screen that the canvas fits into (decision 3, O1).
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/ffi_backend.dart' show kSenseShortcutRows, senseShortcutText;
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

String combo(Map b) {
  final mods = [for (final m in b['mods'] as List) '$m']..sort();
  return '${mods.join('+')}+${b['key']}';
}

void main() {
  group('space above the remote screen', () {
    test('one session: only the 46 px bar; several: 28 px strip + bar', () {
      expect(senseTopInset(tabStrip: false, barHeight: SenseSizes.sessionToolbarHeight), 46);
      expect(senseTopInset(tabStrip: true, barHeight: SenseSizes.sessionToolbarHeight), 74);
    });

    test('bar hidden: the image gets the room', () {
      expect(senseTopInset(tabStrip: false, barHeight: 0), 0);
      expect(senseTopInset(tabStrip: true, barHeight: 0), 28);
    });

    test('the strip is RustDesk\'s tab bar height', () {
      expect(kSenseTabStripHeight, kDesktopRemoteTabBarHeight);
    });
  });

  group('Sense shortcut defaults', () {
    test('toolbar and close get Ctrl+Alt+Shift+B / +Q', () {
      final byAction = {for (final b in kSenseDefaultShortcutBindings) b['action']: b};
      expect(senseShortcutText(byAction[kShortcutActionToggleToolbar]!, mac: false), 'Ctrl+Alt+Shift+B');
      expect(senseShortcutText(byAction[kShortcutActionCloseTab]!, mac: false), 'Ctrl+Alt+Shift+Q');
      expect(senseShortcutText(byAction[kShortcutActionCloseTab]!, mac: true), 'Cmd+Option+Shift+Q');
    });

    test('no clash with RustDesk\'s defaults', () {
      final taken = {for (final b in kDefaultShortcutBindings) combo(b)};
      for (final b in kSenseDefaultShortcutBindings) {
        expect(taken, isNot(contains(combo(b))), reason: '${b['action']}');
      }
    });

    test('seeding adds them once, keeps a user binding, skips a taken combination', () {
      final seeded = withSenseDefaultShortcuts([
        for (final b in kDefaultShortcutBindings) Map<String, dynamic>.of(b),
      ]);
      expect(seeded.where((b) => b['action'] == kShortcutActionToggleToolbar), hasLength(1));
      expect(seeded.where((b) => b['action'] == kShortcutActionCloseTab), hasLength(1));
      expect(withSenseDefaultShortcuts(seeded), hasLength(seeded.length));

      final own = withSenseDefaultShortcuts([
        {'action': kShortcutActionCloseTab, 'mods': ['primary', 'alt'], 'key': 'w'},
      ]);
      expect(own.where((b) => b['action'] == kShortcutActionCloseTab).single['key'], 'w');

      final taken = withSenseDefaultShortcuts([
        {'action': kShortcutActionScreenshot, 'mods': ['primary', 'alt', 'shift'], 'key': 'b'},
      ]);
      expect(taken.where((b) => b['action'] == kShortcutActionToggleToolbar), isEmpty);
    });

    test('every row of the list has a default key', () {
      final defaults = {
        for (final b in [...kDefaultShortcutBindings, ...kSenseDefaultShortcutBindings]) b['action'],
      };
      for (final (id, _) in kSenseShortcutRows) {
        expect(defaults, contains(id), reason: id);
      }
    });
  });
}
