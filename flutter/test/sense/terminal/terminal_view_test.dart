// Sense Remote (Sürüm 12, ST 4–5, #157): the Sense terminal window body — admin step in
// place (T7), request / failure strips with the right choices, rights badge, footer, the
// clipboard notice — and goldens compared with the prototype `auxTerm` (prototype screenshot
// "S12 — terminal": title bar, tab, black box, footer). Images are made on CI (sense-golden.yml);
// until one exists its test is skipped.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/shared/aux_window/aux_window_frame.dart';
import 'package:flutter_hbb/sense/screens/terminal/aux_parts.dart';
import 'package:flutter_hbb/sense/screens/terminal/clip_notice.dart';
import 'package:flutter_hbb/sense/screens/terminal/terminal_admin.dart';
import 'package:flutter_hbb/sense/screens/terminal/terminal_view.dart';
import 'package:flutter_hbb/sense/screens/terminal/terminal_keys.dart';
import 'package:flutter_hbb/sense/strings/terminal.dart';

const String _dir = 'test/goldens/terminal';
String _file(String name) => '../../goldens/terminal/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_dir/$name.png').existsSync();

const _pc = 'Giriş Salonu PC-2';

Widget _app(Widget child, {Size size = const Size(1000, 560)}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: true),
        child: ColoredBox(color: SenseColors.bg, child: child),
      ),
    );

/// Stand-in for RustDesk's xterm view (the prototype's sample output).
class _FakeTerminal extends StatelessWidget {
  const _FakeTerminal({this.admin = false});
  final bool admin;

  @override
  Widget build(BuildContext context) {
    final p = admin ? r'C:\Windows\system32>' : r'C:\Users\Sense>';
    final dim = SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textMuted, height: 1.6);
    final out = SenseTextStyles.of(size: SenseFontSize.bodySmall, color: SenseColors.textSecondary, height: 1.6);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text.rich(TextSpan(children: [
        TextSpan(text: '$p ', style: dim),
        TextSpan(text: 'hostname\n', style: out),
        TextSpan(text: 'GIRIS-SALON-02\n\n', style: out),
        TextSpan(text: '$p ', style: dim),
        TextSpan(text: 'tasklist\n', style: out),
        TextSpan(text: 'mediaserver.exe   4120 Console   1   812.340 K\n', style: out),
        TextSpan(text: 'SenseRemote.exe   2284 Services  0    41.120 K\n\n', style: out),
        TextSpan(text: p, style: dim),
      ])),
    );
  }
}

Widget _window(Widget body, {bool admin = false}) => SenseAuxWindowFrame(
      title: SenseTerminalStrings.title,
      subject: _pc,
      live: const SenseAuxLive('Doğrudan · ekran açılmadı', SenseLevel.ok),
      badges: admin ? const [SenseAuxBadge(label: SenseTerminalStrings.adminChip, level: SenseLevel.warn)] : const [],
      tabs: [SenseAuxTab(key: 'p_1', label: SenseTerminalStrings.tabLabel(1))],
      alwaysShowTabs: true,
      onSelectTab: (_) {},
      onCloseTab: (_) {},
      onNewTab: () {},
      actions: SenseAuxWindowActions(onMinimize: () {}, onToggleMaximize: () {}, onClose: () {}),
      child: body,
    );

