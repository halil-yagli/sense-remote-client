// Sense Remote: the layers on screen (YH O13 c11/c12, O14 n07, O15 n08): every button,
// the in-place second step, colours by limit, and golden images.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/session/bar/sense_session_frame.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart' as bar show SenseBarPopup, SenseLinkSample, SenseLinkPath;
import 'package:flutter_hbb/sense/screens/session/data/frame_rate.dart';
import 'package:flutter_hbb/sense/screens/session/layers/data/session_hub.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_controller.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_spec.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_strings.dart';
import 'package:flutter_hbb/sense/screens/session/layers/layer_views.dart';
import 'package:flutter_hbb/sense/screens/session/layers/link_machine.dart';
import 'package:flutter_hbb/sense/screens/session/layers/session_end.dart';
import 'package:flutter_hbb/sense/screens/session/layers/session_layers.dart';
import 'package:flutter_test/flutter_test.dart';

import '../session_bar/fake_backend.dart' show FakeBackend, FakePopups;
import 'support.dart';

const String _goldenDir = 'test/goldens/session_layers';
String _golden(String name) => '../../goldens/session_layers/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_goldenDir/$name.png').existsSync();

/// The connection window behind the layers (G10): the real session bar
/// (`SenseSessionFrame` with the test backend), the glow "remote screen" and an
/// open Bilgisayar durumu popup drawn with the real popup frame and status box.
class _FakeWindow extends StatelessWidget {
  const _FakeWindow({this.link, this.popupOpen = true});

  /// What the bar's logo / status area shows (null = the healthy default).
  final bar.SenseLinkSample? link;

  /// Bilgisayar durumu open behind the layer (closed when the logo area opens a card).
  final bool popupOpen;

  @override
  Widget build(BuildContext context) {
    final popups = FakePopups()
      ..statusLevel = SenseLevel.ok
      ..infoLevel = null;
    if (popupOpen) popups.open.add(bar.SenseBarPopup.status);
    return SenseSessionFrame(
      backend: link == null ? FakeBackend() : FakeBackend(link: link!),
      popups: popups,
      child: Stack(children: [
        const Positioned.fill(child: SenseGlowScene(style: SenseGlowStyle.scene)),
        if (popupOpen)
        Positioned(
          top: 10,
          right: 10,
          width: SenseSizes.popupWidthMedium,
          child: SensePopupShell(
            title: 'Bilgisayar durumu',
            subtitle: 'Canlı · 8 sn önce',
            animateIn: false,
            onClose: () {},
            onMinimizedChanged: (_) {},
            body: const SenseStatusBox(level: SenseLevel.ok, title: 'Her şey yolunda'),
          ),
        ),
      ]),
    );
  }
}

Future<void> _pump(WidgetTester tester, Widget layer, {bar.SenseLinkSample? link, bool popupOpen = true}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: senseTheme(),
    darkTheme: senseTheme(),
    themeMode: kSenseThemeMode,
    builder: (context, w) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: w!,
    ),
    home: Scaffold(
      body: RepaintBoundary(
        key: const Key('golden'),
        child: Stack(children: [
          Positioned.fill(child: _FakeWindow(link: link, popupOpen: popupOpen)),
          Positioned.fill(child: layer),
        ]),
      ),
    ),
  ));
  await tester.pump();
}

const _weak = SenseLinkView(
  phase: SenseLinkPhase.weak,
  sample: SenseLinkSample(rttMs: 272, lossPct: 5.1, fps: 8),
);

const _lost = SenseLinkView(
  phase: SenseLinkPhase.lost,
  sample: SenseLinkSample(fps: 0),
  stall: Duration(seconds: 9),
  retries: 3,
);

const _summary = SenseSessionSummary(
  reason: SenseEndReason.hostEnded,
  duration: Duration(minutes: 42),
  messages: 3,
  files: 1,
  idleLimit: Duration(minutes: 30),
);

Color? _valueColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

