// Sense Remote: the four lists against TK9 §3 (YH O3–O7 acceptance: every RustDesk session
// option of Windows / Mac is in a list; conditional items follow the rules).
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/data/grants.dart';
import 'package:flutter_hbb/sense/screens/session/data/session_state.dart';
import 'package:flutter_hbb/sense/screens/session/lists/backend.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_model.dart';
import 'package:flutter_hbb/sense/screens/session/lists/list_specs.dart';
import 'package:flutter_hbb/sense/screens/session/lists/rules.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

import 'fake_backend.dart';

Map<String, SenseListEntry> entriesOf(FakeBackend b) => {
      for (final m in SenseBarMenu.values)
        for (final e in senseBuildList(m, b).allEntries) e.id: e,
    };

/// TK9 §3 row → the list entry that stands for it.
const kCorrespondence = <String, String>{
  'O3 ekranlar / Tümü (openMonitorInTheSameTab, kAllDisplayValue)': 'screens.tiles',
  'Ayrı pencere (sessionSetDisplaysAsIndividualWindows)': 'screens.individual',
  'Uzak çözünürlük (sessionChangeResolution)': 'screens.resolution',
  'Tüm ekranlarım (sessionSetUseAllMyDisplaysForTheRemoteSession)': 'screens.allMine',
  'Sanal ekran (sessionToggleVirtualDisplay) ekle': 'screens.virtual.add',
  'Sanal ekran (sessionToggleVirtualDisplay) çıkar': 'screens.virtual.removeAll',
  'O4 boyut (sessionSetViewStyle)': 'display.size',
  'Özel ölçek (_CustomScaleMenuControls)': 'display.customScale',
  'Kalite (sessionSetImageQuality)': 'display.quality',
  'Özel kalite (sessionSetCustomImageQuality)': 'display.qualityPct',
  'Özel kare hızı (sessionSetCustomFps)': 'display.fps',
  'Yenile (sessionRefreshVideo)': 'display.refresh',
  'Kaydırma (sessionSetScrollStyle)': 'display.scroll',
  'Görünümü sıfırla (cursorModel.reset)': 'display.resetView',
  'Pencereyi uzak boyuta (ScreenAdjustor.adjustWindow)': 'display.adjustWindow',
  '4:4:4 (i444)': 'display.trueColor',
  'Kodek (codec-preference)': 'display.codec',
  'Ses kapat (disable-audio)': 'display.mute',
  'O5 klavye modu (sessionSetKeyboardMode)': 'keyboard.mode',
  'Eski klavye modu (legacy)': 'keyboard.legacy',
  'Yalnız izle (view-only)': 'keyboard.viewOnly',
  'İmleç: show-remote-cursor': 'mouse.showRemote',
  'İmleç: show-my-cursor': 'mouse.showMine',
  'İmleç: follow-remote-cursor': 'mouse.followCursor',
  'İmleç: follow-remote-window': 'mouse.followWindow',
  'İmleç: zoom-cursor': 'mouse.zoom',
  'İmleç: setRelativeMouseMode': 'mouse.relative',
  'İmleç: sessionSetReverseMouseWheel': 'mouse.reverseWheel',
  'İmleç: swap-left-right-mouse': 'mouse.swapButtons',
  'İmleç: trackpad-speed (pencereden kategoriye)': 'mouse.trackpad',
  'Kısayollar (ShortcutModel)': 'shortcut.toggle_fullscreen',
  'O6 Ctrl+Alt+Del (sessionCtrlAltDel)': 'actions.ctrlAltDel',
  'Ekran görüntüsü (sessionTakeScreenshot)': 'actions.screenshot',
  'Kilitle (sessionLockScreen)': 'actions.lock',
  'Yeniden başlat (sessionRestartRemoteDevice)': 'actions.restart',
  'Giriş kilidi (block-input)': 'actions.blockInput',
  'Kayıt (RecordingModel.toggle)': 'actions.record',
  'Pano: sessionInputString': 'actions.typeClipboard',
  'Pano: enable-file-copy-paste': 'actions.fileCopyPaste',
  'Pano: disable-clipboard': 'actions.disableClipboard',
  'Uzak dosyalar (connectWithToken isFileTransfer)': 'actions.remoteFiles',
  'Yönetici yetkisi (showRequestElevationDialog)': 'actions.elevation',
  'Oturum sonu kilit (lock-after-session-end)': 'actions.lockAfterEnd',
  'Not (showAuditDialog)': 'actions.note',
  'Terminal (connectWithToken)': 'actions.terminal',
  'TCP (connectWithToken)': 'actions.tunnel',
  'Parmak izi (onCopyFingerprint)': 'actions.fingerprint',
};

