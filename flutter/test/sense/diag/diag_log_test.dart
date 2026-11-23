import 'package:flutter_hbb/sense/diag_text.dart';
import 'package:flutter_test/flutter_test.dart';

// Sense Remote (karar #86): the pure parts of the Dart diagnostic log.
void main() {
  test('long lines are cut, short ones stay', () {
    expect(senseDiagTruncate('kisa'), 'kisa');
    expect(senseDiagTruncate('a' * 5000).length, kSenseDiagMaxLine);
    expect(senseDiagTruncate('abcdef', 3), 'abc');
  });

  test('an error becomes one text with kind, message and stack', () {
    final text = senseDiagError('Zone', 'RxString not found', StackTrace.current);
    expect(text.startsWith('Zone: RxString not found\n'), isTrue);
    expect(senseDiagError('FlutterError', 'x', null), 'FlutterError: x');
  });
}