void main() {
  group('O13 weak (c11)', () {
    testWidgets('texts, tiles coloured by limit, estimated loss, limits line', (tester) async {
      await _pump(tester, SenseLinkLayer(view: _weak, onEnd: () {}));
      expect(find.text('Bağlantı zayıf'), findsOneWidget);
      expect(find.text('Bağlantı bir süredir zayıf; tepkiler gecikiyor.'), findsOneWidget);
      expect(find.text('272 ms'), findsOneWidget);
      expect(find.text('%5,1'), findsOneWidget);
      expect(find.text('8 fps'), findsOneWidget);
      expect(find.text('tahmini kayıp'), findsOneWidget, reason: '#69: loss is not measured');
      expect(_valueColor(tester, '272 ms'), SenseColors.warn);
      expect(_valueColor(tester, '%5,1'), SenseColors.dangerText);
      expect(_valueColor(tester, '8 fps'), SenseColors.warn);
      expect(
          find.text(
              'Çalışılabilir bağlantı: gecikme 150 ms altı · kayıp %2 altı · 15 fps üstü'),
          findsOneWidget);
      expect(find.text('Daha iyi yol aranıyor (doğrudan / aktarma)…'), findsOneWidget);
    });

    testWidgets('4 px blur, 62 % brightness', (tester) async {
      await _pump(tester, SenseLinkLayer(view: _weak, onEnd: () {}));
      final veil = tester.widget<SenseLayerVeil>(find.byType(SenseLayerVeil));
      expect(veil.blur, 4);
      expect(veil.brightness, 0.62);
    });

    testWidgets('"Bağlantıyı bitir" asks in place, Vazgeç goes back, Bitir ends', (tester) async {
      var ended = 0;
      await _pump(tester, SenseLinkLayer(view: _weak, onEnd: () => ended++));
      await tester.tap(find.byKey(const Key('sense-layer-end')));
      await tester.pump();
      expect(find.text('Bağlantı bitirilsin mi?'), findsOneWidget);
      expect(ended, 0);
      await tester.tap(find.byKey(const Key('sense-confirm-cancel')));
      await tester.pump();
      expect(find.byKey(const Key('sense-layer-end')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-layer-end')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sense-confirm-ok')));
      await tester.pump();
      expect(ended, 1);
    });

    testWidgets('unknown loss says okunamadı, not a number', (tester) async {
      await _pump(
          tester,
          SenseLinkLayer(
              view: const SenseLinkView(
                  phase: SenseLinkPhase.weak, sample: SenseLinkSample(rttMs: 200, fps: 30)),
              onEnd: () {}));
      expect(find.text('okunamadı'), findsOneWidget);
    });

    testWidgets('recovering line', (tester) async {
      await _pump(
          tester,
          SenseLinkLayer(
              view: const SenseLinkView(
                  phase: SenseLinkPhase.weak,
                  sample: SenseLinkSample(rttMs: 20, lossPct: 0, fps: 60),
                  recoveringIn: 2),
              onEnd: () {}));
      expect(find.text('Bağlantı toparlandı · 2 sn iyi kalırsa kapanır'), findsOneWidget);
    });

    testWidgets('x on the weak card calls onMinimize; the lost card has none', (tester) async {
      var n = 0;
      await _pump(tester, SenseLinkLayer(view: _weak, onEnd: () {}, onMinimize: () => n++));
      await tester.tap(find.byKey(const Key('sense-layer-minimize')));
      expect(n, 1);
      await _pump(tester, SenseLinkLayer(view: _lost, onEnd: () {}, onMinimize: () => n++));
      expect(find.byKey(const Key('sense-layer-minimize')), findsNothing);
    });

    testWidgets('golden c11', (tester) async {
      await _pump(tester, SenseLinkLayer(view: _weak, onEnd: () {}, onMinimize: () {}));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('o13_weak_c11')));
    }, skip: _skip('o13_weak_c11'), tags: ['golden']);

    testWidgets('golden: card shrunk into the logo area (warning colour kept)', (tester) async {
      await _pump(
        tester,
        const SizedBox.shrink(),
        link: bar.SenseLinkSample(
            path: bar.SenseLinkPath.direct, fps: 3, rttMs: 20, wavy: true, onRestoreLayer: () {}),
      );
      expect(find.textContaining('Dalgalı'), findsOneWidget);
      await expectLater(
          find.byKey(const Key('golden')), matchesGoldenFile(_golden('o13_weak_minimized')));
    }, skip: _skip('o13_weak_minimized'), tags: ['golden']);
  });

  // Sürüm 10 (#110): the same card opened from the logo area while the link is good.
  group('O13 good-link card (#110)', () {
    const good = SenseLinkView(
      phase: SenseLinkPhase.normal,
      sample: SenseLinkSample(rttMs: 18, lossPct: 0.2, fps: 60),
    );

    testWidgets('type, current values, limits line; no end button, no breathing logo', (tester) async {
      await _pump(tester, SenseLinkInfoLayer(view: good, direct: true, onClose: () {}), popupOpen: false);
      expect(find.text('Bağlantı iyi'), findsOneWidget);
      expect(find.text('Doğrudan bağlantı (aktarma yok)'), findsOneWidget);
      expect(find.text('18 ms'), findsOneWidget);
      expect(find.text('%0,2'), findsOneWidget);
      expect(find.text('60 fps'), findsOneWidget);
      expect(_valueColor(tester, '18 ms'), SenseColors.text, reason: 'large tiles: good values in white');
      expect(find.textContaining('Çalışılabilir bağlantı'), findsOneWidget);
      expect(find.byKey(const Key('sense-layer-end')), findsNothing);
      expect(find.byType(SenseBreathe), findsNothing);
    });

    testWidgets('server line (#144): name, path, ms; empty name gives a dash', (tester) async {
      await _pump(
          tester, SenseLinkInfoLayer(view: good, direct: true, serverName: 'Türkiye (İstanbul)', onClose: () {}),
          popupOpen: false);
      expect(find.text('Sunucu: Türkiye (İstanbul) · doğrudan · 18 ms'), findsOneWidget);
      await _pump(tester, SenseLinkInfoLayer(view: good, direct: false, serverName: 'Almanya', onClose: () {}),
          popupOpen: false);
      expect(find.text('Sunucu: Almanya · aktarma · 18 ms'), findsOneWidget);
      await _pump(tester, SenseLinkInfoLayer(view: good, direct: true, serverName: '', onClose: () {}),
          popupOpen: false);
      expect(find.text('Sunucu: —'), findsOneWidget);
      await _pump(tester, SenseLinkInfoLayer(view: good, direct: true, onClose: () {}), popupOpen: false);
      expect(find.text('Sunucu: —'), findsOneWidget);
    });

    testWidgets('relay, unknown type and "Dalgalı" wording', (tester) async {
      await _pump(tester, SenseLinkInfoLayer(view: good, direct: false, onClose: () {}), popupOpen: false);
      expect(find.text('Aktarma sunucusu üzerinden'), findsOneWidget);
      await _pump(
          tester,
          SenseLinkInfoLayer(
              view: const SenseLinkView(phase: SenseLinkPhase.normal, sample: SenseLinkSample(rttMs: 272, fps: 8), wavy: true),
              direct: null,
              onClose: () {}),
          popupOpen: false);
      expect(find.text('Bağlantı türü ölçülüyor'), findsOneWidget);
      expect(find.text('Bağlantı dalgalı'), findsOneWidget);
      expect(_valueColor(tester, '272 ms'), SenseColors.warn);
    });

    testWidgets('x, Kapat and a click beside the card close it; a click on the card does not', (tester) async {
      var closed = 0;
      await _pump(tester, SenseLinkInfoLayer(view: good, direct: true, onClose: () => closed++), popupOpen: false);
      await tester.tap(find.text('Bağlantı iyi'));
      expect(closed, 0);
      await tester.tap(find.byKey(const Key('sense-layer-minimize')));
      expect(closed, 1);
      await tester.tap(find.byKey(const Key('sense-layer-info-close')));
      expect(closed, 2);
      await tester.tapAt(const Offset(40, 680));
      expect(closed, 3);
    });

    testWidgets('golden: good-link card', (tester) async {
      await _pump(
          tester,
          SenseLinkInfoLayer(view: good, direct: true, serverName: 'Türkiye (İstanbul)', onClose: () {}),
          link: const bar.SenseLinkSample(path: bar.SenseLinkPath.direct, fps: 60, rttMs: 18),
          popupOpen: false);
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('o13_good_card')));
    }, skip: _skip('o13_good_card'), tags: ['golden']);
  });

  group('O13 lost (c12)', () {
    testWidgets('texts, all red, 6 px blur, 45 % brightness', (tester) async {
      await _pump(tester, SenseLinkLayer(view: _lost, onEnd: () {}));
      expect(find.text('Bağlantı kesildi'), findsOneWidget);
      expect(find.text('Son görüntü 9 sn önce geldi. Uzak bilgisayar çalışıyor olabilir.'),
          findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('%100'), findsOneWidget);
      expect(find.text('0 fps'), findsOneWidget);
      expect(_valueColor(tester, '0 fps'), SenseColors.dangerText);
      expect(find.text('Yeniden bağlanılıyor · 3. deneme · 21 sn sonra oturum kapanır'),
          findsOneWidget);
      final veil = tester.widget<SenseLayerVeil>(find.byType(SenseLayerVeil));
      expect(veil.blur, 6);
      expect(veil.brightness, 0.45);
    });

    testWidgets('golden c12', (tester) async {
      await _pump(tester, SenseLinkLayer(view: _lost, onEnd: () {}));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('o13_lost_c12')));
    }, skip: _skip('o13_lost_c12'), tags: ['golden']);
  });

  // Sürüm 11 (#121): logged in, no picture: a Turkish card instead of a black screen.
  group('#121 waiting for the picture', () {
    testWidgets('relay: title, path, status line, end button', (tester) async {

      await _pump(tester, SenseWaitingImageLayer(direct: false, onEnd: () {}));
      expect(find.text('Görüntü bekleniyor'), findsOneWidget);
      expect(find.text('Aktarma sunucusu üzerinden; yavaş olabilir'), findsOneWidget);
      expect(find.text('Uzak bilgisayardan ilk görüntü isteniyor…'), findsOneWidget);
      expect(find.byKey(const Key('sense-waiting-end')), findsOneWidget);
    });

    testWidgets('direct and unknown path', (tester) async {
      await _pump(tester, SenseWaitingImageLayer(direct: true, onEnd: () {}));
      expect(find.text('Doğrudan bağlantı'), findsOneWidget);
      await _pump(tester, SenseWaitingImageLayer(direct: null, onEnd: () {}));
      expect(find.text('Bağlantı türü ölçülüyor'), findsOneWidget);
    });

    testWidgets('lost card with no attempt yet says so without a count', (tester) async {
      await _pump(
          tester,
          SenseLinkLayer(
              view: const SenseLinkView(
                  phase: SenseLinkPhase.lost,
                  sample: SenseLinkSample(fps: 0),
                  stall: Duration(seconds: 2),
                  lostFor: Duration(seconds: 1)),
              onEnd: () {}));
      expect(find.text('Yeniden bağlanılıyor · 29 sn sonra oturum kapanır'), findsOneWidget);
    });
  });

  group('O14 ended (n07)', () {
    Widget card({SenseReconnectState r = SenseReconnectState.idle, VoidCallback? close,
            VoidCallback? again, SenseSessionSummary s = _summary}) =>
        SenseEndedLayer(
          summary: s,
          backHomeIn: 5,
          reconnect: r,
          onClose: close ?? () {},
          onReconnect: again ?? () {},
        );

    testWidgets('reason, duration, chat summary, countdown', (tester) async {
      await _pump(tester, card());
      expect(find.text('Bağlantı sona erdi'), findsOneWidget);
      expect(find.text('Sahadaki kişi bağlantıyı bitirdi'), findsOneWidget);
      expect(find.text('42 dk'), findsOneWidget);
      expect(find.text('süre'), findsOneWidget);
      expect(find.text('3 mesaj · 1 dosya'), findsOneWidget);
      expect(find.text('sohbet silindi'), findsOneWidget);
      expect(find.text('5 sn sonra ana ekrana dönülüyor'), findsOneWidget);
    });

    testWidgets('each of the three reasons', (tester) async {
      for (final r in SenseEndReason.values) {
        final s = SenseSessionSummary(
            reason: r, duration: Duration.zero, messages: 0, files: 0, idleLimit: const Duration(minutes: 30));
        await _pump(tester, card(s: s));
        expect(find.text(s.reasonText), findsOneWidget);
      }
    });

    testWidgets('Kapat and Yeniden bağlan', (tester) async {
      var closed = 0, again = 0;
      await _pump(tester, card(close: () => closed++, again: () => again++));
      await tester.tap(find.byKey(const Key('sense-ended-close')));
      await tester.tap(find.byKey(const Key('sense-ended-reconnect')));
      expect(closed, 1);
      expect(again, 1);
    });

    testWidgets('connecting: Bağlanıyor…, Yeniden bağlan faded', (tester) async {
      var again = 0;
      await _pump(tester, card(r: SenseReconnectState.connecting, again: () => again++));
      expect(find.text('Bağlanıyor…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-ended-reconnect')));
      expect(again, 0);
    });

    testWidgets('busy computer: Meşgul', (tester) async {
      await _pump(tester, card(r: SenseReconnectState.busy));
      expect(find.text('Meşgul · 5 sn sonra ana ekrana dönülüyor'), findsOneWidget);
    });

    testWidgets('golden n07', (tester) async {
      await _pump(tester, card());
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('o14_ended_n07')));
    }, skip: _skip('o14_ended_n07'), tags: ['golden']);
  });

  group('O15 idle strip (n08)', () {
    testWidgets('34 px, left aligned, countdown, Devam et', (tester) async {
      var go = 0;
      await _pump(
          tester,
          Stack(children: [
            Positioned(
              top: SenseSizes.sessionToolbarHeight,
              left: 0,
              right: 0,
              child: SenseIdleStrip(secondsLeft: 55, onContinue: () => go++),
            ),
          ]));
      final box = tester.getRect(find.byKey(const Key('sense-idle-strip')));
      expect(box.height, SenseLayerLook.idleHeight);
      expect(box.top, SenseSizes.sessionToolbarHeight);
      expect(box.width, 1280);
      expect(find.textContaining('Bağlantı hareketsiz · 55 sn içinde kesilecek', findRichText: true),
          findsOneWidget);
      final text = tester.getRect(find.textContaining('Bağlantı hareketsiz', findRichText: true));
      expect(text.left, lessThan(1280 / 3), reason: 'left, not under the island');
      await tester.tap(find.byKey(const Key('sense-idle-continue')));
      expect(go, 1);
    });

    testWidgets('golden n08', (tester) async {
      await _pump(
          tester,
          Stack(children: [
            Positioned(
              top: SenseSizes.sessionToolbarHeight,
              left: 0,
              right: 0,
              child: SenseIdleStrip(secondsLeft: 55, onContinue: () {}),
            ),
          ]));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_golden('o15_idle_n08')));
    }, skip: _skip('o15_idle_n08'), tags: ['golden']);
  });

  group('all layers together (controller)', () {
    late FakeClock clock;
    late FakeHost host;
    late SenseLayerController c;

    setUp(() {
      clock = FakeClock();
      host = FakeHost(clock)..healthy();
      c = SenseLayerController(
        host: host,
        idleLimit: const Duration(minutes: 30),
        clock: () => clock.mono,
        wall: () => clock.wall,
        autoStart: false,
      );
    });

    tearDown(() => c.dispose());

    Future<void> seconds(WidgetTester tester, int n, [void Function()? each]) async {
      for (var i = 0; i < n; i++) {
        clock.advance(const Duration(seconds: 1));
        each?.call();
        c.tick();
      }
      await tester.pump();
    }

    testWidgets('nothing up: no layer, clicks pass through', (tester) async {
      var taps = 0;
      await _pump(
          tester,
          Stack(children: [
            Positioned.fill(child: GestureDetector(onTap: () => taps++)),
            Positioned.fill(child: SenseSessionLayers(id: 'p1', controller: c, listenToInput: false)),
          ]));
      expect(find.byType(SenseLayerVeil), findsNothing);
      await tester.tapAt(const Offset(400, 400));
      expect(taps, 1);
    });

    testWidgets('weak layer comes and goes with the "Bağlantı düzeldi" toast', (tester) async {
      await _pump(tester, SenseSessionLayers(id: 'p1', controller: c, listenToInput: false));
      await seconds(tester, 16, host.weakFps);
      expect(find.text(SenseLayerStrings.weakTitle), findsOneWidget);
      await seconds(tester, 4, host.healthy);
      expect(find.text(SenseLayerStrings.weakTitle), findsNothing);
      expect(find.text('Bağlantı düzeldi'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('x shrinks the weak card; the logo area opens it again', (tester) async {
      await _pump(tester, SenseSessionLayers(id: 'p1', controller: c, listenToInput: false));
      await seconds(tester, 16, host.weakFps);
      expect(find.byKey(const Key('sense-layer-minimize')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-layer-minimize')));
      await tester.pump();
      expect(c.minimized, isTrue);
      expect(find.text(SenseLayerStrings.weakTitle), findsNothing);
      expect(find.byKey(const Key('sense-layer-minimize')), findsNothing);
      await seconds(tester, 40, host.weakFps);
      expect(find.text(SenseLayerStrings.weakTitle), findsNothing, reason: 'does not reopen itself');
      c.restoreCard(); // what the bar's logo area calls
      await tester.pump();
      expect(find.text(SenseLayerStrings.weakTitle), findsOneWidget);
    });

    testWidgets('#110: logo area on a good link opens the info card; x closes it', (tester) async {
      await _pump(tester, SenseSessionLayers(id: 'p1', controller: c, listenToInput: false), popupOpen: false);
      await seconds(tester, 3, host.healthy);
      expect(find.byType(SenseLayerVeil), findsNothing);
      c.openCard(); // what the bar's logo area calls
      await tester.pump();
      expect(find.text(SenseLayerStrings.goodTitle), findsOneWidget);
      expect(find.text('20 ms'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-layer-minimize')));
      await tester.pump();
      expect(c.infoOpen, isFalse);
      expect(find.byType(SenseLayerVeil), findsNothing);
    });

    // Sürüm 12 (#150): on the device the logo showed the forbidden cursor. remote_page.dart
    // rebuilds its body in another wrapper when the first picture comes, so the layer is
    // mounted anew with the same controller; the old dispose used to drop the registration
    // and the bar never found the card again.
    testWidgets('#150: after the layer is remounted the logo still opens the card (good link)', (tester) async {
      void link() => host.raw = SenseLinkRaw(
            delay: '3',
            fps: '60',
            lossEst: 0,
            lastFrameMs: 10,
            lastFrameAt: clock.wall,
            probeAt: clock.wall,
            serverName: 'Almanya',
          );
      link();
      final backend = FakeBackend(
        link: bar.SenseLinkSample(
          path: bar.SenseLinkPath.direct,
          fps: 0,
          rttMs: 3,
          lastFrameMs: 9000,
          wavy: false,
          recentFps: 120,
          remoteHz: 144,
          onRestoreLayer: () => SenseLayerController.find('p1')?.openCard(),
        ),
      )..ready = false; // values still being measured: the card opens anyway
      Widget window({required bool wrapped}) {
        final layer = SenseSessionLayers(id: 'p1', controller: c, listenToInput: false);
        return MaterialApp(
          theme: senseTheme(),
          home: Scaffold(
            body: Stack(children: [
              Positioned.fill(
                child: SenseSessionFrame(backend: backend, popups: FakePopups(), child: const SizedBox.expand()),
              ),
              Positioned.fill(child: wrapped ? Padding(padding: EdgeInsets.zero, child: layer) : layer),
            ]),
          ),
        );
      }

      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(window(wrapped: false));
      await seconds(tester, 3, link);
      SenseFrameCap.of('p1').value = const SenseFrameInfo(drawnFps: 58, recentFps: 120, reachableFps: 120, remoteHz: 144);
      // The first picture arrives: remote_page puts its body in BlockableOverlay.
      await tester.pumpWidget(window(wrapped: true));
      expect(SenseLayerController.find('p1'), same(c), reason: 'the remount keeps the registration');

      final area = find.byKey(const ValueKey('sense-bar-link'));
      final detector = tester.widget<FocusableActionDetector>(
          find.descendant(of: area, matching: find.byType(FocusableActionDetector)));
      expect(detector.enabled, isTrue);
      expect(detector.mouseCursor, SystemMouseCursors.click, reason: 'no forbidden cursor');
      final line = tester.widget<Text>(find.byKey(const ValueKey('sense-bar-link-text')));
      expect(line.data, '120 fps · 3 ms');

      await tester.tap(area);
      await tester.pump();
      expect(c.infoOpen, isTrue);
      expect(find.text(SenseLayerStrings.goodTitle), findsOneWidget);
      expect(find.byKey(const Key('sense-layer-info-server')), findsOneWidget);
      expect(find.text('Kare hızı: 58 fps · karşı ekran 144 Hz'), findsOneWidget, reason: 'moving picture: drawn rate');
      SenseFrameCap.remove('p1');

      await tester.pumpWidget(const SizedBox());
      expect(SenseLayerController.find('p1'), isNull, reason: 'gone with the last layer widget');
    });

    testWidgets('lost card keeps showing and has no x', (tester) async {
      await _pump(tester, SenseSessionLayers(id: 'p1', controller: c, listenToInput: false));
      await seconds(tester, 1, host.healthy);
      await seconds(tester, 10);
      expect(SenseSessionHub.onMessage('p1', 'restarting-show', 'Connecting...', 'Connection in progress.'), isTrue);
      await tester.pump();
      expect(find.text(SenseLayerStrings.lostTitle), findsOneWidget);
      expect(find.byKey(const Key('sense-layer-minimize')), findsNothing);
    });

    testWidgets('a Host message reaches the card through the hub', (tester) async {
      await _pump(tester, SenseSessionLayers(id: 'p1', controller: c, listenToInput: false));
      expect(SenseSessionHub.onMessage('p1', 'error', 'Connection Error', 'Closed manually by the peer'),
          isTrue);
      await tester.pump();
      expect(find.text('Bağlantı sona erdi'), findsOneWidget);
      expect(SenseSessionHub.onMessage('other', 'error', 'Connection Error', 'Timeout'), isFalse);
    });

    testWidgets('idle strip, Devam et resets', (tester) async {
      await _pump(tester, SenseSessionLayers(id: 'p1', controller: c, listenToInput: false));
      await seconds(tester, 29 * 60, host.healthy);
      expect(find.byKey(const Key('sense-idle-strip')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-idle-continue')));
      await tester.pump();
      expect(find.byKey(const Key('sense-idle-strip')), findsNothing);
      expect(host.calls, contains('keepAlive'));
    });

    testWidgets('window input counts as activity', (tester) async {
      await _pump(tester, SenseSessionLayers(id: 'p1', controller: c));
      await seconds(tester, 29 * 60 + 5, host.healthy);
      expect(find.byKey(const Key('sense-idle-strip')), findsOneWidget);
      await tester.tapAt(const Offset(600, 600));
      await tester.pump();
      expect(find.byKey(const Key('sense-idle-strip')), findsNothing);
    });

    testWidgets('the top bar can read "Dalgalı"', (tester) async {
      await _pump(tester, SenseSessionLayers(id: 'p1', controller: c, listenToInput: false));
      expect(SenseLayerController.find('p1'), same(c));
      await seconds(tester, 2, host.slow);
      expect(SenseLayerController.find('p1')!.wavy.value, isTrue);
    });
  });
}
