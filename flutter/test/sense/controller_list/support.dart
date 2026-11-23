// Sense Remote: helpers of the Controller list tests (plan B3; YH C1, C2).
//
// Golden images live in test/goldens/controller_list/ and are rendered on the
// Linux CI runner by the golden workflow; there is no Flutter on the developer
// machine. Until an image exists its golden test is skipped, and goldens are
// compared only on Linux (text rasterises differently elsewhere). The example
// data follows the prototype (`PCS2`); names and IDs are made up.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/controller/data/grants.dart';
import 'package:flutter_hbb/sense/screens/controller/data/peers.dart';
import 'package:flutter_hbb/sense/screens/controller/login/login_controller.dart';
import 'package:flutter_hbb/sense/screens/session/data/peer_status.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_test/flutter_test.dart';

import '../session_popups/fixtures.dart' show fullJson, kLastSeen;

/// "Now" of the examples: 8 s after the health values (a02 "Son veri 8 sn önce").
const int kNow = kLastSeen + 8;

String goldenFile(String name) => '../../goldens/controller_list/$name.png';

/// True (skip) off Linux, or while the image has not been generated yet.
bool goldenSkip(String name) =>
    !Platform.isLinux || (!autoUpdateGoldenFiles && !File('test/goldens/controller_list/$name.png').existsSync());

void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Black app with a toast host; [child] fills it.
Widget app(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: senseTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: SenseToastHost(
            child: ColoredBox(
              color: SenseColors.bg,
              child: DefaultTextStyle(
                style: const TextStyle(fontFamily: SenseFont.family, color: SenseColors.text),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );

/// The page area of the window (padding of `.amain`), scrolling.
Widget page(Widget child, {double width = 960}) => Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(22, 18, 22, 24), child: child),
      ),
    );

SenseComputer pc(
  String id,
  String name, {
  String location = '',
  int? displays,
  bool online = true,
  String os = 'Windows',
  String? busy,
  int? lastSeen,
}) =>
    SenseComputer(
      id: id,
      deviceId: 'dev_$id',
      name: name,
      location: location,
      os: os,
      online: online,
      displayCount: displays,
      busyBy: busy,
      lastSeenAt: lastSeen,
    );

/// The prototype's three projects (a01): 8 computers, 6 online, 1 busy.
List<SenseProject> exampleProjects() => [
      SenseProject(id: 'prj_muze', name: 'Örnek Müze', computers: [
        pc('482913207', 'Giriş Salonu PC-2', location: 'Lobi', displays: 3),
        pc('482913208', 'Media server A', location: 'Ana salon', displays: 3),
        pc('482913209', 'Galeri kioskı', location: 'Galeri 1', displays: 1),
        pc('482913210', 'Projeksiyon Mac', location: 'Kubbe', displays: 3, os: 'macOS', busy: 'Mevlüt'),
        pc('482913211', 'Giriş kiosk 2',
            location: 'Lobi', displays: 1, online: false, lastSeen: kNow - 3 * 86400),
      ]),
      SenseProject(id: 'prj_fuar', name: 'Örnek Fuar Standı', computers: [
        pc('482913212', 'LED işlemci PC', location: 'Arka oda', displays: 2),
        pc('482913214', 'Stand ekranı', location: 'Hol 3', displays: 1, online: false),
      ]),
      SenseProject(id: 'prj_ofis', name: 'Ofis', computers: [
        pc('482913213', 'Ofis test PC', location: 'Stüdyo', displays: 2),
      ]),
    ];

/// a02: Giriş Salonu PC-2 is red (Disk D: %96), Media server A orange.
SenseComputerHealth healthFromJson(Map<String, Object?> json) =>
    senseHealthOf(SensePeerStatusFull.parse(jsonEncode(json))!);

/// A computer with only the basic values (v1 health).
Map<String, Object?> simpleJson({double gpuTemp = 51, double gpuPct = 22, double disk = 38}) => {
      'online': true,
      'last_seen_at': kLastSeen,
      'app_version': 4,
      'role': 'host',
      'envelope': {'state': 'applied'},
      'displays': [],
      'network': [],
      'health': {
        'at': kLastSeen - 4,
        'cpu_pct': 9,
        'cpu_temp_c': 47,
        'gpu_pct': gpuPct,
        'gpu_temp_c': gpuTemp,
        'mem_used_mb': 5300,
        'mem_total_mb': 16384,
        'disks': [
          {'mount': 'C:', 'used_pct': disk, 'total_gb': 476},
        ],
      },
    };

/// Media server A (a02): the graphics card at 84 °C (orange).
Map<String, Object?> warnJson() => simpleJson(gpuTemp: 84, gpuPct: 88, disk: 48);
Map<String, Object?> okJson() => simpleJson();

/// Peer-status answers by ID; unknown IDs answer "not found".
class FakePeers implements SensePeersBackend {
  final Map<String, Map<String, Object?>> status = {};
  final List<String> asked = [];
  final List<(String, List<String>)> orders = [];
  bool saveOk = true;
  final Map<String, String> local = {};

  @override
  Future<SensePeerStatusFullResult> peerStatus(String id) async {
    asked.add(id);
    final j = status[id];
    if (j == null) return const SensePeerStatusFullResult.error(SensePeerStatusError.notFound);
    return SensePeerStatusFullResult.ok(SensePeerStatusFull.parse(jsonEncode(j))!);
  }

  @override
  Future<bool> saveOrder(String projectId, List<String> deviceIds) async {
    orders.add((projectId, deviceIds));
    return saveOk;
  }

  @override
  String readLocal(String key) => local[key] ?? '';

  @override
  Future<void> writeLocal(String key, String value) async => local[key] = value;
}

/// A health cache filled with the a02 values (no requests).
SenseHealthCache exampleHealth() {
  final cache = SenseHealthCache(FakePeers(), now: () => kNow, gap: Duration.zero);
  cache.put('482913207', healthFromJson(fullJson()));
  cache.put('482913208', healthFromJson(warnJson()));
  cache.put('482913209', healthFromJson(okJson()));
  cache.put('482913210', healthFromJson(okJson()));
  cache.put('482913212', healthFromJson(okJson()));
  cache.put('482913213', healthFromJson(okJson()));
  return cache;
}

class FakeGrants implements SenseGrantsBackend {
  FakeGrants([Map<String, Object?>? answer])
      : answer = jsonEncode(answer ?? {'state': 'ok', 'perms': SensePerm.all, 'email': 'halil@example.com', 'rev': 3});
  String answer;
  int refreshes = 0;

  @override
  Future<String> grants() async => answer;

  @override
  Future<void> refresh() async => refreshes++;
}

class FakeLogin implements SenseLoginBackend {
  String? op = 'google';
  List<String> results = [
    jsonEncode({'state_msg': 'Waiting account auth', 'failed_msg': '', 'url': 'https://panel.example/oidc', 'pairing_code': '731054'}),
  ];
  Map<String, dynamic>? completed;
  bool completeOk = true;
  final List<String> calls = [];

  @override
  Future<String?> provider() async => op;

  @override
  Future<void> start(String op) async => calls.add('start:$op');

  @override
  Future<String> result() async => results.length > 1 ? results.removeAt(0) : results.first;

  @override
  Future<void> cancel() async => calls.add('cancel');

  @override
  Future<bool> complete(Map<String, dynamic> authBody) async {
    completed = authBody;
    return completeOk;
  }

  @override
  Future<void> openUrl(String url) async => calls.add('open:$url');

  @override
  Future<void> copy(String text) async => calls.add('copy:$text');
}
