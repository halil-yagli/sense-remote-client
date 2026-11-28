// Sense Remote (Sürüm 12, KQ): the busy card names who is connected and since when (the Host's
// `sense_busy {...}` answer, src/sense/single_conn.rs `busy_text`), the offline card the panel's
// last-seen time. Texts are the core's exact output.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/diag_log.dart';
import 'package:flutter_hbb/sense/screens/session/data/sense_peer_status.dart';
import 'package:flutter_hbb/sense/screens/session/layers/connect_cards.dart';
import 'package:flutter_hbb/sense/strings/connect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final DateTime _now = DateTime(2026, 11, 28, 14, 32);
int _unix(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

SenseConnectController _controller(FakeConnectHost host) =>
    SenseConnectController(host: host, autoStart: false, now: () => _now);

void main() {
  setUp(() => senseDiagEventTestSink = (_, __, ___) {});
  tearDown(() => senseDiagEventTestSink = null);

  group('busy detail', () {
    test('the Host answer gives who and since', () {
      final d = senseBusyDetailOf('sense_busy {"by":"Elif K.","since":1764330000}')!;
      expect(d.by, 'Elif K.');
      expect(d.since, 1764330000);
    });

    test('quotes and braces in a name survive', () {
      final d = senseBusyDetailOf(r'sense_busy {"by":"A \"B\" {C}","since":5}')!;
      expect(d.by, 'A "B" {C}');
    });

    test('an older Host (plain code) or a broken tail gives no detail', () {
      expect(senseBusyDetailOf('sense_busy'), isNull);
      expect(senseBusyDetailOf('sense_busy {'), isNull);
      expect(senseBusyDetailOf('sense_busy {"by":"  ","since":0}'), isNull);
      expect(senseBusyDetailOf('Timeout'), isNull);
    });

    test('the detailed answer is still the busy card', () {
      expect(senseConnectCardOf('error', 'Login Error', 'sense_busy {"by":"Elif K.","since":1}'),
          SenseConnectCard.busy);
    });

    test('text: who · how long; without detail the old sentence', () {
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı', by: 'Elif K.', minutes: 12),
          "Galeri kioskı şu an Elif K. tarafından kullanılıyor · 12 dk'dır");
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı', minutes: 0),
          "Galeri kioskı şu an başka biri tarafından kullanılıyor · 1 dk'dır");
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı', by: 'Elif K.'),
          'Galeri kioskı şu an Elif K. tarafından kullanılıyor.');
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı'), SenseConnectStrings.busyBody('Galeri kioskı'));
      expect(SenseConnectStrings.busyFor(125), '2 saattir');
    });

    testWidgets('the card shows it', (tester) async {
      final since = _unix(_now.subtract(const Duration(minutes: 12)));
      final c = _controller(FakeConnectHost())
        ..onMessage('error', 'Login Error', 'sense_busy {"by":"Elif K.","since":$since}', false);
      await pumpCard(tester, SenseConnectCardView(controller: c));
      expect(find.text("Galeri kioskı şu an Elif K. tarafından kullanılıyor · 12 dk'dır"), findsOneWidget);
    });
  });

  group('offline last seen', () {
    test('clock today, "dün" yesterday, the date before', () {
      expect(SenseConnectStrings.seenAt(DateTime(2026, 11, 28, 9, 5), _now), '09:05');
      expect(SenseConnectStrings.seenAt(DateTime(2026, 11, 27, 23, 59), _now), 'dün 23:59');
      expect(SenseConnectStrings.seenAt(DateTime(2026, 11, 1, 14, 20), _now), '01.11.2026 14:20');
      expect(SenseConnectStrings.seenAt(DateTime(2026, 11, 30, 23, 59), DateTime(2026, 12, 1, 8)), 'dün 23:59');
    });

    testWidgets('the panel answer reaches the card', (tester) async {
      final host = FakeConnectHost()
        ..offline = SenseOfflineInfo(lastSeenAt: _unix(DateTime(2026, 11, 28, 14, 20)), wakeable: true);
      final c = _controller(host);
      // The layer widget listens to the controller, as on a real connection window.
      await pumpCard(tester, SenseConnectLayer(id: 'kq-offline', controller: c));
      c.onMessage('error', 'Connection Error', 'Remote desktop is offline', false);
      await tester.pump();
      await tester.pump();
      expect(host.offlineAsked, 1);
      expect(c.offline?.wakeable, isTrue);
      expect(find.text('Bilgisayar kapalı ya da internete bağlı değil · son görülme 14:20'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('no panel answer keeps the plain text', (tester) async {
      final host = FakeConnectHost();
      final c = _controller(host)..onMessage('error', 'Connection Error', 'Remote desktop is offline', false);
      await pumpCard(tester, SenseConnectCardView(controller: c));
      await tester.pump();
      expect(find.text(SenseConnectStrings.offlineBody), findsOneWidget);
    });

    test('peer-status carries "wakeable" (absent = null)', () {
      expect(SensePeerStatus.fromJson({'online': false, 'last_seen_at': 5, 'wakeable': true})!.wakeable, isTrue);
      expect(SensePeerStatus.fromJson({'online': false})!.wakeable, isNull);
    });
  });
}
