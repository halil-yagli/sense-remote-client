// Sense Remote (#114): "Kayıt kaydedildi · Klasörü aç" note.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/session/record_notice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pill shows the text and the button calls onOpen', (tester) async {
    var opened = 0;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SenseRecordNoticeBar(onOpen: () => opened++),
    ));
    expect(find.textContaining('Kayıt kaydedildi'), findsOneWidget);
    expect(find.text('Klasörü aç'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-record-notice-open')));
    expect(opened, 1);
  });

  test('handle takes only its own event', () {
    expect(SenseRecordNotice.handle({'name': 'sense_privacy_note'}), isFalse);
    // No navigator overlay in a unit test: the event is still taken, nothing is shown.
    expect(SenseRecordNotice.handle({'name': 'sense_record_saved', 'dir': '/tmp/kayit'}), isTrue);
  });
}
