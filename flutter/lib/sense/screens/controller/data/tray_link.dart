// Sense Remote (YH C5, D3e): the tray menu's "Çıkış yap". The menu is the
// operating system's own (#69, `src/tray.rs`), drawn by the tray process; it
// hands the request to this window as the link `<scheme>://sense-signout`
// (the same way the tray's recent connections arrive as `connect` links).
//
// The link comes in through `handleUriLink` (common.dart). It only signs out
// when no connection window is open (C1: "Açık bağlantı yok."); with an open
// connection the window just comes forward and nothing else happens. The
// link carries nothing else: whoever opens it can at most sign this person
// out, never in, and never touch a connection.
import '../shell/account_box.dart' show SenseAccountBackend, SenseAccountBridge;

/// Authority of the tray's sign-out link (`tray_menu::SIGN_OUT_AUTHORITY`).
const String kSenseTraySignOutAuthority = 'sense-signout';

/// Pure: whether one of the given forms of a link is the tray's sign-out link.
bool senseIsTraySignOutLink({List<String>? cmdArgs, Uri? uri, String? uriString}) {
  Uri? u = uri;
  if (u == null && uriString != null) u = Uri.tryParse(uriString);
  if (u == null && cmdArgs != null && cmdArgs.isNotEmpty) u = Uri.tryParse(cmdArgs.first);
  if (u == null || u.scheme.isEmpty) return false;
  final path = u.path;
  return u.authority == kSenseTraySignOutAuthority &&
      (path.isEmpty || path == '/') &&
      u.query.isEmpty;
}

/// What the link does; tests pass a fake backend and window hook.
Future<bool> senseTraySignOut({
  SenseAccountBackend backend = const SenseAccountBridge(),
  required Future<void> Function() bringToFront,
}) async {
  await bringToFront();
  if (await backend.openConnections() > 0) return false;
  await backend.signOut();
  return true;
}
