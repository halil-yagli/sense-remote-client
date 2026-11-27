// Sense Remote (C2, YH O8, O9, T7): behaviour of the two session popups —
// one popup at a time, ×, –, alert tags open their category, one category
// open, Kopyala per card, loading / error states, chat icon not covered.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/session/data/peer_status.dart';
import 'package:flutter_hbb/sense/screens/session/popups/display/display_data.dart';
import 'package:flutter_hbb/sense/screens/session/popups/display/display_popup.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_popup.dart';
import 'package:flutter_hbb/sense/screens/session/popups/status/status_widgets.dart';

import 'fixtures.dart';

void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget statusPopup(SensePeerStatusFeed feed, {VoidCallback? onClose, String? open}) => app(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 400,
        height: 840,
        child: Align(
          alignment: Alignment.topCenter,
          child: SenseStatusPopup(feed: feed, onClose: onClose ?? () {}, tick: null, initialOpenId: open),
        ),
      ),
    ));

void main() {
  group('Bilgisayar durumu', () {
    testWidgets('header, live line, overall box, categories, bottom note', (tester) async {
      setWindow(tester, const Size(400, 840));
      await tester.pumpWidget(statusPopup(feedWith(fullJson())));
      expect(find.text('Bilgisayar durumu'), findsOneWidget);
      expect(find.text('8 sn önce'), findsOneWidget);
      expect(find.text('Canlı · 8 sn önce'), findsOneWidget);
      expect(find.text('Dikkat gerekiyor'), findsOneWidget);
      for (final t in ['İşlemci', 'Bellek', 'Ağ', 'Ekranlar', 'Bileşenler', 'Yazılım ve sürücüler']) {
        expect(find.text(t), findsWidgets, reason: t);
      }
      // No "Tümünü aç" / "Hepsini kopyala" (#10).
      expect(find.text('Tümünü aç'), findsNothing);
      expect(find.text('Hepsini kopyala'), findsNothing);
      await tester.scrollUntilVisible(find.textContaining('Eşikler:'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('"okunamadı": bilgisayar o değeri vermiyor'), findsOneWidget);
    });

    testWidgets('closed warn/hot categories carry the 3 px stripe', (tester) async {
      setWindow(tester, const Size(400, 840));
      await tester.pumpWidget(statusPopup(feedWith(fullJson())));
      // Ekran kartı (warn) and Depolama (hot).
      expect(find.byKey(const Key('sense-acc-stripe')), findsNWidgets(2));
    });

    testWidgets('an alert tag opens its category; one category at a time', (tester) async {
      setWindow(tester, const Size(400, 840));
      await tester.pumpWidget(statusPopup(feedWith(fullJson())));
      expect(find.text('Samsung SSD 980 PRO 1TB'), findsNothing);
      await tester.tap(find.text('Depolama').first);
      await tester.pump();
      expect(find.text('Samsung SSD 980 PRO 1TB'), findsOneWidget);
      // Opening İşlemci closes Depolama.
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('sense-acc-cpu')), matching: find.text('İşlemci')));
      await tester.pump();
      expect(find.text('Samsung SSD 980 PRO 1TB'), findsNothing);
      expect(find.text('TouchDesigner.exe'), findsOneWidget);
      // Tapping the open header closes it.
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('sense-acc-cpu')), matching: find.text('İşlemci')));
      await tester.pump();
      expect(find.text('TouchDesigner.exe'), findsNothing);
    });

    testWidgets('"okunamadı" is drawn faded and italic', (tester) async {
      setWindow(tester, const Size(400, 1400));
      await tester.pumpWidget(statusPopup(feedWith(fullJson()), open: 'storage'));
      final texts = tester.widgetList<RichText>(find.byType(RichText)).where((t) => t.text.toPlainText() == 'okunamadı');
      expect(texts, isNotEmpty);
      for (final t in texts) {
        TextStyle? style;
        t.text.visitChildren((span) {
          if (span is TextSpan && span.text == 'okunamadı') style = span.style;
          return style == null;
        });
        expect(style?.fontStyle, FontStyle.italic);
        expect(style?.color, SenseColors.textDim);
      }
    });

    testWidgets('Kopyala copies one card', (tester) async {
      setWindow(tester, const Size(400, 1400));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(statusPopup(feedWith(fullJson()), open: 'gpu'));
      await tester.tap(find.byKey(const Key('sense-copy-NVIDIA GeForce RTX 4070')));
      await tester.pump();
      expect(copied, startsWith('NVIDIA GeForce RTX 4070\nKullanım: %71'));
      expect(copied, isNot(contains('Intel UHD')));
      expect(find.text('Kopyalandı'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('× closes, – leaves only the header', (tester) async {
      setWindow(tester, const Size(400, 840));
      var closed = 0;
      await tester.pumpWidget(statusPopup(feedWith(fullJson()), onClose: () => closed++));
      await tester.tap(find.byKey(const Key('sense-popup-minimize')));
      await tester.pump();
      expect(find.text('Dikkat gerekiyor'), findsNothing);
      expect(find.text('Bilgisayar durumu'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-popup-minimize')));
      await tester.pump();
      expect(find.text('Dikkat gerekiyor'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-popup-close')));
      expect(closed, 1);
    });

    testWidgets('loading, no panel info, failed + Yeniden dene', (tester) async {
      setWindow(tester, const Size(400, 840));
      var calls = 0;
      final feed = SensePeerStatusFeed(
        peerId: '1',
        now: () => kNow,
        refreshEvery: null,
        fetch: (_) async {
          calls++;
          return const SensePeerStatusFullResult.error(SensePeerStatusError.failed);
        },
      );
      await tester.pumpWidget(statusPopup(feed));
      expect(find.text('Bilgiler panelden alınıyor…'), findsOneWidget);
      await tester.pump();
      expect(find.text('Panel bilgisine ulaşılamadı.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-status-retry')));
      await tester.pump();
      expect(calls, 2);

      final none = SensePeerStatusFeed(peerId: '2', now: () => kNow, refreshEvery: null,
          fetch: (_) async => const SensePeerStatusFullResult.error(SensePeerStatusError.notFound));
      await tester.pumpWidget(statusPopup(none));
      await tester.pump();
      expect(find.text('Bu bilgisayar için panel bilgisi yok.'), findsOneWidget);
      expect(find.byKey(const Key('sense-status-retry')), findsNothing);
    });

    testWidgets('offline computer: grey "Kapalı · son veri …"', (tester) async {
      setWindow(tester, const Size(400, 840));
      final j = fullJson()..['online'] = false;
      await tester.pumpWidget(statusPopup(feedWith(j)));
      expect(find.text('Kapalı · son veri 8 sn önce'), findsOneWidget);
    });

    test('the feed refreshes while open and stops when closed', () async {
      var calls = 0;
      final feed = SensePeerStatusFeed(
        peerId: '1',
        refreshEvery: null,
        fetch: (_) async {
          calls++;
          return SensePeerStatusFullResult.ok(parseFull(fullJson()));
        },
      );
      feed.attach();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(feed.data, isNotNull);
      feed.attach(); // fresh: no second read
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      feed.detach();
      feed.detach();
      feed.dispose();
    });
  });

  group('Ekran bilgisi', () {
    Widget displayPopup({String? open, SenseSessionVideo video = kVideo}) => app(Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 840,
            child: Align(
              alignment: Alignment.topCenter,
              child: SenseDisplayPopup(
                feed: feedWith(fullJson()),
                video: ValueNotifier(video),
                onClose: () {},
                initialOpenId: open,
              ),
            ),
          ),
        ));

    testWidgets('top line, box, watched display open, note', (tester) async {
      setWindow(tester, const Size(400, 840));
      await tester.pumpWidget(displayPopup());
      expect(find.text('Ekran bilgisi'), findsOneWidget);
      expect(find.text('3 ekran · Ekran 1 izleniyor'), findsOneWidget);
      expect(find.text('Uyarı var'), findsOneWidget);
      expect(find.text('60 / 60 fps'), findsOneWidget);
      expect(find.text('Doğrudan · VP9 · Dengeli'), findsOneWidget);
      expect(find.text('Samsung QM55B'), findsOneWidget); // Ekran 1 open
      expect(find.textContaining('gecikme 150 ms üstü turuncu'), findsOneWidget);
    });

    testWidgets('the "Ekran 2" tag opens Ekran 2 with the 4:2:2 note', (tester) async {
      setWindow(tester, const Size(400, 840));
      await tester.pumpWidget(displayPopup());
      await tester.tap(find.text('Ekran 2').first);
      await tester.pump();
      expect(find.text('50 Hz (diğerleri 60 Hz)'), findsOneWidget);
      expect(find.textContaining('RGB 4:4:4 önerilir'), findsOneWidget);
      expect(find.text('Samsung QM55B'), findsNothing);
    });
  });

  group('one popup at a time, placement', () {
    testWidgets('opening Ekran bilgisi closes Bilgisayar durumu; toggle closes', (tester) async {
      setWindow(tester, const Size(1440, 854));
      final c = SensePopupController();
      addTearDown(c.dispose);
      final feed = feedWith(fullJson());
      final video = ValueNotifier(kVideo);
      await tester.pumpWidget(app(SensePopupHost(controller: c, child: const SizedBox.expand())));
      SenseStatusPopup.toggle(c, feed: feed);
      await tester.pump();
      expect(find.byType(SenseStatusPopup), findsOneWidget);
      SenseDisplayPopup.toggle(c, feed: feed, video: video);
      await tester.pump();
      expect(find.byType(SenseStatusPopup), findsNothing);
      expect(find.byType(SenseDisplayPopup), findsOneWidget);
      SenseDisplayPopup.toggle(c, feed: feed, video: video);
      await tester.pump();
      expect(find.byType(SenseDisplayPopup), findsNothing);
      SenseStatusPopup.toggle(c, feed: feed);
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-popup-close')));
      await tester.pump();
      expect(c.isOpen, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the popup ends 32 px above the bottom', (tester) async {
      setWindow(tester, const Size(1440, 854));
      final c = SensePopupController();
      addTearDown(c.dispose);
      await tester.pumpWidget(app(SensePopupHost(controller: c, child: const SizedBox.expand())));
      SenseStatusPopup.toggle(c, feed: feedWith(fullJson()));
      await tester.pump();
      await tester.tap(find.text('Depolama').first); // tall content
      await tester.pump();
      final r = tester.getRect(find.byType(SensePopupShell));
      expect(r.bottom, lessThanOrEqualTo(854 - SenseSizes.popupBottomGap));
      expect(r.top, SensePopupHost.defaultMargin);
      expect(r.width, SenseSizes.popupWidthMedium);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the popup does not cover the chat icon in the lower right', (tester) async {
      setWindow(tester, const Size(1440, 854));
      final c = SensePopupController();
      addTearDown(c.dispose);
      const icon = Rect.fromLTWH(1440 - 84, 854 - 84, 64, 64);
      final place = ValueNotifier<SenseChatIconPlacement?>(
          const SenseChatIconPlacement(icon: icon, area: Size(1440, 854)));
      await tester.pumpWidget(app(SensePopupHost(controller: c, child: const SizedBox.expand())));
      SenseStatusPopup.toggle(c, feed: feedWith(fullJson()), chatIcon: place);
      await tester.pump();
      await tester.tap(find.text('Depolama').first);
      await tester.pump();
      final r = tester.getRect(find.byType(SensePopupShell));
      expect(r.bottom, lessThanOrEqualTo(icon.top - SensePopupHost.defaultMargin));
      // Icon dragged to the left: the popup may use the full height again.
      place.value = const SenseChatIconPlacement(icon: Rect.fromLTWH(20, 770, 64, 64), area: Size(1440, 854));
      await tester.pump();
      expect(tester.getRect(find.byType(SensePopupShell)).bottom, greaterThan(icon.top));
      await tester.pumpWidget(const SizedBox());
    });

    test('max height rule', () {
      const area = Size(1440, 854);
      expect(senseSidePopupMaxHeight(slotMaxHeight: 812, popupWidth: 400), 812);
      expect(
          senseSidePopupMaxHeight(
              slotMaxHeight: 812,
              popupWidth: 400,
              chat: const SenseChatIconPlacement(icon: Rect.fromLTWH(1356, 770, 64, 64), area: area)),
          750);
      // Upper half: not under the popup's bottom.
      expect(
          senseSidePopupMaxHeight(
              slotMaxHeight: 812,
              popupWidth: 400,
              chat: const SenseChatIconPlacement(icon: Rect.fromLTWH(1356, 100, 64, 64), area: area)),
          812);
      // Never under 200 px.
      expect(
          senseSidePopupMaxHeight(
              slotMaxHeight: 812,
              popupWidth: 400,
              chat: const SenseChatIconPlacement(icon: Rect.fromLTWH(1356, 440, 64, 64), area: Size(1440, 500))),
          420);
    });
  });
}
