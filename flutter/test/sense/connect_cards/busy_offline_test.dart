// Sense Remote (Sürüm 12, KQ, karar #173): the busy card says since when (the Host's
// `sense_busy {"since":…}` answer, src/sense/single_conn.rs `busy_text`; no name before the
// password check) and who from the panel (peer-status `busy_by`); the offline card the panel's
// last-seen time.
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

/// The layer widget listens to the controller, as on a real connection window.
Future<void> _showLayer(WidgetTester tester, SenseConnectController c, String id) =>
    pumpCard(tester, SenseConnectLayer(id: id, controller: c));

Future<void> _endLayer(WidgetTester tester, SenseConnectController c) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
}

void main() {
  setUp(() => senseDiagEventTestSink = (_, __, ___) {});
  tearDown(() => senseDiagEventTestSink = null);

  group('busy', () {
    test('the Host answer gives since when', () {
      expect(senseBusySinceOf('sense_busy {"since":1764330000}'), 1764330000);
    });

    test('an older Host (plain code) or a broken tail gives nothing', () {
      expect(senseBusySinceOf('sense_busy'), isNull);
      expect(senseBusySinceOf('sense_busy {'), isNull);
      expect(senseBusySinceOf('sense_busy {"since":0}'), isNull);
      expect(senseBusySinceOf('Timeout'), isNull);
    });

    test('the detailed answer is still the busy card', () {
      expect(senseConnectCardOf('error', 'Login Error', 'sense_busy {"since":1}'), SenseConnectCard.busy);
    });

    test('text: who · how long; without the panel "başka bir Sense çalışanı"; without both the old sentence', () {
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı', by: 'Elif K.', minutes: 12),
          "Galeri kioskı şu an Elif K. tarafından kullanılıyor · 12 dk'dır");
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı', minutes: 12),
          "Galeri kioskı şu an başka bir Sense çalışanı tarafından kullanılıyor · 12 dk'dır");
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı', minutes: 0),
          "Galeri kioskı şu an başka bir Sense çalışanı tarafından kullanılıyor · 1 dk'dır");
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı', by: 'Elif K.'),
          'Galeri kioskı şu an Elif K. tarafından kullanılıyor.');
      expect(SenseConnectStrings.busyBodyDetail('Galeri kioskı'), SenseConnectStrings.busyBody('Galeri kioskı'));
      expect(SenseConnectStrings.busyFor(125), '2 saattir');
    });

    testWidgets('Host time + panel name on the card', (tester) async {
      final since = _unix(_now.subtract(const Duration(minutes: 12)));
      final host = FakeConnectHost()..panel = const SensePanelInfo(busyBy: 'Elif K.');
      final c = _controller(host);
      await _showLayer(tester, c, 'kq-busy');
      c.onMessage('error', 'Login Error', 'sense_busy {"since":$since}', false);
      await tester.pump();
      await tester.pump();
      expect(host.panelAsked, 1);
      expect(find.text("Galeri kioskı şu an Elif K. tarafından kullanılıyor · 12 dk'dır"), findsOneWidget);
      await _endLayer(tester, c);
    });

    testWidgets('no panel name: "başka bir Sense çalışanı"', (tester) async {
      final since = _unix(_now.subtract(const Duration(minutes: 12)));
      final c = _controller(FakeConnectHost());
      await _showLayer(tester, c, 'kq-busy2');
      c.onMessage('error', 'Login Error', 'sense_busy {"since":$since}', false);
      await tester.pump();
      await tester.pump();
      expect(find.text("Galeri kioskı şu an başka bir Sense çalışanı tarafından kullanılıyor · 12 dk'dır"),
          findsOneWidget);
      await _endLayer(tester, c);
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
        ..panel = SensePanelInfo(lastSeenAt: _unix(DateTime(2026, 11, 28, 14, 20)), wakeable: true);
      final c = _controller(host);
      await _showLayer(tester, c, 'kq-offline');
      c.onMessage('error', 'Connection Error', 'Remote desktop is offline', false);
      await tester.pump();
      await tester.pump();
      expect(host.panelAsked, 1);
      expect(c.panel?.wakeable, isTrue);
      expect(find.text('Bilgisayar kapalı ya da internete bağlı değil · son görülme 14:20'), findsOneWidget);
      await _endLayer(tester, c);
    });

    testWidgets('no panel answer keeps the plain text', (tester) async {
      final c = _controller(FakeConnectHost())
        ..onMessage('error', 'Connection Error', 'Remote desktop is offline', false);
      await pumpCard(tester, SenseConnectCardView(controller: c));
      await tester.pump();
      expect(find.text(SenseConnectStrings.offlineBody), findsOneWidget);
    });
  });

  test('peer-status carries "wakeable" and "busy_by" (absent = null)', () {
    final s = SensePeerStatus.fromJson({'online': true, 'wakeable': true, 'busy_by': '  Elif K. '})!;
    expect(s.wakeable, isTrue);
    expect(s.busyBy, 'Elif K.');
    final old = SensePeerStatus.fromJson({'online': false})!;
    expect(old.wakeable, isNull);
    expect(old.busyBy, isNull);
    expect(SensePeerStatus.fromJson({'online': true, 'busy_by': '   '})!.busyBy, isNull);
  });
}
