// Sense Remote (#114, #136): recording notes and the real recording state.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show globalKey;
import 'package:flutter_hbb/sense/screens/session/record_notice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pill shows "Kaydedildi" and the button calls onOpen', (tester) async {
    var opened = 0;
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: SenseRecordNoticeBar(onOpen: () => opened++),
    ));
    expect(find.text('Bu bilgisayara kaydedildi · '), findsOneWidget);
    expect(find.text('Klasörü aç'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-record-notice-open')));
    expect(opened, 1);
  });

  testWidgets('text-only pill has no button', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: SenseRecordNoticeBar(text: 'Kayıt başlatılamadı · dosya oluşturulamadı'),
    ));
    expect(find.text('Kayıt başlatılamadı · dosya oluşturulamadı'), findsOneWidget);
    expect(find.byKey(const Key('sense-record-notice-open')), findsNothing);
  });

  test('handle takes only its own events', () {
    expect(SenseRecordNotice.handle({'name': 'sense_privacy_note'}), isFalse);
    // No navigator overlay in a unit test: the event is still taken, nothing is shown.
    expect(SenseRecordNotice.handle({'name': 'sense_record_saved', 'dir': '/tmp/kayit'}), isTrue);
    expect(
        SenseRecordNotice.handle({'name': 'sense_record_state', 'id': 'p', 'state': 'started'}),
        isTrue);
  });

  test('every core reason has its own text', () {
    final texts = ['izin_yok', 'klasor', 'dosya', 'kodek', 'yeni_bir_sey']
        .map(SenseRecordStrings.failure)
        .toSet();
    expect(texts.length, 5);
    expect(SenseRecordStrings.failure('izin_yok'), 'bu bilgisayarda kayıt izni yok');
  });

  test('sense_record_state keeps the real state per peer (B5)', () {
    final s = SenseRecordNotice.statusOf('peer-136');
    expect(s.value, isNull);
    // As the core pushes it: every field is text.
    SenseRecordNotice.handle({
      'name': 'sense_record_state',
      'id': 'peer-136',
      'state': 'started',
      'display': '1',
      'part': '1',
      'reason': '',
    });
    expect(s.value!.started, isTrue);
    expect(s.value!.display, 1);
    SenseRecordNotice.handle({
      'name': 'sense_record_state',
      'id': 'peer-136',
      'state': 'failed',
      'display': 0,
      'part': 0,
      'reason': 'izin_yok',
    });
    expect(s.value!.failed, isTrue);
    expect(s.value!.reason, 'izin_yok');
    // The stop that follows a failure reports `stopped` and `empty`; the failure stays.
    SenseRecordNotice.handle({'name': 'sense_record_state', 'id': 'peer-136', 'state': 'stopped'});
    SenseRecordNotice.handle({'name': 'sense_record_state', 'id': 'peer-136', 'state': 'empty'});
    expect(s.value!.failed, isTrue);
    // The next start clears it; on only once a file really opened.
    SenseRecordNotice.handle({'name': 'sense_record_state', 'id': 'peer-136', 'state': 'starting'});
    expect(s.value!.started, isFalse);
    SenseRecordNotice.handle({'name': 'sense_record_state', 'id': 'peer-136', 'state': 'started'});
    expect(s.value!.started, isTrue);
    // Another peer is not touched.
    expect(SenseRecordNotice.statusOf('peer-other').value, isNull);
  });

  testWidgets('saved note reveals the first file of the recording', (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: globalKey,
      home: const SizedBox.shrink(),
    ));
    String? gotDir;
    String? gotFile;
    SenseRecordNotice.handle({
      'name': 'sense_record_saved',
      'dir': r'C:\Users\u\Videos\SenseRemote\Slayer_2026-11-27_03-52-04',
      'file': r'C:\Users\u\Videos\SenseRemote\Slayer_2026-11-27_03-52-04\Slayer_2026-11-27_03-52-04_Ekran1.mp4',
    }, reveal: (d, f) async {
      gotDir = d;
      gotFile = f;
    });
    await tester.pump();
    expect(find.text('Bu bilgisayara kaydedildi · '), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-record-notice-open')));
    await tester.pump();
    expect(gotDir, endsWith('Slayer_2026-11-27_03-52-04'));
    expect(gotFile, endsWith('_Ekran1.mp4'));
    expect(find.byKey(const Key('sense-record-notice')), findsNothing);
  });

  testWidgets('failure note says why', (tester) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: globalKey,
      home: const SizedBox.shrink(),
    ));
    SenseRecordNotice.handle({
      'name': 'sense_record_state',
      'id': 'peer-fail',
      'state': 'failed',
      'reason': 'klasor',
    });
    await tester.pump();
    expect(find.text('Kayıt başlatılamadı · kayıt klasörü açılamadı'), findsOneWidget);
    SenseRecordNotice.hide();
  });
}
