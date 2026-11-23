// Sense Remote (C3): chat state — messages, unread, files, call, S12 wipe.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_controller.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_entry.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/data/files.dart';
import 'package:flutter_hbb/sense/strings/chat.dart';

import 'support.dart';

void main() {
  group('messages', () {
    test('send trims, ignores empty, goes out once', () {
      final out = <String>[];
      final c = makeController(sentTexts: out);
      expect(c.send('   '), isFalse);
      expect(c.send('  Merhaba  '), isTrue);
      expect(out, ['Merhaba']);
      final e = c.entries.single as SenseChatText;
      expect(e.mine, isTrue);
      expect(e.text, 'Merhaba');
      expect(c.messageCount, 1);
    });

    test('received text counts as unread only while the chat is closed', () {
      final c = makeController();
      c.receiveText('bir');
      c.receiveText('iki');
      expect(c.unread, 2);
      c.open();
      expect(c.unread, 0);
      c.receiveText('üç');
      expect(c.unread, 0);
      c.minimize();
      expect(c.isOpen, isFalse);
      c.receiveText('dört');
      expect(c.unread, 1);
    });

    test('incoming stream carries the text for the notification card', () async {
      final c = makeController();
      final got = <SenseChatIncoming>[];
      final sub = c.incoming.listen(got.add);
      c.receiveText('Ekran 2 kaydı');
      c.applyJobs([job('a', 'log.zip', SenseFileDir.incoming, total: 10)]);
      await Future<void>.delayed(Duration.zero);
      expect(got.map((e) => e.text), ['Ekran 2 kaydı', 'log.zip']);
      expect(got.last.isFile, isTrue);
      await sub.cancel();
    });
  });

  group('files', () {
    test('sendFiles makes an outgoing bubble per id', () async {
      final f = FakeFiles();
      final c = makeController(files: f);
      await c.sendFiles([r'C:\a\rapor.pdf', '/b/video.mp4']);
      expect(f.sent.single, [r'C:\a\rapor.pdf', '/b/video.mp4']);
      final rows = c.entries.whereType<SenseChatFileEntry>().toList();
      expect(rows, hasLength(2));
      expect(rows.every((r) => r.mine), isTrue);
      expect(c.job('j1')!.name, 'rapor.pdf');
      expect(c.job('j2')!.kind, SenseFileKind.video);
      expect(c.transferring, isTrue);
      expect(c.fileCount, 2);
    });

    test('jobs from the bridge update bubbles and add received files', () async {
      final f = FakeFiles();
      final c = makeController(files: f);
      f.list = [job('x', 'a.png', SenseFileDir.incoming, done: 5, total: 10)];
      await c.refreshFiles();
      expect(c.entries.single.mine, isFalse);
      expect(c.unread, 1);
      f.list = [
        job('x', 'a.png', SenseFileDir.incoming,
            done: 10, total: 10, state: SenseFileState.ok, path: r'C:\Users\u\Downloads\a.png')
      ];
      await c.refreshFiles();
      expect(c.entries, hasLength(1), reason: 'same job, same bubble');
      expect(c.job('x')!.finished, isTrue);
      expect(c.transferring, isFalse);
    });

    test('bridge JSON is parsed; broken input is an empty list', () {
      final jobs = senseParseFileJobs(
          '[{"id":"1","name":"v.mp4","kind":"video","dir":"in","done":49,"total":100,"state":"run","path":""},'
          '{"name":"no id"},{"id":"2","name":"b.zip","dir":"out","done":"7","total":7,"state":"ok"}]');
      expect(jobs, hasLength(2));
      expect(jobs.first.dir, SenseFileDir.incoming);
      expect(jobs.first.progress, closeTo(0.49, 1e-9));
      expect(jobs.last.state, SenseFileState.ok);
      expect(jobs.last.done, 7);
      expect(senseParseFileJobs('nope'), isEmpty);
      expect(senseParseFileJobs('{}'), isEmpty);
      expect(senseParseJobIds('["a",1]'), ['a', '1']);
      expect(senseParentFolder(r'C:\Users\u\Downloads\a.png'), r'C:\Users\u\Downloads');
    });

    test('state lines (O12)', () {
      expect(
          senseFileLine(job('v', 'takilma_ekran2.mp4', SenseFileDir.incoming,
              done: 90500000, total: 184000000)),
          'Video · İndiriliyor · %49 · 90,5 MB / 184,0 MB');
      expect(
          senseFileLine(job('p', 'k.png', SenseFileDir.out,
              done: 2400000, total: 2400000, state: SenseFileState.ok)),
          'Resim · 2,4 MB · ${SenseChatStrings.sentSaved}');
      expect(
          senseFileLine(job('z', 's.zip', SenseFileDir.incoming,
              done: 1, total: 1, state: SenseFileState.ok, path: '/home/u/Downloads/s.zip')),
          'Belge · 1 KB · İndirilenler’e kaydedildi');
      expect(senseSavedText(r'D:\Gelen\s.zip'), SenseChatStrings.savedIncoming);
      expect(
          senseFileLine(job('r', 'b.mov', SenseFileDir.out,
              done: 1000000000, total: 2000000000, state: SenseFileState.resume)),
          'Video · Kaldığı yerden sürüyor · %50 · 1,0 GB / 2,0 GB');
      expect(senseFileSize(300), '1 KB');
      expect(senseCallClock(const Duration(seconds: 95)), '01:35');
    });
  });

  group('call (O11, voice only)', () {
    test('Ara asks once; bitir closes; events move the phase', () async {
      final call = FakeCall();
      var t = at(17, 0);
      final c = makeController(call: call, now: () => t);
      await c.startCall();
      await c.startCall();
      expect(call.starts, 1);
      expect(c.phase, SenseCallPhase.calling);
      c.setPhase(SenseCallPhase.active);
      t = t.add(const Duration(minutes: 1, seconds: 35));
      expect(c.callElapsed, const Duration(minutes: 1, seconds: 35));
      await c.endCall();
      expect(call.ends, 1);
      expect(c.phase, SenseCallPhase.idle);
      expect(c.callStart, isNull);
    });
  });

  group('S12: the chat is gone when the connection ends (#56)', () {
    test('clear drops messages and files; only the counts remain', () async {
      final c = makeController();
      c.send('a');
      c.receiveText('b');
      await c.sendFiles(['/x/y.png']);
      c.setPhase(SenseCallPhase.active);
      c.clear();
      expect(c.entries, isEmpty);
      expect(c.job('j1'), isNull);
      expect(c.unread, 0);
      expect(c.phase, SenseCallPhase.idle);
      expect(c.messageCount, 2);
      expect(c.fileCount, 1);
    });

    test('dispose empties the memory', () {
      final c = makeController();
      c.send('gizli');
      c.dispose();
      expect(c.entries, isEmpty);
    });

    test('the chat code has no way to write to disk', () {
      // Only the bridge (Rust) touches files; the chat keeps text in memory.
      final banned = RegExp(r"dart:io|SharedPreferences|mainSetLocalOption|mainSetOption|"
          r"\bFile\(|writeAsString|writeAsBytes|path_provider");
      final dirs = ['lib/sense/screens/shared/chat', 'lib/sense/screens/session/chat_icon'];
      final hits = <String>[];
      for (final d in dirs) {
        for (final f in Directory(d).listSync(recursive: true).whereType<File>()) {
          if (!f.path.endsWith('.dart')) continue;
          final lines = f.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].trimLeft().startsWith('//')) continue;
            if (banned.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      expect(hits, isEmpty, reason: hits.join('\n'));
    });
  });
}
