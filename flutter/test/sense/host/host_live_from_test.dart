// Sense Remote (P3, B4): "who is connected" comes from the live server model, not a fixed '{}'.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/sense/screens/host/data/host_status.dart';

Client client(String name,
    {bool authorized = true, bool disconnected = false, bool file = false}) {
  final c = Client(1, authorized, file, false, name, '123', false, false, false);
  c.disconnected = disconnected;
  return c;
}

void main() {
  test('no client: nothing known', () {
    expect(senseHostLiveFrom(const []), '{}');
    expect(SenseHostLive.parse(senseHostLiveFrom(const [])).connectedBy, isNull);
  });

  test('an authorized open connection names who is connected', () {
    final raw = senseHostLiveFrom([client('Ayşe Y.')]);
    expect(jsonDecode(raw), {'connected_by': 'Ayşe Y.'});
    expect(SenseHostLive.parse(raw).connectedBy, 'Ayşe Y.');
  });

  test('waiting, closed and file-transfer connections do not count', () {
    expect(senseHostLiveFrom([client('A', authorized: false)]), '{}');
    expect(senseHostLiveFrom([client('A', disconnected: true)]), '{}');
    expect(senseHostLiveFrom([client('A', file: true)]), '{}');
    expect(
        jsonDecode(senseHostLiveFrom([client('A', file: true), client('Mert')])),
        {'connected_by': 'Mert'});
  });
}
