// Sense Remote (C3): helpers for the chat tests. Goldens live in
// test/goldens/chat/ and are made on CI (sense-golden.yml); until an image
// exists its test is skipped, not failed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_controller.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/chat_entry.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/data/call.dart';
import 'package:flutter_hbb/sense/screens/shared/chat/data/files.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

const String kGoldenDir = 'test/goldens/chat';

String goldenFile(String name) => '../../goldens/chat/$name.png';

bool goldenSkip(String name) =>
    !autoUpdateGoldenFiles && !File('$kGoldenDir/$name.png').existsSync();

void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Black app frame; [child] fills it.
Widget app(Widget child, {bool still = false}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: still),
        child: ColoredBox(
          color: SenseColors.bg,
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: SenseFont.family, color: SenseColors.text),
            child: child,
          ),
        ),
      ),
    ),
  );
}

class FakeFiles implements SenseChatFiles {
  final List<List<String>> sent = [];
  final List<String> revealed = [];
  List<SenseFileJob> list = [];
  int nextId = 1;

  @override
  Future<List<String>> send(List<String> paths) async {
    sent.add(paths);
    return [for (final _ in paths) 'j${nextId++}'];
  }

  @override
  Future<List<SenseFileJob>> jobs() async => list;

  @override
  Future<void> reveal(String path) async => revealed.add(path);
}

class FakeCall implements SenseChatCall {
  FakeCall({this.canMute = false, this.levelValue});

  final bool canMute;
  final double? levelValue;
  int starts = 0;
  int ends = 0;
  final List<String> inputs = [];
  final List<String> outputs = [];
  final List<bool> mutes = [];
  SenseAudioDevices devs = const SenseAudioDevices(
    inputs: ['Kulaklık mikrofonu', 'Kamera mikrofonu', 'Dahili mikrofon'],
    input: 'Kulaklık mikrofonu',
    outputs: ['Kulaklık', 'Hoparlör', 'Monitör hoparlörü'],
    output: 'Kulaklık',
  );

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> end() async => ends++;

  @override
  Future<SenseAudioDevices> devices() async => devs;

  @override
  Future<void> setInput(String device) async => inputs.add(device);

  @override
  Future<void> setOutput(String device) async => outputs.add(device);

  @override
  Future<bool> setMuted(bool muted) async {
    mutes.add(muted);
    return canMute;
  }

  @override
  Future<double?> level() async => levelValue;
}

DateTime at(int h, int m) => DateTime(2026, 11, 23, h, m);

SenseChatController makeController({
  FakeFiles? files,
  FakeCall? call,
  List<String>? sentTexts,
  DateTime Function()? now,
}) {
  return SenseChatController(
    sendText: (t) => sentTexts?.add(t),
    files: files ?? FakeFiles(),
    call: call ?? FakeCall(),
    now: now ?? () => at(17, 14),
    pollEvery: Duration.zero,
  );
}

SenseFileJob job(String id, String name, SenseFileDir dir,
        {int done = 0, int total = 0, SenseFileState state = SenseFileState.run, String path = ''}) =>
    SenseFileJob(
      id: id,
      name: name,
      kind: senseFileKind(null, name),
      dir: dir,
      done: done,
      total: total,
      state: state,
      path: path,
    );

/// The c08 conversation: two texts each way, a sent picture, a video coming in.
SenseChatController c08Controller({FakeFiles? files, FakeCall? call}) {
  var clock = at(17, 10);
  final c = makeController(files: files, call: call, now: () => clock);
  c.receiveText("Merhaba, ekran 2'de video takılıyor.");
  clock = at(17, 11);
  c.send('Bakıyorum, birkaç dakika sürer.');
  clock = at(17, 12);
  c.applyJobs([
    job('p1', 'kalibrasyon_ekran2.png', SenseFileDir.out,
        done: 2400000, total: 2400000, state: SenseFileState.ok),
  ]);
  clock = at(17, 13);
  c.receiveText('Takılmanın videosunu çektim, gönderiyorum.');
  c.applyJobs([
    job('p1', 'kalibrasyon_ekran2.png', SenseFileDir.out,
        done: 2400000, total: 2400000, state: SenseFileState.ok),
    job('v1', 'takilma_ekran2.mp4', SenseFileDir.incoming, done: 90500000, total: 184000000),
  ]);
  return c;
}
