// Sense Remote (Sürüm 12): helpers for the "Sık kullanılanlar" tests. The fake answers
// with the core's real strings: by default exactly what this build's core (ÇK-0 skeleton)
// returns — an empty catalogue, `{"error":"unsupported"}` for the preference store and the
// custom request, "" for a sent message.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/catalog.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_io.dart';
import 'package:flutter_hbb/sense/screens/session/lists/favorites/favorites_model.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

/// The core's answers of this build (ÇK-0, `src/sense/shortcuts/mod.rs`, `prefs_sync.rs`).
const String kCoreCatalogEmpty = '[]';
const String kCoreUnsupported = '{"error":"unsupported"}';

class FakeFavIo implements SenseFavoritesIo {
  FakeFavIo({
    this.catalogJson = kCoreCatalogEmpty,
    Map<SenseFavOs, String>? prefs,
    this.setAnswer = 'unsupported',
    this.customAnswer = kCoreUnsupported,
    this.sendAnswer = '',
  }) : prefs = prefs ?? {};

  String catalogJson;
  final Map<SenseFavOs, String> prefs;
  String setAnswer;
  String customAnswer;
  String sendAnswer;

  final List<String> setCalls = [];
  final List<String> customCalls = [];
  final List<(String, Map<String, dynamic>)> sent = [];
  final List<SenseFavKeys> keys = [];

  /// Sürüm 12 (#171): the Host's answers by shortcut id, pushed back the way the core pushes
  /// `sense_shortcut_result` (after the run was sent). Ids without an answer are never
  /// answered (an older Host). [answer] may look at the run (`arg`).
  final Map<String, HostAnswer Function(Map<String, dynamic> run)> host = {};
  String hostPeer = 'p1';

  @override
  Future<String> catalog(SenseFavOs os) async => catalogJson;

  @override
  Future<String> prefsGet(SenseFavOs os) async => prefs[os] ?? kCoreUnsupported;

  @override
  Future<String> prefsSet(String json) async {
    setCalls.add(json);
    return setAnswer;
  }

  @override
  Future<String> customRequest(String json) async {
    customCalls.add(json);
    return customAnswer;
  }

  @override
  Future<String> send(String name, String json) async {
    final body = jsonDecode(json) as Map<String, dynamic>;
    sent.add((name, body));
    final answer = host[body['id']];
    if (answer != null && sendAnswer.isEmpty) {
      final a = answer(body);
      // A timer, not a microtask: the model waits for the answer only after `send` returned.
      Timer(Duration.zero, () {
        SenseFavoritesEvents.handle(hostPeer, {
          'name': 'sense_shortcut_result',
          'req': body['req'],
          'ok': a.ok,
          'err': a.err,
          'res': a.res,
        });
      });
    }
    return sendAnswer;
  }

  @override
  bool sendKeys(SenseFavKeys k) {
    keys.add(k);
    return true;
  }
}

/// One Host answer (`sense_shortcut_result {ok, err, res}`).
typedef HostAnswer = ({bool ok, String? err, Object? res});

/// Result bodies exactly as the Host builds them (`src/sense/shortcuts/results.rs`).
const Map<String, dynamic> kResPing = {
  'ping': {'sent': 4, 'received': 4, 'avg_ms': 18, 'loss': 0}
};
const Map<String, dynamic> kResPingLost = {
  'ping': {'sent': 4, 'received': 0, 'avg_ms': null, 'loss': 100}
};
const Map<String, dynamic> kResWindows = {
  'windows': [
    {'pid': 4120, 'name': 'Sergi uygulaması', 'hung': true},
    {'pid': 5532, 'name': 'Medya oynatıcı', 'hung': false},
    {'pid': 7781, 'name': 'Tarayıcı', 'hung': false},
  ]
};
const Map<String, dynamic> kResIp = {
  'ip': {
    'ip': '192.168.10.42',
    'gateway': ['192.168.10.1'],
    'dns': ['192.168.10.1', '8.8.8.8'],
  }
};

/// A preference store answer as the core gives it (`{entries, custom}`).
String prefsJson({
  required SenseFavOs os,
  List<Map<String, Object?>> items = const [],
  List<String> recent = const [],
  List<Map<String, Object?>> custom = const [],
}) =>
    jsonEncode({
      'entries': [
        {'os': os.code, 'key': 'fav.items', 'value': items, 'rev': 3, 'updated_at': '2026-11-28T10:00:00Z'},
        {'os': os.code, 'key': 'fav.recent', 'value': recent, 'rev': 2, 'updated_at': '2026-11-28T10:00:00Z'},
      ],
      'custom': custom,
    });

/// The Windows list of the prototype (`ST.fav.win`, `ST.favKey.win`, `ST.favRecent.win`).
String prototypeWinPrefs() => prefsJson(
      os: SenseFavOs.win,
      items: [
        {'id': 'win.taskmgr', 'key': 1},
        {'id': 'win.netadapt', 'key': 2},
        {'id': 'win.thispc', 'key': null},
      ],
      recent: ['win.netadapt', 'win.ipinfo', 'win.taskmgr'],
      custom: [
        {'id': 'cu1', 'os': 'win', 'label': 'Sergi uygulamasını yeniden başlat', 'kind': 'program', 'scope': 'project'},
        {'id': 'cu2', 'os': 'win', 'label': 'Videolar klasörü', 'kind': 'folder', 'scope': 'person'},
      ],
    );

String prototypeMacPrefs() => prefsJson(
      os: SenseFavOs.mac,
      items: [
        {'id': 'mac.actmon', 'key': 1},
        {'id': 'mac.net', 'key': null},
        {'id': 'mac.term', 'key': null},
      ],
      recent: ['mac.actmon', 'mac.term', 'mac.net'],
    );

/// The core's catalogue once FAV-Ç is in (a few entries are enough for the tests).
String coreCatalog(List<(String, String, bool)> entries) => jsonEncode([
      for (final e in entries) {'id': e.$1, 'cat': 'x', 'kind': e.$2, 'admin': false, 'available': e.$3},
    ]);

Future<SenseFavoritesModel> loadedModel(FakeFavIo io,
    {SenseFavOs os = SenseFavOs.win, bool input = true, List<String>? notices, String peerId = 'p1'}) async {
  final m = SenseFavoritesModel(
    io: io,
    os: os,
    peerId: peerId,
    computerName: 'Giriş Salonu PC-2',
    inputAllowed: input,
    onNotice: notices?.add,
  );
  await m.load();
  return m;
}

const String kGoldenDir = 'test/goldens/favorites';

String goldenFile(String name) => '../../goldens/favorites/$name.png';

bool goldenSkip(String name) => !autoUpdateGoldenFiles && !File('$kGoldenDir/$name.png').existsSync();

void setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The list on the dark session background, as it hangs from the bar.
Widget listApp(Widget list) => MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Scaffold(
        backgroundColor: SenseColors.bg,
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: RepaintBoundary(key: const Key('golden'), child: list),
          ),
        ),
      ),
    );
