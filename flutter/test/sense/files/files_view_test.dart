// Sense Remote (#155): the Sense "Uzak dosyalar" view. Behaviour (selection, keyboard,
// send / receive, states, transfers) and goldens compared side by side with the
// prototype "Uzak dosyalar" section (SENSE-REMOTE_PROTOTIP.html#dosyalar). Sample
// folders are the prototype's. Images are made on CI (sense-golden.yml); until one
// exists its test is skipped.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/sense/screens/files/files_format.dart';
import 'package:flutter_hbb/sense/screens/files/files_queue.dart';
import 'package:flutter_hbb/sense/screens/files/files_view.dart';
import 'package:flutter_hbb/sense/screens/shared/aux_window/aux_window_frame.dart';
import 'package:flutter_hbb/sense/strings/files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

const String _dir = 'test/goldens/files';
String _file(String name) => '../../goldens/files/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_dir/$name.png').existsSync();

final _sessionId = UuidValue('00000000-0000-0000-0000-000000000002');

class _FakeFFI implements FFI {
  @override
  String id = 'test-peer';
  @override
  UuidValue get sessionId => _sessionId;
  @override
  late final FfiModel ffiModel = FfiModel(WeakReference(this));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Binding extends Fake implements RustdeskImpl {
  final cancelled = <int>[];

  @override
  Future<void> sessionCancelJob({required UuidValue sessionId, required int actId, dynamic hint}) async {
    cancelled.add(actId);
  }

  @override
  String translate({required String name, required String locale, dynamic hint}) => name;
}

/// Records sends instead of calling Rust.
class _Controller extends FileController {
  _Controller({required super.isLocal, required JobController jobs})
      : super(
          getSessionID: () => _sessionId,
          rootState: WeakReference(_FakeFFI()),
          jobController: jobs,
          fileFetcher: FileFetcher(() => _sessionId),
          getOtherSideDirectoryData: () => DirectoryData(FileDirectory(), DirectoryOptions()),
        );

  final sent = <List<String>>[];
  final opened = <String>[];

  @override
  Future<void> sendFiles(SelectedItems items, DirectoryData otherSideData) async {
    sent.add(items.items.map((e) => e.name).toList());
  }

  @override
  Future<bool> openDirectory(String path, {bool isBack = false}) async {
    opened.add(path);
    return true;
  }
}

int _t(int d, int h, int m) => DateTime(2026, 11, d, h, m).millisecondsSinceEpoch ~/ 1000;

Entry _e(String name, {int type = 4, int size = 0, int time = 0}) => Entry()
  ..name = name
  ..entryType = type
  ..size = size
  ..modifiedTime = time;

void _fill(FileController c, String path, List<Entry> entries) {
  c.options.value.isWindows = true;
  final fd = FileDirectory()
    ..path = path
    ..entries = entries;
  fd.format(true);
  c.directory.value = fd;
}

({_Controller local, _Controller remote, JobController jobs}) _models() {
  final jobs = JobController(() => _sessionId, () => null);
  final local = _Controller(isLocal: true, jobs: jobs);
  final remote = _Controller(isLocal: false, jobs: jobs);
  _fill(local, r'C:\Kullanıcılar\sense\İndirilenler', [
    _e('sergi_sov_v6.mp4', size: 742000000, time: _t(28, 0, 38)),
    _e('kiosk_ayar.json', size: 4200, time: _t(27, 21, 12)),
    _e('dokunmatik_surucu.zip', size: 38600000, time: _t(26, 15, 20)),
    _e('notlar.txt', size: 1100, time: _t(25, 10, 5)),
  ]);
  _fill(remote, r'C:\Sergi\Videolar', [
    _e('sergi_sov_v5.mp4', size: 698000000, time: _t(20, 18, 20)),
    _e('giris_dongu.mp4', size: 212000000, time: _t(12, 9, 41)),
    _e('kubbe_4k.mov', size: 1920000000, time: _t(8, 17, 5)),
  ]);
  return (local: local, remote: remote, jobs: jobs);
}

JobProgress _job(int id, String name, JobState state,
        {bool down = false, int total = 0, int done = 0, double speed = 0, String err = ''}) =>
    JobProgress()
      ..id = id
      ..type = JobType.transfer
      ..state = state
      ..fileName = name
      ..jobName = name
      ..to = down ? r'C:\Kullanıcılar\sense\İndirilenler' : r'C:\Sergi\Videolar'
      ..isRemoteToLocal = down
      ..totalSize = total
      ..finishedSize = done
      ..speed = speed
      ..err = err;

Widget _app(Widget child, {Size size = const Size(1180, 720)}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: true),
        child: Material(color: SenseColors.bg, child: child),
      ),
    );