void main() {
  group('tab keys', () {
    test('peer and terminal number; ids with "_" split at the last one', () {
      expect(senseTerminalTabKey('123456789_2'), ('123456789', 2));
      expect(senseTerminalTabKey('a_b_3'), ('a_b', 3));
      expect(senseTerminalTabKey('nounderscore'), isNull);
      expect(senseTerminalTabKey('x_y'), isNull);
    });
  });

  group('admin view', () {
    test('from the controller phase; asking wins', () {
      final c = SenseTermAdminController(peerId: 'v1', begin: () async => 'busy');
      expect(senseTerminalAdminViewOf(null, asking: false), SenseTerminalAdminView.none);
      expect(senseTerminalAdminViewOf(c, asking: false), SenseTerminalAdminView.none);
      expect(senseTerminalAdminViewOf(c, asking: true), SenseTerminalAdminView.asking);
      c.dispose();
    });
  });

  group('body', () {
    testWidgets('normal terminal: badge, note, buttons; Yönetici olarak aç asks in place', (tester) async {
      var asked = 0, closed = 0;
      await tester.pumpWidget(_app(SenseTerminalBody(
        computer: _pc,
        terminal: const SizedBox.expand(),
        onCopyOutput: () => 'x',
        onAskAdmin: () => asked++,
        onClose: () => closed++,
      )));
      expect(find.text(SenseTerminalStrings.normalUser), findsOneWidget);
      expect(find.text(SenseTerminalStrings.footNote), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-term-admin')));
      await tester.tap(find.byKey(const Key('sense-term-close')));
      expect([asked, closed], [1, 1]);
    });

    testWidgets('asking: question names the computer; Vazgeç and Yönetici olarak aç call back', (tester) async {
      var cancel = 0, go = 0;
      await tester.pumpWidget(_app(SenseTerminalBody(
        computer: _pc,
        terminal: const SizedBox.expand(),
        adminView: SenseTerminalAdminView.asking,
        onAskAdmin: () {},
        onCancelAsk: () => cancel++,
        onConfirmAdmin: () => go++,
      )));
      expect(find.text(SenseTerminalStrings.askTitle), findsOneWidget);
      expect(find.textContaining(_pc), findsOneWidget);
      // While asking, the footer button is off (one question at a time).
      final footer = tester.widget<SenseButton>(find.byKey(const Key('sense-term-admin')));
      expect(footer.onPressed, isNull);
      await tester.tap(find.byKey(const Key('sense-term-ask-cancel')));
      await tester.tap(find.byKey(const Key('sense-term-ask-go')));
      expect([cancel, go], [1, 1]);
    });

    testWidgets('admin granted: orange badge, footer button off', (tester) async {
      await tester.pumpWidget(_app(SenseTerminalBody(
        computer: _pc,
        terminal: const SizedBox.expand(),
        admin: true,
        onAskAdmin: () {},
      )));
      expect(find.text(SenseTerminalStrings.adminRights), findsOneWidget);
      final b = tester.widget<SenseButton>(find.byKey(const Key('sense-term-admin')));
      expect(b.onPressed, isNull);
      final box = tester.widget<Container>(find.byKey(const Key('sense-term-box')));
      final border = (box.decoration as BoxDecoration).border as Border;
      expect(border.top.color, SenseColors.warn);
    });

    testWidgets('requesting: spinner strip, no choices', (tester) async {
      await tester.pumpWidget(_app(const SenseTerminalBody(
        computer: _pc,
        terminal: SizedBox.expand(),
        adminView: SenseTerminalAdminView.requesting,
      )));
      expect(find.text(SenseTerminalStrings.requesting), findsOneWidget);
      expect(find.byType(SenseSpinner), findsOneWidget);
    });

    testWidgets('unsupported: Windows hesabıyla aç (stock box fallback) and Normal terminal aç', (tester) async {
      var normal = 0, stock = 0;
      await tester.pumpWidget(_app(SenseTerminalBody(
        computer: _pc,
        terminal: const SizedBox.expand(),
        adminView: SenseTerminalAdminView.failed,
        adminError: 'unsupported',
        onOpenNormal: () => normal++,
        onWindowsAccount: () => stock++,
        onRetryAdmin: () {},
        onClose: () {},
      )));
      expect(find.text(SenseTerminalStrings.error('unsupported')), findsOneWidget);
      expect(find.byKey(const Key('sense-term-retry')), findsNothing);
      await tester.tap(find.byKey(const Key('sense-term-windows-account')));
      await tester.tap(find.byKey(const Key('sense-term-open-normal')));
      expect([normal, stock], [1, 1]);
    });

    testWidgets('not_admin: no stock fallback, no retry; expired: retry', (tester) async {
      Widget body(String code) => _app(SenseTerminalBody(
            key: ValueKey(code),
            computer: _pc,
            terminal: const SizedBox.expand(),
            adminView: SenseTerminalAdminView.failed,
            adminError: code,
            onOpenNormal: () {},
            onWindowsAccount: () {},
            onRetryAdmin: () {},
          ));
      await tester.pumpWidget(body('not_admin'));
      expect(find.text(SenseTerminalStrings.error('not_admin')), findsOneWidget);
      expect(find.byKey(const Key('sense-term-windows-account')), findsNothing);
      expect(find.byKey(const Key('sense-term-retry')), findsNothing);
      await tester.pumpWidget(body('expired'));
      expect(find.byKey(const Key('sense-term-retry')), findsOneWidget);
    });

    testWidgets('Çıktıyı kopyala copies the buffer and says Kopyalandı', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(_app(SenseTerminalBody(
        computer: _pc,
        terminal: const SizedBox.expand(),
        onCopyOutput: () => 'GIRIS-SALON-02',
      )));
      await tester.tap(find.byKey(const Key('sense-term-copy')));
      await tester.pump();
      expect(copied, 'GIRIS-SALON-02');
      expect(find.text(SenseTerminalStrings.copied), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(SenseTerminalStrings.copyOutput), findsOneWidget);
    });

    testWidgets('clipboard notice: persistable → İzin ver / İzin verme', (tester) async {
      var yes = 0, no = 0;
      await tester.pumpWidget(_app(Align(
        alignment: Alignment.topCenter,
        child: SenseTerminalClipNotice(persistAllowed: true, onPositive: () => yes++, onNegative: () => no++),
      )));
      expect(find.text(SenseTerminalStrings.clipAllow), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-term-clip-yes')));
      await tester.tap(find.byKey(const Key('sense-term-clip-no')));
      expect([yes, no], [1, 1]);
    });
  });

  group('goldens', () {
    Future<void> shoot(WidgetTester tester, String name, Widget w, {Size size = const Size(1000, 560)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(RepaintBoundary(key: const Key('golden'), child: w), size: size));
      await tester.pump();
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file(name)));
    }

    const n1 = 'terminal_normal';
    testWidgets('golden: normal terminal window', (tester) async {
      await shoot(
          tester,
          n1,
          _window(SenseTerminalBody(
            computer: _pc,
            terminal: const _FakeTerminal(),
            onCopyOutput: () => '',
            onAskAdmin: () {},
            onClose: () {},
          )));
    }, skip: _skip(n1), tags: const ['golden']);

    const n2 = 'terminal_ask_admin';
    testWidgets('golden: Yönetici olarak açılsın mı? in place', (tester) async {
      await shoot(
          tester,
          n2,
          _window(SenseTerminalBody(
            computer: _pc,
            terminal: const _FakeTerminal(),
            adminView: SenseTerminalAdminView.asking,
            onCopyOutput: () => '',
            onAskAdmin: () {},
            onCancelAsk: () {},
            onConfirmAdmin: () {},
            onClose: () {},
          )));
    }, skip: _skip(n2), tags: const ['golden']);

    const n3 = 'terminal_admin';
    testWidgets('golden: admin terminal (orange frame, chip, badge)', (tester) async {
      await shoot(
          tester,
          n3,
          _window(
            SenseTerminalBody(
              computer: _pc,
              admin: true,
              terminal: const _FakeTerminal(admin: true),
              onCopyOutput: () => '',
              onAskAdmin: () {},
              onClose: () {},
            ),
            admin: true,
          ));
    }, skip: _skip(n3), tags: const ['golden']);

    const n4 = 'terminal_admin_unsupported';
    testWidgets('golden: admin refused (unsupported) with the fallback', (tester) async {
      await shoot(
          tester,
          n4,
          _window(SenseTerminalBody(
            computer: _pc,
            terminal: const SizedBox.expand(),
            adminView: SenseTerminalAdminView.failed,
            adminError: 'unsupported',
            onOpenNormal: () {},
            onWindowsAccount: () {},
            onRetryAdmin: () {},
            onClose: () {},
          )));
    }, skip: _skip(n4), tags: const ['golden']);

    const n5 = 'terminal_admin_not_admin';
    testWidgets('golden: admin refused (not_admin)', (tester) async {
      await shoot(
          tester,
          n5,
          _window(SenseTerminalBody(
            computer: _pc,
            terminal: const SizedBox.expand(),
            adminView: SenseTerminalAdminView.failed,
            adminError: 'not_admin',
            onOpenNormal: () {},
            onClose: () {},
          )));
    }, skip: _skip(n5), tags: const ['golden']);

    const n6 = 'terminal_clip_notice';
    testWidgets('golden: clipboard notice in Sense colours', (tester) async {
      await shoot(
          tester,
          n6,
          Align(
            alignment: Alignment.topCenter,
            child: SenseTerminalClipNotice(persistAllowed: true, onPositive: () {}, onNegative: () {}),
          ),
          size: const Size(640, 200));
    }, skip: _skip(n6), tags: const ['golden']);
  });
}
