// Sense Remote (Sürüm 12, U169, FO-A9): the session's quality, scale and key bindings follow the
// person's account, and the drawing label reads as the plan says. The answers fed to the parser
// are the core's own (`{entries, custom}`, `{"error":"unsupported"}`).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/data/account_view_prefs.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_specs.dart';

import 'fake_backend.dart';

class _Io implements SenseAccountPrefsIo {
  _Io(this.answer, {this.setAnswer = ''});
  String answer;
  String setAnswer;
  final sent = <Map<String, dynamic>>[];

  @override
  Future<String> get() async => answer;

  @override
  Future<String> set(String json) async {
    sent.add(jsonDecode(json) as Map<String, dynamic>);
    return setAnswer;
  }
}

String _entries(List<Map<String, Object?>> e) => jsonEncode({'entries': e, 'custom': []});

void main() {
  group('U169 account view preferences', () {
    test('reads quality, scale and bindings of the account', () async {
      final io = _Io(_entries([
        {'os': 'any', 'key': 'view.quality', 'value': {'mode': 'custom', 'fps': 24}, 'rev': 2},
        {'os': 'any', 'key': 'view.scale', 'value': {'mode': 'fit'}, 'rev': 1},
        {
          'os': 'any',
          'key': 'keys.bindings',
          'value': [
            {'action': 'reset_canvas', 'key': 'KeyR', 'modifiers': ['ctrl']}
          ]
        },
      ]));
      final a = (await SenseAccountViewPrefs(io).read())!;
      expect(a.quality, 'custom');
      expect(a.fps, 24);
      expect(a.scale, 'adaptive');
      expect(a.bindings!.single['action'], 'reset_canvas');
    });

    test('original scale, and values that are not understood are left out', () {
      final a = SenseAccountViewPrefs.parse(_entries([
        {'os': 'any', 'key': 'view.scale', 'value': {'mode': 'original'}},
        {'os': 'any', 'key': 'view.quality', 'value': {'mode': 'ultra', 'fps': 999}},
      ]))!;
      expect(a.scale, 'original');
      expect(a.quality, isNull);
      expect(a.fps, isNull);
      expect(a.bindings, isNull);
    });

    test('no store (unsupported, bad text, error) keeps the old local behaviour', () async {
      expect(SenseAccountViewPrefs.parse('{"error":"unsupported"}'), isNull);
      expect(SenseAccountViewPrefs.parse('not json'), isNull);
      expect(await SenseAccountViewPrefs(_Io('{"error":"unsupported"}')).read(), isNull);
      final empty = (await SenseAccountViewPrefs(_Io(_entries([]))).read())!;
      expect(empty.quality, isNull);
      expect(empty.scale, isNull);
    });

    test('writes go to the account as os "any" with the contract shape', () async {
      final io = _Io('');
      final p = SenseAccountViewPrefs(io);
      expect(await p.writeQuality('best'), isTrue);
      expect(await p.writeQuality('custom', fps: 30), isTrue);
      expect(await p.writeScale('adaptive'), isTrue);
      expect(await p.writeScale('original'), isTrue);
      Map<String, dynamic> entry(int i) => (io.sent[i]['entries'] as List).single as Map<String, dynamic>;
      expect(entry(0), {'os': 'any', 'key': 'view.quality', 'value': {'mode': 'best'}});
      expect(entry(1)['value'], {'mode': 'custom', 'fps': 30});
      expect(entry(2), {'os': 'any', 'key': 'view.scale', 'value': {'mode': 'fit'}});
      expect(entry(3)['value'], {'mode': 'original'});
    });

    test('custom scale has no account value; a failed store is false, never an error', () async {
      final io = _Io('');
      expect(await SenseAccountViewPrefs(io).writeScale('custom'), isFalse);
      expect(io.sent, isEmpty);
      expect(await SenseAccountViewPrefs(_Io('', setAnswer: 'unsupported')).writeQuality('low'), isFalse);
    });

    test('bindings are merged into the local config without touching its switches', () {
      final account = [
        {'action': 'reset_canvas', 'key': 'KeyR'}
      ];
      final local = jsonEncode({'enabled': true, 'pass_through': false, 'bindings': []});
      final merged = jsonDecode(SenseAccountViewPrefs.mergeBindings(local, account)!) as Map<String, dynamic>;
      expect(merged['enabled'], isTrue);
      expect(merged['pass_through'], isFalse);
      expect(merged['bindings'], account);
      // Already the same: nothing to write.
      expect(SenseAccountViewPrefs.mergeBindings(jsonEncode(merged), account), isNull);
      // Nothing local yet: the config is created, off.
      final fresh = jsonDecode(SenseAccountViewPrefs.mergeBindings('', account)!) as Map<String, dynamic>;
      expect(fresh['enabled'], isFalse);
    });
  });

  test('FO-A9: the drawing entry reads "Doku (texture) ile çiz" with the info line below', () {
    final render = senseDisplayList(FakeBackend()).sections.firstWhere((s) => s.id == 'render');
    expect(render.entries.first.label, 'Doku (texture) ile çiz');
    expect(render.entries.last.id, 'display.renderInfo');
  });
}
