// Sense Remote: setting keys shared by C3 and O3–O6, and the lock wrapper (TK9 §4; A2a).
import 'package:flutter_hbb/sense/data/option_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every key is listed once', () {
    final keys = SenseOptionKeys.all.map((k) => k.key).toList();
    expect(keys.toSet().length, keys.length);
    expect(SenseOptionKeys.byKey('view_style'), SenseOptionKeys.viewStyle);
    expect(SenseOptionKeys.byKey('nope'), isNull);
  });

  test('TK9 §4 lock sources', () {
    expect(SenseOptionKeys.connType.lock, SenseOptionLock.hard);
    for (final k in [SenseOptionKeys.autoDisconnect, SenseOptionKeys.autoDisconnectTimeout,
        SenseOptionKeys.removeWallpaper]) {
      expect(k.lock, SenseOptionLock.panel, reason: k.key);
    }
    for (final k in [SenseOptionKeys.rendezvousServer, SenseOptionKeys.apiServer,
        SenseOptionKeys.relayServer, SenseOptionKeys.serverKey, SenseOptionKeys.autoUpdate]) {
      expect(k.lock, SenseOptionLock.overwrite, reason: k.key);
    }
    // Decision 5 (2026-11-23): LAN discovery, direct IP and proxy are really locked.
    for (final k in ['enable-lan-discovery', 'direct-server', 'direct-access-port', 'proxy-url']) {
      expect(SenseOptionKeys.byKey(k)!.lock, SenseOptionLock.decision, reason: k);
    }
    for (final k in [SenseOptionKeys.openInTabs, SenseOptionKeys.viewOnly, SenseOptionKeys.hwcodec]) {
      expect(k.lock, SenseOptionLock.open, reason: k.key);
    }
  });

  test('the "Yeni bağlantılar" defaults are the session menu keys', () {
    final group = SenseOptionKeys.all.where((k) => k.group == SenseOptionGroup.newConnections);
    expect(group.map((k) => k.key), ['view_style', 'image_quality', 'view_only', 'privacy_mode']);
    expect(group.every((k) => k.store == SenseOptionStore.userDefault), isTrue);
  });

  test('without the native side the design list answers', () {
    expect(senseOptionLocked('proxy-url'), isTrue);
    expect(senseOptionLocked('allow-auto-disconnect'), isTrue);
    expect(senseOptionLocked('view_only'), isFalse);
  });

  test('the wrapper can be replaced (tests, D3e bridge)', () {
    final saved = senseOptionLockedImpl;
    addTearDown(() => senseOptionLockedImpl = saved);
    senseOptionLockedImpl = (key) => key == 'view_only';
    expect(senseOptionLocked('view_only'), isTrue);
    expect(senseOptionLocked('proxy-url'), isFalse);
  });
}
