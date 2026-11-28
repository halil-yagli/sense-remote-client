// Sense Remote (Sürüm 12, plan 2026-11-28 §2.4): the "Sık kullanılanlar" list over the
// bridge. Every call is one bridge function of the plan; nothing else is reached. Keys are
// sent with the same RustDesk functions as the stock menu (Ctrl+Alt+Del, lock) or as one
// key press with the Windows key (Win+D).
import '../../../../../common.dart' show SessionID;
import '../../../../../models/platform_model.dart' show bind;
import 'catalog.dart';
import 'favorites_io.dart';

class SenseFavoritesFfiIo implements SenseFavoritesIo {
  SenseFavoritesFfiIo(this.sessionId);

  final SessionID sessionId;

  @override
  Future<String> catalog(SenseFavOs os) => bind.mainSenseShortcutCatalog(os: os.code);

  @override
  Future<String> prefsGet(SenseFavOs os) => bind.mainSensePrefsGet(os: os.code);

  @override
  Future<String> prefsSet(String json) => bind.mainSensePrefsSet(json: json);

  @override
  Future<String> customRequest(String json) => bind.mainSenseCustomShortcutRequest(json: json);

  @override
  Future<String> send(String name, String json) =>
      bind.sessionSenseSendMsg(sessionId: sessionId, name: name, json: json);

  @override
  bool sendKeys(SenseFavKeys keys) {
    switch (keys) {
      case SenseFavKeys.ctrlAltDel:
        bind.sessionCtrlAltDel(sessionId: sessionId);
      case SenseFavKeys.lockScreen:
        bind.sessionLockScreen(sessionId: sessionId);
      case SenseFavKeys.winD:
        bind.sessionInputKey(
            sessionId: sessionId,
            name: 'VK_D',
            down: false,
            press: true,
            alt: false,
            ctrl: false,
            shift: false,
            command: true);
    }
    return true;
  }
}
