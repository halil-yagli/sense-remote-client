// Sense Remote: helpers of the Host window tests (plan B2; YH H1, H2).
//
// Golden images live in test/goldens/host/ and are rendered on the Linux CI runner
// by the golden workflow (`flutter test --update-goldens`); there is no Flutter on the
// developer machine. Until an image exists its golden test is skipped, and goldens
// are compared only on Linux (text rasterises differently elsewhere).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/host/data/identity.dart';
import 'package:flutter_hbb/sense/screens/host/role/role_category.dart';
import 'package:flutter_hbb/sense/screens/host/sense_password_model.dart';
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_test/flutter_test.dart';

const int kNow = 1000000;
const String kUrl = 'https://remote.example/onay?f=deneme-akisi';

String goldenFile(String name) => '../../goldens/host/$name.png';

/// True (skip) off Linux, or while the image has not been generated yet.
bool goldenSkip(String name) =>
    !Platform.isLinux || (!autoUpdateGoldenFiles && !File('test/goldens/host/$name.png').existsSync());

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

/// A page-width box that scrolls (the view inside the shell's main area).
Widget page(Widget child, {double width = 900}) => Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
      ),
    );

String statusJson(Map<String, Object?> json) => jsonEncode({
      'supported': true,
      'role': 'host',
      'perm_set': true,
      'changed_at': DateTime(2026, 11, 12, 10).millisecondsSinceEpoch ~/ 1000,
      'stage': 'locked',
      'until': null,
      'user': null,
      ...json,
    });

class FakePassword implements SensePasswordBackend {
  String statusAnswer = statusJson({});
  String beginAnswer = '{"ok":true}';
  List<String> logins = [
    jsonEncode({'state': 'waiting', 'url': kUrl, 'pairing_code': '482913'}),
  ];
  String unlockAnswer = jsonEncode({'ok': true, 'until': kNow + 300, 'user': 'Halil'});
  String checkAnswer = '';
  String setAnswer = '';
  final calls = <String>[];
  final setPasswords = <String>[];

  @override
  Future<String> status() async => statusAnswer;
  @override
  Future<String> begin() async {
    calls.add('begin');
    return beginAnswer;
  }

  @override
  Future<String> loginStatus() async => logins.length > 1 ? logins.removeAt(0) : logins.first;
  @override
  Future<String> unlock() async {
    calls.add('unlock');
    return unlockAnswer;
  }

  @override
  Future<String> check(String password) async {
    calls.add('check');
    return checkAnswer;
  }

  @override
  Future<String> set(String password) async {
    calls.add('set');
    setPasswords.add(password);
    return setAnswer;
  }

  @override
  Future<void> cancel() async => calls.add('cancel');
  @override
  void openUrl(String url) => calls.add('open');
  @override
  Future<void> copy(String text) async => calls.add('copy');
}

class FakeRole implements SenseRoleBackend {
  FakeRole({this.roles = const ['host']});
  List<String> roles;
  String beginAnswer = jsonEncode({'pairing_code': '731054', 'url': kUrl, 'expires_at': kNow + 174});
  List<String> statuses = ['{"stage":"login"}'];
  final calls = <String>[];

  @override
  Future<String> status() async => jsonEncode({'roles': roles, 'pending': null, 'error': null});
  @override
  Future<String> begin(String target) async {
    calls.add('begin:$target');
    return beginAnswer;
  }

  @override
  Future<String> changeStatus() async => statuses.length > 1 ? statuses.removeAt(0) : statuses.first;
  @override
  Future<void> cancel() async => calls.add('cancel');
}

class FakeIdentity implements SenseIdentityBackend {
  String answer = '{"ok":true}';
  final sets = <String>[];
  @override
  Future<String> identity() async => jsonEncode({
        'name': 'Galeri kioskı',
        'location_id': 'g1',
        'location_name': 'Galeri 1',
        'locations': [
          {'id': 'g1', 'name': 'Galeri 1'},
          {'id': 'lobi', 'name': 'Lobi'},
        ],
        'panel': 'ok',
      });
  @override
  Future<String> setIdentity(String name, String placeId) async {
    sets.add('$name|$placeId');
    return answer;
  }
}

const SenseIdentity kIdentity = SenseIdentity(
  name: 'Galeri kioskı',
  placeId: 'g1',
  placeName: 'Galeri 1',
  places: [SensePlace('g1', 'Galeri 1'), SensePlace('lobi', 'Lobi')],
  panelOk: true,
);

/// Password controller in a given stage (no timer runs: one-day interval).
SensePasswordController passwordIn(SensePasswordStage stage,
    {Map<String, Object?> status = const {}, FakePassword? backend}) {
  final c = SensePasswordController(backend ?? FakePassword(),
      interval: const Duration(days: 1), now: () => kNow);
  c.status = SensePasswordStatus.parse(statusJson(status));
  c.stage = stage;
  return c;
}

/// Role controller with Host installed (no timer runs).
SenseRoleController roleWith({Set<SenseRole> current = const {SenseRole.host}, FakeRole? backend}) {
  final c = SenseRoleController(backend ?? FakeRole(), interval: const Duration(days: 1), now: () => kNow);
  c.current = {...current};
  return c;
}
