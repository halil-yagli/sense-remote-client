// Sense Remote (P3, B10): the handler is removed again; a method torn off twice is `==`.

import 'package:flutter_hbb/sense/screens/session/layers/data/session_hub.dart';
import 'package:flutter_test/flutter_test.dart';

class _Owner {
  int calls = 0;
  bool onMessage(String type, String title, String text) {
    calls++;
    return true;
  }
}

void main() {
  test('unregister with a fresh tear-off removes the handler', () {
    final owner = _Owner();
    SenseSessionHub.register('p1', owner.onMessage);
    expect(SenseSessionHub.onMessage('p1', 'error', 't', 'x'), isTrue);
    SenseSessionHub.unregister('p1', owner.onMessage);
    expect(SenseSessionHub.onMessage('p1', 'error', 't', 'x'), isFalse);
    expect(owner.calls, 1);
  });

  test('a handler of a newer owner is not removed by the old one', () {
    final old = _Owner();
    final fresh = _Owner();
    SenseSessionHub.register('p2', old.onMessage);
    SenseSessionHub.register('p2', fresh.onMessage);
    SenseSessionHub.unregister('p2', old.onMessage);
    expect(SenseSessionHub.onMessage('p2', 'error', 't', 'x'), isTrue);
    expect(fresh.calls, 1);
    SenseSessionHub.unregister('p2', fresh.onMessage);
  });
}
