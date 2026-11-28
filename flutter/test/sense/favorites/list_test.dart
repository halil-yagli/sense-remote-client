// Sense Remote (Sürüm 12, #160–#163, #167): the "Sık kullanılanlar" list on screen —
// choosing from the catalogue, search, running, the in-place question, panes, grey rows
// without permission, Linux placeholder, the custom form, the bar button and the hotkeys.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/catalog.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_ffi.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_list.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_model.dart';
import 'package:flutter_hbb/sense/strings/favorites.dart';
import 'package:uuid/uuid.dart';

import 'support.dart';

Future<SenseFavoritesModel> pumpList(WidgetTester t, FakeFavIo io,
    {SenseFavOs? os = SenseFavOs.win, bool input = true, List<String>? notes, VoidCallback? onClose}) async {
  setWindow(t, const Size(500, 1400));
  final m = SenseFavoritesModel(
      io: io, os: os, peerId: 'p1', computerName: 'Giriş Salonu PC-2', inputAllowed: input, onNotice: notes?.add);
  if (os != null) await m.load();
  await t.pumpWidget(listApp(SenseFavoritesList(model: m, onNotify: notes?.add, onClose: onClose)));
  await t.pump();
  addTearDown(m.dispose);
  return m;
}

void main() {
  setUp(senseFavResetMemory);

  testWidgets('empty list: hint, count 0, catalogue groups closed, local footer', (t) async {
    await pumpList(t, FakeFavIo());
    expect(find.text('Sık kullanılanlar'), findsOneWidget);
    expect(find.text('0 kısayol'), findsOneWidget);
    expect(find.text('Windows için kısayolların'), findsOneWidget);
    expect(find.byKey(const ValueKey('sense-fav-mine-empty')), findsOneWidget);
    expect(find.text('KISAYOLLARIM'), findsOneWidget);
    expect(find.text('EKLENEBİLECEK KISAYOLLAR'), findsOneWidget);
    expect(find.text('Sistem hareketleri'), findsOneWidget);
    expect(find.text('Mac’e özel'), findsNothing, reason: 'Windows list');
    expect(find.text('Özel kısayollar'), findsOneWidget);
    expect(find.text('Görev Yöneticisi'), findsNothing, reason: 'groups closed');
    expect(find.text(SenseFavoritesStrings.footerLocal), findsOneWidget);
  });

  testWidgets('a tick in the catalogue adds the row to Kısayollarım', (t) async {
    final notes = <String>[];
    final m = await pumpList(t, FakeFavIo(), notes: notes);
    await t.tap(find.byKey(const ValueKey('sense-fav-group-files')));
    await t.pump();
    expect(find.text('Süreçler ve kaynak kullanımı'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sense-fav-pick-win.taskmgr')));
    await t.pump();
    expect(m.mine.single.id, 'win.taskmgr');
    expect(find.byKey(const ValueKey('sense-fav-run-win.taskmgr')), findsOneWidget);
    expect(find.text('1 kısayol'), findsOneWidget);
    expect(find.text('1 seçili · 5'), findsOneWidget);
    expect(notes.last, 'Görev Yöneticisi · kısayollara eklendi');
  });

  testWidgets('search opens every matching group; nothing found says so', (t) async {
    await pumpList(t, FakeFavIo());
    await t.enterText(find.byKey(const ValueKey('sense-fav-search')), 'dns');
    await t.pump();
    expect(find.text('DNS önbelleğini temizle'), findsOneWidget);
    expect(find.text('IP bilgisi'), findsOneWidget, reason: 'its description says DNS');
    expect(find.text('Sistem hareketleri'), findsNothing);
    // Turkish case: "İzleyici" is found with "izleyici".
    await t.enterText(find.byKey(const ValueKey('sense-fav-search')), 'izleyici');
    await t.pump();
    expect(find.text('Kaynak İzleyicisi'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('sense-fav-search')), 'zzzz');
    await t.pump();
    expect(find.byKey(const ValueKey('sense-fav-no-match')), findsOneWidget);
  });

  testWidgets('one click runs, the list closes, the Host is asked by id only', (t) async {
    final io = FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs()}, setAnswer: '');
    var closed = 0;
    final m = await pumpList(t, io, onClose: () => closed++);
    expect(find.text('3 kısayol'), findsOneWidget);
    expect(find.text('Ctrl+Alt+Shift+1'), findsOneWidget);
    expect(find.text(SenseFavoritesStrings.footer), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sense-fav-run-win.taskmgr')));
    await t.pump();
    expect(io.sent.single.$2, {'req': 1, 'id': 'win.taskmgr'});
    expect(closed, 1);
    m.dispose(); // the 8 s answer timer
  });

  testWidgets('a row that cannot be undone asks in place first', (t) async {
    final io = FakeFavIo(prefs: {
      SenseFavOs.win: prefsJson(os: SenseFavOs.win, items: [
        {'id': 'win.logoff', 'key': null}
      ])
    }, setAnswer: '');
    final m = await pumpList(t, io);
    expect(find.text('Sor ›'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sense-fav-run-win.logoff')));
    await t.pump();
    expect(find.text('Oturum kapatılsın mı?'), findsOneWidget);
    expect(find.text('Açık programlardaki kaydedilmemiş işler kaybolabilir.'), findsOneWidget);
    expect(io.sent, isEmpty);
    await t.tap(find.byKey(const ValueKey('sense-fav-ask-cancel')));
    await t.pump();
    expect(find.text('Oturum kapatılsın mı?'), findsNothing);
    await t.tap(find.byKey(const ValueKey('sense-fav-run-win.logoff')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('sense-fav-ask-ok')));
    await t.pump();
    expect(io.sent.single.$2['id'], 'win.logoff');
    m.dispose();
  });

  testWidgets('IP card and ping open under their rows', (t) async {
    final io = FakeFavIo(prefs: {
      SenseFavOs.win: prefsJson(os: SenseFavOs.win, items: [
        {'id': 'win.ipinfo', 'key': null},
        {'id': 'win.ping', 'key': null},
        {'id': 'win.killhung', 'key': null},
      ])
    }, setAnswer: '');
    final m = await pumpList(t, io);
    m.ipInfo = () => const SenseFavIpInfo(ip: '192.168.10.42', gateway: ['192.168.10.1'], dns: ['192.168.10.1', '8.8.8.8']);
    await t.tap(find.byKey(const ValueKey('sense-fav-run-win.ipinfo')));
    await t.pump();
    expect(find.text('192.168.10.42'), findsOneWidget);
    expect(find.text('192.168.10.1 · 8.8.8.8'), findsOneWidget);
    expect(io.sent, isEmpty, reason: 'the card reads data the session has');
    expect(m.recent.first.id, 'win.ipinfo');

    await t.tap(find.byKey(const ValueKey('sense-fav-run-win.ping')));
    await t.pump();
    expect(find.text('192.168.10.42'), findsNothing, reason: 'one pane at a time');
    await t.tap(find.byKey(const ValueKey('sense-fav-ping-start')));
    await t.pump();
    expect(find.text(SenseFavoritesStrings.pingUnsupported), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('sense-fav-run-win.killhung')));
    await t.pump();
    expect(find.byKey(const ValueKey('sense-fav-windows-unsupported')), findsOneWidget);
  });

  testWidgets('key slots: pick one, it shows on the row; "Yok" clears it', (t) async {
    final io = FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs()}, setAnswer: '');
    final m = await pumpList(t, io);
    await t.tap(find.byKey(const ValueKey('sense-fav-key-win.taskmgr')));
    await t.pump();
    expect(find.byKey(const ValueKey('sense-fav-slot-5')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sense-fav-slot-5')));
    await t.pump();
    expect(m.keyOf('win.taskmgr'), 5);
    expect(find.text('Ctrl+Alt+Shift+5'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sense-fav-key-win.taskmgr')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('sense-fav-slot-none')));
    await t.pump();
    expect(m.keyOf('win.taskmgr'), isNull);
  });

  testWidgets('without keyboard and mouse permission: grey, nothing runs', (t) async {
    final io = FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs()}, setAnswer: '');
    await pumpList(t, io, input: false);
    expect(find.byKey(const ValueKey('sense-fav-passive')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sense-fav-run-win.taskmgr')), warnIfMissed: false);
    await t.tap(find.byKey(const ValueKey('sense-fav-recent-win.netadapt')), warnIfMissed: false);
    await t.pump();
    expect(io.sent, isEmpty);
    // The catalogue can still be edited.
    await t.tap(find.byKey(const ValueKey('sense-fav-group-actions')));
    await t.pump();
    expect(find.byKey(const ValueKey('sense-fav-pick-win.cad')), findsOneWidget);
  });

  testWidgets('a Mac connection shows the Mac list; Linux a placeholder (#163)', (t) async {
    final io = FakeFavIo(prefs: {SenseFavOs.mac: prototypeMacPrefs()}, setAnswer: '');
    final m = await pumpList(t, io, os: SenseFavOs.mac);
    expect(find.text('Mac için kısayolların'), findsOneWidget);
    expect(find.text('Etkinlik Monitörü'), findsWidgets);
    expect(find.text('Cmd+Option+Shift+1'), findsNothing, reason: 'the Controller is not a Mac here');
    expect(find.text('Mac’e özel'), findsOneWidget);
    m.setOs(SenseFavOs.linux);
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('sense-fav-linux')), findsOneWidget);
    expect(find.text('Linux'), findsOneWidget);
  });

  testWidgets('before the peer info arrives the list waits', (t) async {
    await pumpList(t, FakeFavIo(), os: null);
    expect(find.byKey(const ValueKey('sense-fav-os-waiting')), findsOneWidget);
  });

  testWidgets('custom form: checks in place, says this build cannot send yet', (t) async {
    await pumpList(t, FakeFavIo());
    await t.tap(find.byKey(const ValueKey('sense-fav-group-custom')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('sense-fav-add')));
    await t.pump();
    expect(find.byKey(const ValueKey('sense-fav-form')), findsOneWidget);
    expect(find.text(SenseFavoritesStrings.formNote), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sense-fav-form-add')));
    await t.pump();
    expect(find.text(SenseFavoritesStrings.formMissing), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('sense-fav-form-name')), 'Sergi uygulaması');
    await t.enterText(find.byKey(const ValueKey('sense-fav-form-path')), r'C:\Sergi\sergi.exe');
    await t.tap(find.byKey(const ValueKey('sense-fav-form-add')));
    await t.pump();
    await t.pump();
    expect(find.text(SenseFavoritesStrings.formUnsupported), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('sense-fav-form-cancel')));
    await t.pump();
    expect(find.byKey(const ValueKey('sense-fav-form')), findsNothing);
  });

  testWidgets('custom form sent: pending row with "Onay bekliyor"', (t) async {
    final notes = <String>[];
    await pumpList(t, FakeFavIo(customAnswer: '{"id":"a1","status":"pending"}'), notes: notes);
    await t.tap(find.byKey(const ValueKey('sense-fav-group-custom')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('sense-fav-add')));
    await t.pump();
    await t.enterText(find.byKey(const ValueKey('sense-fav-form-name')), 'Sergi uygulaması');
    await t.enterText(find.byKey(const ValueKey('sense-fav-form-path')), r'C:\Sergi\sergi.exe');
    await t.tap(find.byKey(const ValueKey('sense-fav-form-add')));
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('sense-fav-form')), findsNothing);
    expect(find.text('Onay bekliyor'), findsOneWidget);
    expect(notes.last, 'Yönetici onayına gönderildi · Windows');
  });

  testWidgets('bar button: name on a wide window, a star with a tooltip on a narrow one (#167)', (t) async {
    setWindow(t, const Size(600, 200));
    var taps = 0;
    await t.pumpWidget(listApp(Row(mainAxisSize: MainAxisSize.min, children: [
      SenseFavoritesButton(compact: false, onTap: () => taps++),
      const SenseFavoritesButton(compact: true, open: true),
    ])));
    expect(find.text('Sık kullanılanlar'), findsOneWidget);
    expect(find.byKey(const ValueKey('sense-fav-star')), findsOneWidget);
    expect(find.byTooltip('Sık kullanılanlar'), findsOneWidget);
    expect(find.text('Kısayollar'), findsNothing, reason: 'never clashes with Klavye › Kısayollar');
    await t.tap(find.text('Sık kullanılanlar'));
    expect(taps, 1);
  });

  testWidgets('hotkey Ctrl+Alt+Shift+1 runs slot 1 of the window in front', (t) async {
    SenseFavoritesHotkeys.macOverride = false;
    addTearDown(() => SenseFavoritesHotkeys.macOverride = null);
    final io = FakeFavIo(prefs: {SenseFavOs.win: prototypeWinPrefs()}, setAnswer: '');
    final m = await pumpList(t, io);
    var used = false;
    await t.pumpWidget(listApp(Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (SenseFavoritesHotkeys.handle(e)) used = true;
        return KeyEventResult.ignored;
      },
      child: const SizedBox(width: 10, height: 10),
    )));
    await t.pump();
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.digit1, physicalKey: PhysicalKeyboardKey.digit1);
    await t.sendKeyUpEvent(LogicalKeyboardKey.digit1, physicalKey: PhysicalKeyboardKey.digit1);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(used, isTrue);
    expect(io.sent.single.$2['id'], 'win.taskmgr');
    m.dispose();
  });

  test('the bridge implementation builds (generated bindings exist)', () {
    final io = SenseFavoritesFfiIo(UuidValue(const Uuid().v4()));
    expect(io.sessionId, isNotNull);
  });
}