void main() {
  test('every TK9 §3 item is in a list (Windows peer, three displays, scrolling view)', () {
    final b = FakeBackend()..viewStyle = SenseRd.viewOriginal;
    // Follow remote cursor/window need a peer from 1.2.4 with more than one display;
    // zoom cursor needs a fitted view: check those on a second, adaptive backend.
    final fitted = FakeBackend();
    final all = {...entriesOf(b), ...entriesOf(fitted)};
    final missing = [
      for (final e in kCorrespondence.entries)
        if (!all.containsKey(e.value)) '${e.key} → ${e.value}',
    ];
    expect(missing, isEmpty, reason: missing.join('\n'));
  });

  test('Mac items: Ctrl ↔ Cmd and the local keyboard type (Windows here, Mac there)', () {
    final b = FakeBackend(facts: const SensePeerFacts(os: SensePeerOs.mac, sasEnabled: false));
    final e = entriesOf(b);
    expect(e, contains('keyboard.swapCtrlCmd'));
    expect(e, contains('keyboard.localLayout'));
  });

  test('Mac peer: no Ctrl+Alt+Del, no input lock, no virtual display', () {
    final b = FakeBackend(facts: const SensePeerFacts(os: SensePeerOs.mac, sasEnabled: false, rustDeskIdd: true));
    final e = entriesOf(b);
    expect(e, isNot(contains('actions.ctrlAltDel')));
    expect(e, isNot(contains('actions.blockInput')));
    expect(e, isNot(contains('screens.virtual.add')));
  });

  test('one display: no "Tümü" tile (#5) and no separate windows', () {
    final b = FakeBackend(facts: const SensePeerFacts(displaysCount: 1))
      ..displays = const [SenseDisplayRef(0, primary: true)];
    final spec = senseScreensList(b);
    final tiles = spec.frequent.whereType<SenseTilesEntry>().single;
    expect(tiles.tiles.map((t) => t.value), isNot(contains(SenseRd.allDisplays)));
    expect(spec.allEntries.map((e) => e.id), isNot(contains('screens.individual')));
  });

  test('several displays: "Tümü birlikte" is the last tile', () {
    final spec = senseScreensList(FakeBackend());
    final tiles = spec.frequent.whereType<SenseTilesEntry>().single.tiles;
    expect(tiles.map((t) => t.title), ['1', '2', '3', 'Tümü']);
    expect(tiles.first.sub, 'ana');
    expect(tiles.last.sub, 'birlikte');
    expect(spec.chip, 'Ekran 1');
  });

  test('no "Taraf değiştir" anywhere (decision 2)', () {
    final e = entriesOf(FakeBackend());
    expect(e.values.where((x) => x.rustdesk.contains('Switch Sides') || x.label.contains('Taraf')), isEmpty);
  });

  test('no Android buttons, Wayland items or OS password', () {
    final e = entriesOf(FakeBackend());
    for (final x in e.values) {
      expect(x.rustdesk, isNot(contains('OS Password')));
      expect(x.rustdesk, isNot(contains('wayland')));
      expect(x.rustdesk, isNot(contains('Mobile')));
    }
  });

  test('screenshot: waits during the 30 s pause, not on "Tümü"', () {
    final busy = FakeBackend()..screenshotBusy = true;
    final e1 = entriesOf(busy)['actions.screenshot'] as SenseActionEntry;
    expect(e1.onTap, isNull);
    final all = FakeBackend(facts: const SensePeerFacts(displaysCount: 3, currentDisplay: SenseRd.allDisplays));
    final e2 = entriesOf(all)['actions.screenshot'] as SenseActionEntry;
    expect(e2.onTap, isNull);
    expect(e2.hint, isNotNull);
  });

  test('restart asks in place (T7), with its own question', () {
    final e = entriesOf(FakeBackend())['actions.restart'] as SenseActionEntry;
    expect(e.confirmQuestion, 'Uzak bilgisayar yeniden başlatılsın mı?');
    expect(e.confirmLabel, 'Yeniden başlat');
  });

  test('scroll choices only for 1:1 and custom scale', () {
    expect(entriesOf(FakeBackend()), isNot(contains('display.scroll')));
    expect(entriesOf(FakeBackend()..viewStyle = SenseRd.viewCustom), contains('display.scroll'));
  });

  test('custom quality sliders work only while custom quality is on', () {
    final off = entriesOf(FakeBackend());
    expect((off['display.qualityPct'] as SenseSliderEntry).onChanged, isNull);
    final on = entriesOf(FakeBackend()..imageQuality = SenseRd.qualityCustom);
    expect((on['display.qualityPct'] as SenseSliderEntry).onChanged, isNotNull);
    expect((on['display.fps'] as SenseSliderEntry).onChanged, isNotNull);
  });

  test('status colours: recording red frame, input lock orange', () {
    final b = FakeBackend()
      ..recordingOn = true
      ..inputLocked = true;
    final spec = senseActionsList(b);
    expect(spec.frequentLevel, SenseLevel.hot);
    expect(spec.chip, 'Kayıt');
    expect(spec.chipLevel, SenseLevel.hot);
    final locked = FakeBackend()..inputLocked = true;
    expect(senseActionsList(locked).frequentLevel, SenseLevel.warn);
  });

  test('view only: orange chip and orange frame on the keyboard list', () {
    final spec = senseKeyboardList(FakeBackend()..viewOnly = true);
    expect(spec.chip, 'Yalnız izle');
    expect(spec.chipLevel, SenseLevel.warn);
    expect(spec.frequentLevel, SenseLevel.warn);
  });

  test('closed categories show their value (O7)', () {
    final d = senseDisplayList(FakeBackend());
    final codec = d.sections.firstWhere((s) => s.id == 'codec');
    expect(codec.summary, 'Otomatik');
    final k = senseKeyboardList(FakeBackend());
    expect(k.sections.firstWhere((s) => s.id == 'shortcuts').summary, '6 kısayol · salt okunur');
  });

  test('shortcuts: six read-only rows, all bound', () {
    final k = senseKeyboardList(FakeBackend());
    final rows = k.sections.firstWhere((s) => s.id == 'shortcuts').entries.cast<SenseInfoEntry>();
    expect(rows, hasLength(6));
    expect(rows.first.detail, 'Ctrl+Alt+Shift+Enter');
    expect(rows.map((r) => r.detail), isNot(contains('atanmadı')));
    expect(rows.firstWhere((r) => r.id == 'shortcut.close_tab').detail, 'Ctrl+Alt+Shift+Q');
    final unbound = FakeBackend()..shortcuts = const [SenseShortcutRow('close_tab', 'Bağlantıyı bitir', null)];
    final r = senseKeyboardList(unbound).sections.firstWhere((s) => s.id == 'shortcuts').entries.single as SenseInfoEntry;
    expect(r.detail, 'atanmadı');
  });

  group('person rights lock, never hide (plan §2.1)', () {
    test('no rights: locked entries stay in the list', () {
      final b = FakeBackend(grants: const SenseSessionGrants(SenseGrantsState.ok, {SenseGrant.connect}));
      final e = entriesOf(b);
      for (final id in [
        'actions.ctrlAltDel',
        'actions.lock',
        'actions.restart',
        'actions.blockInput',
        'actions.record',
        'actions.terminal',
        'actions.tunnel',
        'actions.remoteFiles',
        'actions.fileCopyPaste',
        'keyboard.mode',
      ]) {
        expect(e[id]?.noRights, isTrue, reason: id);
      }
    });

    test('with the rights: unlocked', () {
      final b = FakeBackend(
          grants: const SenseSessionGrants(SenseGrantsState.ok, {
        SenseGrant.control,
        SenseGrant.restartRemote,
        SenseGrant.recordSession,
        SenseGrant.terminalTunnel,
        SenseGrant.fileTransfer,
      }));
      expect(entriesOf(b).values.where((x) => x.noRights), isEmpty);
    });
  });

  test('entries call the RustDesk side', () {
    final b = FakeBackend();
    final e = entriesOf(b);
    (e['actions.ctrlAltDel'] as SenseActionEntry).onTap!();
    (e['actions.lock'] as SenseActionEntry).onTap!();
    (e['actions.restart'] as SenseActionEntry).onTap!();
    (e['display.refresh'] as SenseActionEntry).onTap!();
    (e['display.resetView'] as SenseActionEntry).onTap!();
    (e['actions.fingerprint'] as SenseActionEntry).onTap!();
    (e['screens.tiles'] as SenseTilesEntry).onPick!(2);
    (e['screens.resolution'] as SenseChoiceEntry).onChanged!('fit');
    (e['actions.record'] as SenseToggleEntry).onChanged!(true);
    expect(b.calls, containsAllInOrder([
      'ctrlAltDel',
      'lockScreen',
      'restart',
      'refreshVideo',
      'resetView',
      'fingerprint',
      'openDisplay:2',
      'resolution:1920x1080',
      'recording',
    ]));
    (e['display.codec'] as SenseChoiceEntry).onChanged!('av1');
    expect(b.codec, 'av1');
    (e['mouse.trackpad'] as SenseSliderEntry).onChanged!(250);
    expect(b.trackpadSpeed, 250);
  });
}
