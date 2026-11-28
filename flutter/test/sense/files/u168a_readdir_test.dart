// Sense Remote (U168a, #168): "Failed to openDirectory: FormatException: Unexpected end
// of input" and "Failed to read dir, timeout" in the Controller log of session
// c1795815969-0 (Slayer → Sedat-4090, 00:50, while a 76 MB chat file was sent).
//
// Root cause: a screen session also owns a FileModel that the file window never opened
// (empty paths). The chat file is a Rust-side job; its `job_done` is unknown to the
// Dart job table, so `jobDone` asked for `refreshAll()`, which read "" locally (Rust
// `read_dir("")` fails → returns "" → `jsonDecode("")` → FormatException) and "" remotely
// (no answer → 30 s timeout). The tests below replay that event order.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

final _sessionId = UuidValue('00000000-0000-0000-0000-000000000000');

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

/// Counts directory reads; the local read answers like Rust does for a folder it
/// cannot read (an empty string).
class _ReadBinding extends Fake implements RustdeskImpl {
  int localReads = 0;
  int remoteReads = 0;
  String localAnswer = '';

  @override
  Future<String> sessionReadLocalDirSync(
      {required UuidValue sessionId, required String path, required bool showHidden, dynamic hint}) async {
    localReads++;
    return localAnswer;
  }

  @override
  Future<void> sessionReadRemoteDir(
      {required UuidValue sessionId, required String path, required bool includeHidden, dynamic hint}) async {
    remoteReads++;
  }

  @override
  String translate({required String name, required String locale, dynamic hint}) => name;

  @override
  String mainGetCommonSync({required String key, dynamic hint}) => '1';
}

String _dirJson(String path, List<String> names) => jsonEncode({
      'id': 0,
      'path': path,
      'entries': [
        for (final n in names) {'entry_type': 4, 'modified_time': 0, 'name': n, 'size': 1}
      ],
    });

FileController _controller({required bool isLocal, FileFetcher? fetcher}) => FileController(
      isLocal: isLocal,
      getSessionID: () => _sessionId,
      rootState: WeakReference(_FakeFFI()),
      jobController: JobController(() => _sessionId, () => null),
      fileFetcher: fetcher ?? FileFetcher(() => _sessionId),
      getOtherSideDirectoryData: () => DirectoryData(FileDirectory(), DirectoryOptions()),
    );

void main() {
  late List<String> log;
  late DebugPrintCallback savedPrint;
  late List<(bool, int, String?)> events;

  setUp(() {
    log = [];
    events = [];
    savedPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => log.add(m ?? '');
    senseReadDirSink = (ok, ms, err) => events.add((ok, ms, err));
  });

  tearDown(() {
    debugPrint = savedPrint;
    senseReadDirSink = null;
  });

  test('the error strings of the real log map to the Sense states', () {
    expect(senseDirErrorOf(const FormatException('Unexpected end of input')), SenseDirError.unreadable);
    expect(senseDirErrorOf('Failed to read dir, timeout'), SenseDirError.timeout);
    expect(senseDirErrorOf('Access is denied. (os error 5)'), SenseDirError.denied);
    expect(senseDirErrorOf(const SenseDirReadException()), SenseDirError.unreadable);
    expect(senseDirErrorOf(StateError('something else')), SenseDirError.other);
  });

  test('screen session: a chat file job_done no longer reads "" on both sides', () async {
    final binding = _ReadBinding();
    platformFFI.setBindingForTesting(binding);
    final model = FileModel(WeakReference(_FakeFFI()));

    // The event the screen session got when the chat file finished (job unknown here).
    final refresh = await model.jobController.jobDone({'id': '7', 'file_num': '0'});
    expect(refresh, isTrue, reason: 'stock behaviour of an unknown job stays');
    if (refresh) await model.refreshAll();

    expect(binding.localReads, 0);
    expect(binding.remoteReads, 0);
    expect(log.where((l) => l.contains('Failed to openDirectory')), isEmpty);
  });

  test('an unreadable local folder is a Turkish error state, not a FormatException', () async {
    final binding = _ReadBinding()..localAnswer = '';
    platformFFI.setBindingForTesting(binding);
    final c = _controller(isLocal: true);

    expect(await c.openDirectory(r'C:\Silinmiş klasör'), isFalse);
    expect(c.readError.value, SenseDirError.unreadable);
    expect(c.readErrorPath, r'C:\Silinmiş klasör');
    expect(c.loading.value, isFalse);
    expect(log.join('\n'), isNot(contains('FormatException')));
    expect(events, isEmpty, reason: 'files/readdir is for remote reads only');

    // The next good read clears the error.
    binding.localAnswer = _dirJson(r'C:\Users', ['a.txt']);
    expect(await c.openDirectory(r'C:\Users'), isTrue);
    expect(c.readError.value, isNull);
    expect(c.directory.value.entries.single.name, 'a.txt');
  });

  testWidgets('a remote timeout is tried once more and then opens', (tester) async {
    var calls = 0;
    late final FileFetcher fetcher;
    fetcher = FileFetcher(() => _sessionId, readRemoteDirectory: (_, path, __) {
      calls++;
      // First read: no answer (the peer was busy). Second read: answered.
      if (calls == 2) {
        scheduleMicrotask(() => fetcher.tryCompleteTask(_dirJson(path, ['video.mp4']), 'false'));
      }
      return Future<void>.value();
    });
    final c = _controller(isLocal: false, fetcher: fetcher);

    final open = c.openDirectory(r'C:\Sergi');
    await tester.pump(const Duration(seconds: 31));
    expect(await open, isTrue);
    expect(calls, 2);
    expect(c.readError.value, isNull);
    expect(c.directory.value.entries.single.name, 'video.mp4');
    expect(events.length, 1);
    expect(events.single.$1, isTrue);
    expect(events.single.$3, isNull);
    debugPrint = savedPrint; // testWidgets checks debug variables before tearDown
  });

  testWidgets('two remote timeouts end in the timeout state and one files/readdir event', (tester) async {
    final fetcher = FileFetcher(() => _sessionId, readRemoteDirectory: (_, __, ___) => Future<void>.value());
    final c = _controller(isLocal: false, fetcher: fetcher);

    final open = c.openDirectory(r'C:\Sergi');
    await tester.pump(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    expect(await open, isFalse);
    expect(c.readError.value, SenseDirError.timeout);
    expect(events.single.$1, isFalse);
    expect(events.single.$3, 'timeout');
    expect(events.single.$2, greaterThanOrEqualTo(0));
    debugPrint = savedPrint; // testWidgets checks debug variables before tearDown
  });
}
