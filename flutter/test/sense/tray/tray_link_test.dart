// Sense Remote (YH C5, D3e): the tray's "Çıkış yap" link.
import 'package:flutter_hbb/sense/screens/controller/data/tray_link.dart';
import 'package:flutter_hbb/sense/screens/controller/shell/account_box.dart';
import 'package:flutter_test/flutter_test.dart';

class _Backend implements SenseAccountBackend {
  _Backend(this.open);
  final int open;
  int signOuts = 0;

  @override
  Future<int> openConnections() async => open;

  @override
  Future<void> signOut() async => signOuts++;
}

void main() {
  test('only the bare sign-out link is taken', () {
    expect(senseIsTraySignOutLink(uriString: 'senseremote://sense-signout'), isTrue);
    expect(senseIsTraySignOutLink(uri: Uri.parse('senseremote://sense-signout/')), isTrue);
    expect(senseIsTraySignOutLink(cmdArgs: ['senseremote://sense-signout']), isTrue);
    for (final other in [
      'senseremote://connect/123456789',
      'senseremote://123456789',
      'senseremote://sense-signout/123',
      'senseremote://sense-signout?id=1',
      'sense-signout',
      '',
    ]) {
      expect(senseIsTraySignOutLink(uriString: other), isFalse, reason: other);
    }
    expect(senseIsTraySignOutLink(), isFalse);
  });

  test('signs out only without an open connection, the window comes forward', () async {
    var fronted = 0;
    final idle = _Backend(0);
    expect(await senseTraySignOut(backend: idle, bringToFront: () async => fronted++), isTrue);
    expect(idle.signOuts, 1);
    final busy = _Backend(1);
    expect(await senseTraySignOut(backend: busy, bringToFront: () async => fronted++), isFalse);
    expect(busy.signOuts, 0);
    expect(fronted, 2);
  });
}