Widget _view(({_Controller local, _Controller remote, JobController jobs}) m, {bool connected = true}) =>
    SenseFilesView(
      local: m.local,
      remote: m.remote,
      jobs: m.jobs,
      computer: 'Giriş Salonu PC-2',
      localOs: 'Windows',
      remoteOs: 'Windows',
      connected: connected,
    );

Widget _framed(Widget view) => SenseAuxWindowFrame(
      title: SenseFilesStrings.title,
      subject: 'Giriş Salonu PC-2',
      live: const SenseAuxLive('Doğrudan · ekran açılmadı', SenseLevel.ok),
      actions: SenseAuxWindowActions(onMinimize: () {}, onToggleMaximize: () {}, onClose: () {}),
      child: view,
    );

Future<void> _pumpView(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1180, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(w));
  await tester.pump();
}

void main() {
  setUp(() => platformFFI.setBindingForTesting(_Binding()));

  group('format (prototype spelling)', () {
    test('sizes', () {
      expect(senseFileSize(812), '812 B');
      expect(senseFileSize(4200), '4,2 KB');
      expect(senseFileSize(2300000), '2,3 MB');
      expect(senseFileSize(38600000), '39 MB');
      expect(senseFileSize(742000000), '742 MB');
      expect(senseFileSize(1920000000), '1,92 GB');
    });

    test('date and breadcrumb', () {
      expect(senseFileDate(DateTime(2026, 11, 28, 0, 38)), '28 Kas 2026 00:38');
      expect(senseFileDate(DateTime(2026, 2, 3, 9, 5)), '03 Şub 2026 09:05');
      expect(senseCrumbs(r'C:\Sergi\Videolar', windows: true),
          [('C:', r'C:\'), ('Sergi', r'C:\Sergi'), ('Videolar', r'C:\Sergi\Videolar')]);
      expect(senseCrumbs('/Users/sense', windows: false), [('Users', '/Users'), ('sense', '/Users/sense')]);
      expect(senseCrumbs('/', windows: true), isEmpty);
      expect(senseBaseName(r'C:\Sergi\kubbe_4k.mov'), 'kubbe_4k.mov');
    });
  });

  group('selection and transfer', () {
    testWidgets('click selects, Ctrl adds, Shift extends; footer counts', (tester) async {
      final m = _models();
      await _pumpView(tester, _view(m));
      await tester.tap(find.byKey(const Key('sense-files-local-row-sergi_sov_v6.mp4')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(m.local.selectedItems.items.map((e) => e.name), ['sergi_sov_v6.mp4']);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const Key('sense-files-local-row-notlar.txt')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 400));
      expect(m.local.selectedItems.items.map((e) => e.name), ['sergi_sov_v6.mp4', 'notlar.txt']);
      expect(find.textContaining('2 seçili · 742 MB', findRichText: true), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(const Key('sense-files-local-row-kiosk_ayar.json')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 400));
      // Anchor is notlar.txt (last Ctrl click): range notlar.txt … kiosk_ayar.json.
      expect(m.local.selectedItems.items.map((e) => e.name),
          ['kiosk_ayar.json', 'dokunmatik_surucu.zip', 'notlar.txt']);
    });

    testWidgets('selecting on one side drops the other side; Gönder / Al follow', (tester) async {
      final m = _models();
      await _pumpView(tester, _view(m));
      SenseTransferButton btn(String k) => tester.widget<SenseTransferButton>(find.byKey(Key(k)));
      expect(btn('sense-files-send').onPressed, isNull);
      expect(btn('sense-files-receive').onPressed, isNull);

      await tester.tap(find.byKey(const Key('sense-files-local-row-kiosk_ayar.json')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(btn('sense-files-send').onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('sense-files-remote-row-kubbe_4k.mov')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(m.local.selectedItems.items, isEmpty);
      expect(btn('sense-files-send').onPressed, isNull);
      expect(btn('sense-files-receive').onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('sense-files-receive')));
      await tester.pump();
      expect(m.remote.sent, [
        ['kubbe_4k.mov']
      ]);
      expect(m.remote.selectedItems.items, isEmpty);
    });

    testWidgets('not connected: remote panel waits, buttons stay off', (tester) async {
      final m = _models();
      await _pumpView(tester, _view(m, connected: false));
      expect(find.byKey(const Key('sense-files-remote-loading')), findsOneWidget);
      expect(find.text(SenseAuxStrings.connecting), findsOneWidget);
    });

    testWidgets('double click opens a folder; keyboard moves and Enter opens', (tester) async {
      final m = _models();
      _fill(m.remote, r'C:\Sergi', [
        _e('Ayarlar', type: 1, time: _t(22, 14, 11)),
        _e('Kayıtlar', type: 1, time: _t(28, 0, 2)),
        _e('Videolar', type: 1, time: _t(27, 19, 30)),
      ]);
      await _pumpView(tester, _view(m));
      final row = find.byKey(const Key('sense-files-remote-row-Kayıtlar'));
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(row);
      await tester.pump(const Duration(milliseconds: 400));
      expect(m.remote.opened, [r'C:\Sergi\Kayıtlar']);

      await tester.tap(find.byKey(const Key('sense-files-remote-row-Ayarlar')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(m.remote.selectedItems.items.single.name, 'Kayıtlar');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(m.remote.opened.last, r'C:\Sergi\Kayıtlar');
    });

    testWidgets('a column header sorts', (tester) async {
      final m = _models();
      await _pumpView(tester, _view(m));
      await tester.tap(find.byKey(const Key('sense-files-remote-sort-size')));
      await tester.pump();
      expect(m.remote.sortBy.value, SortBy.size);
      expect(m.remote.directory.value.entries.first.name, 'kubbe_4k.mov');
    });

    testWidgets('the ⋯ menu offers the kept stock actions', (tester) async {
      final m = _models();
      await _pumpView(tester, _view(m));
      await tester.tap(find.byKey(const Key('sense-files-local-more')));
      await tester.pump();
      for (final t in [
        SenseFilesStrings.newFolder,
        SenseFilesStrings.rename,
        SenseFilesStrings.delete,
        SenseFilesStrings.showHidden,
        SenseFilesStrings.selectAll,
        SenseFilesStrings.typePath,
      ]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      await tester.tap(find.text(SenseFilesStrings.selectAll));
      await tester.pump();
      expect(m.local.selectedItems.items.length, 4);
    });
  });

  group('states', () {
    testWidgets('U168a error states are Turkish and offer a way out', (tester) async {
      final m = _models();
      m.remote.readErrorPath = r'C:\Windows\System32\config';
      m.remote.readError.value = SenseDirError.denied;
      await _pumpView(tester, _view(m));
      expect(find.byKey(const Key('sense-files-remote-error')), findsOneWidget);
      expect(find.text(SenseFilesStrings.errorTitle), findsOneWidget);
      expect(find.textContaining('Erişim izni yok'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sense-files-remote-error-retry')));
      await tester.pump();
      expect(m.remote.opened.last, r'C:\Windows\System32\config');

      await tester.tap(find.byKey(const Key('sense-files-remote-error-up')));
      await tester.pump();
      expect(m.remote.readError.value, isNull);
      expect(find.byKey(const Key('sense-files-remote-row-kubbe_4k.mov')), findsOneWidget);
    });

    testWidgets('empty folder and empty transfers', (tester) async {
      final m = _models();
      _fill(m.remote, 'E:\\', []);
      await _pumpView(tester, _view(m));
      expect(find.byKey(const Key('sense-files-remote-empty')), findsOneWidget);
      expect(find.text(SenseFilesStrings.emptyRemote), findsOneWidget);
      expect(find.byKey(const Key('sense-files-queue-empty')), findsOneWidget);
    });
  });

  group('transfers', () {
    test('rows say what the prototype says', () {
      final run = senseJobView(_job(1, 'a', JobState.inProgress, total: 100000000, done: 42000000, speed: 11800000));
      expect(run.status, ('%42', '12 MB/sn · 5 sn kaldı'));
      expect(run.actions, [SenseJobAction.cancel]);
      expect(senseJobView(_job(2, 'b', JobState.done, total: 4200)).status, ('Tamamlandı', '4,2 KB'));
      expect(senseJobView(_job(3, 'c', JobState.done, err: 'cancel')).status.$1, 'İptal edildi');
      final err = senseJobView(_job(4, 'd', JobState.error, total: 100, done: 35));
      expect(err.status, ('Aktarım durdu', '%35'));
      expect(err.actions, [SenseJobAction.remove]);
      expect(senseJobView(_job(5, 'e', JobState.paused)).actions, [SenseJobAction.resume, SenseJobAction.cancel]);
    });

    testWidgets('cancel drops the row and cancels the job; clear removes done rows', (tester) async {
      final binding = _Binding();
      platformFFI.setBindingForTesting(binding);
      final m = _models();
      m.jobs.jobTable.addAll([
        _job(11, 'giris_dongu.mp4', JobState.inProgress, down: true, total: 212000000, done: 90000000, speed: 14200000),
        _job(12, 'kiosk_ayar.json', JobState.done, total: 4200),
      ]);
      await _pumpView(tester, _view(m));
      expect(find.textContaining('1 sürüyor · 1 tamamlandı'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sense-files-job-cancel-11')));
      await tester.pump();
      expect(binding.cancelled, [11]);
      expect(m.jobs.jobTable.map((j) => j.id), [12]);
      await tester.tap(find.byKey(const Key('sense-files-clear-done')));
      await tester.pump();
      expect(m.jobs.jobTable, isEmpty);
    });
  });

  group('goldens', () {
    Future<void> shoot(WidgetTester tester, String name, Widget w) async {
      await _pumpView(tester, RepaintBoundary(key: const Key('golden'), child: w));
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file(name)));
    }

    const selected = 'files_selected_transfers';
    testWidgets('golden: selection and transfers (#dosyalar)', (tester) async {
      final m = _models();
      m.local.selectedItems.items.assignAll([
        m.local.directory.value.entries[0],
        m.local.directory.value.entries[3],
      ]);
      m.jobs.jobTable.addAll([
        _job(21, 'dokunmatik_surucu.zip', JobState.inProgress, total: 38600000, done: 16200000, speed: 11800000),
        _job(22, 'sergi_sov_v5.mp4', JobState.done, down: true, total: 698000000),
        _job(23, 'giris_dongu.mp4', JobState.error, down: true, total: 212000000, done: 74000000),
      ]);
      await shoot(tester, selected, _framed(_view(m)));
    }, skip: _skip(selected), tags: const ['golden']);

    const empty = 'files_empty';
    testWidgets('golden: empty folder, no transfers', (tester) async {
      final m = _models();
      _fill(m.remote, 'E:\\', []);
      await shoot(tester, empty, _framed(_view(m)));
    }, skip: _skip(empty), tags: const ['golden']);

    const error = 'files_error';
    testWidgets('golden: folder could not be opened (U168a)', (tester) async {
      final m = _models();
      m.remote.readErrorPath = r'C:\Windows\System32\config';
      m.remote.readError.value = SenseDirError.denied;
      await shoot(tester, error, _framed(_view(m)));
    }, skip: _skip(error), tags: const ['golden']);

    const narrow = 'files_1280';
    testWidgets('golden: smallest window 1280 × 720 (T9)', (tester) async {
      final m = _models();
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(RepaintBoundary(key: const Key('golden'), child: _framed(_view(m))),
          size: const Size(1280, 720)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file(narrow)));
    }, skip: _skip(narrow), tags: const ['golden']);
  });
}
