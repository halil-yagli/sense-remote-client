// Sense Remote (S9, #97): one-time reset of a stuck "Y" for the separate windows switch.
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/sense_indiv_windows_reset.dart';

class _Peer {
  _Peer(this.value, {this.done = false});
  String value;
  bool done;
  Future<bool> run() => senseApplyIndivWindowsReset(
        readDone: () async => done,
        readValue: () async => value,
        writeValue: (v) async => value = v,
        writeDone: () async => done = true,
      );
}

void main() {
  test('old "Y" without marker is reset to N and the marker is written', () async {
    final p = _Peer('Y');
    expect(await p.run(), isTrue);
    expect(p.value, 'N');
    expect(p.done, isTrue);
  });

  test('empty or N value: nothing changes, marker is written', () async {
    for (final v in ['', 'N']) {
      final p = _Peer(v);
      expect(await p.run(), isFalse);
      expect(p.value, v);
      expect(p.done, isTrue);
    }
  });

  test('user turns it on after the reset: stays on in later sessions', () async {
    final p = _Peer('Y');
    await p.run();
    p.value = 'Y'; // user's own choice
    expect(await p.run(), isFalse);
    expect(p.value, 'Y');
  });

  test('marker present: a "Y" value is left alone', () async {
    final p = _Peer('Y', done: true);
    expect(await p.run(), isFalse);
    expect(p.value, 'Y');
  });
}
