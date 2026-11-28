// Sense Remote (Sürüm 12, #164, U164, ST 1–3): the connecting cards. The whole life of a
// connection before the session layers take over is drawn in the Sense card family
// (prototype `cstSim`, `.cstov .nc`: same card as O13/O14, in the middle of the window):
//   Bağlanılıyor (3 steps) · Karşı tarafın onayı · Meşgul · Çevrimdışı · Parola gerekiyor ·
//   Parola yanlış · 2 adımlı kod · İzin reddedildi · Yetkin yok · Zaman aşımı · Ağ hatası.
// "Görüntü bekleniyor", "Kesildi · yeniden bağlanılıyor" and "Bağlantı sona erdi" stay the
// session layers' cards (layer_views.dart); this layer steps aside once they are up.
//
// The cards work before `pi.isSet` (they are mounted with the page) and in every window
// kind: remote screen, files, terminal, tunnel, camera ([SenseConnectCards.attach]).
// RustDesk's stock box is only the fallback for a message no card knows; each such box is
// recorded as `ui/dialog` ([SenseConnectCards.noteStockDialog]; target: none) and each card
// as `ui/card`.
import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../components/sense_dialog.dart';
import '../../../diag_log.dart' show senseUiEvent;
import '../../../sense.dart';
import '../../../strings/connect.dart';
import 'data/session_hub.dart';
import 'layer_spec.dart';
import 'layer_views.dart' show SenseLayerCard, SenseLayerVeil;

/// What the window connects for.
enum SenseConnectKind { screen, file, terminal, tunnel, camera }

/// The cards (#164).
enum SenseConnectCard {
  connecting,
  waitingAccept,
  busy,
  offline,
  notFound,
  password,
  passwordWrong,
  otp,
  otpWrong,
  denied,
  noPermission,
  timeout,
  network,
  failed,
}

/// Reads a RustDesk message box that arrives while connecting (`msgbox`: type, title, text).
/// Null = no card for it (the stock box stays, recorded as `ui/dialog`).
/// Texts: `client.rs` `handle_login_error`, `LOGIN_ERROR_MAP`, `on_establish_connection_error`,
/// `server/connection.rs` `send_login_error`, `io_loop.rs` timeouts, S8 `sense_busy`.
SenseConnectCard? senseConnectCardOf(String type, String title, String text) {
  switch (type) {
    case 'input-password':
      return SenseConnectCard.password;
    case 're-input-password':
      return SenseConnectCard.passwordWrong;
    case 'input-2fa':
      return title == 'Wrong 2FA Code' ? SenseConnectCard.otpWrong : SenseConnectCard.otp;
    case 'wait-remote-accept-nook':
      return SenseConnectCard.waitingAccept;
  }
  final t = text.toLowerCase();
  if (t.contains('sense_busy')) return SenseConnectCard.busy;
  final error = type == 'error' || title == 'Connection Error' || title == 'Login Error';
  if (!error) return null;
  // A security warning keeps RustDesk's own box (it must be read word for word).
  if (t.contains('mismatch') || type.contains('insecure')) return null;
  if (t.contains('remote desktop is offline') || t == 'offline') return SenseConnectCard.offline;
  if (t.contains('id does not exist') || t.contains('not exist')) return SenseConnectCard.notFound;
  if (t.contains('no permission') || t.contains('incoming only') || t.contains('incoming-only')) {
    return SenseConnectCard.noPermission;
  }
  if (t.contains('connection not allowed') ||
      t.contains('blocked by the peer') ||
      t.contains('closed manually by the peer') ||
      t.contains('main window is not open')) {
    return SenseConnectCard.denied;
  }
  if (t.contains('timeout') || t.contains('timed out') || t.contains('deadline')) {
    return SenseConnectCard.timeout;
  }
  if (t.contains('failed to connect') ||
      t.contains('rendezvous') ||
      t.contains('resolve') ||
      t.contains('unreachable') ||
      t.contains('no route') ||
      t.contains('dns')) {
    return SenseConnectCard.network;
  }
  if (t.contains('reset') || t.contains('broken pipe') || t.contains('aborted') || t.contains('closed')) {
    return SenseConnectCard.failed;
  }
  return null;
}

/// Sürüm 12: who holds the computer, from the Host's busy answer
/// (`sense_busy {"by":"<display name>","since":<unix s>}`, `src/sense/single_conn.rs`).
class SenseBusyDetail {
  const SenseBusyDetail({this.by, this.since});

  /// The Sense employee's display name (at most 64 characters).
  final String? by;

  /// Connected since, Unix s.
  final int? since;
}

/// Reads the detail of a busy answer; null for the plain `sense_busy` of an older Host or an
/// unreadable tail.
SenseBusyDetail? senseBusyDetailOf(String text) {
  final at = text.indexOf('sense_busy');
  if (at < 0) return null;
  final open = text.indexOf('{', at);
  if (open < 0) return null;
  try {
    final v = jsonDecode(text.substring(open));
    if (v is! Map) return null;
    final rawBy = v['by'];
    var by = rawBy is String ? rawBy.trim() : '';
    if (by.length > 64) by = by.substring(0, 64);
    final rawSince = v['since'];
    final since = rawSince is int && rawSince > 0 ? rawSince : null;
    if (by.isEmpty && since == null) return null;
    return SenseBusyDetail(by: by.isEmpty ? null : by, since: since);
  } catch (_) {
    return null;
  }
}

/// Sürüm 12: what the panel knows about a computer that is offline (peer-status).
class SenseOfflineInfo {
  const SenseOfflineInfo({this.lastSeenAt, this.wakeable});

  /// Last heartbeat, Unix s.
  final int? lastSeenAt;

  /// The panel can wake it (null = not said).
  final bool? wakeable;
}

/// Name of a card in the record (`ui/card kind=…`).
String senseConnectCardName(SenseConnectCard c) => switch (c) {
      SenseConnectCard.connecting => 'connecting',
      SenseConnectCard.waitingAccept => 'wait_accept',
      SenseConnectCard.busy => 'busy',
      SenseConnectCard.offline => 'offline',
      SenseConnectCard.notFound => 'not_found',
      SenseConnectCard.password => 'password',
      SenseConnectCard.passwordWrong => 'wrong_password',
      SenseConnectCard.otp => 'otp',
      SenseConnectCard.otpWrong => 'wrong_otp',
      SenseConnectCard.denied => 'denied',
      SenseConnectCard.noPermission => 'no_permission',
      SenseConnectCard.timeout => 'timeout',
      SenseConnectCard.network => 'network',
      SenseConnectCard.failed => 'failed',
    };

/// What the cards need from the RustDesk session (data/session_bridge.dart; tests: a fake).
abstract class SenseConnectHost {
  /// Name of the computer for the card text.
  String get peerName;

  /// The session is up and its own layers took over: from now on only the password and
  /// 2-step code cards are taken (a reconnect may ask again).
  bool get connected;

  /// The session layers already show a card (ended / lost): no "Bağlanılıyor" over them.
  bool get layerOwnsScreen;

  /// 0 Bilgisayar aranıyor · 1 Bağlantı kuruluyor · 2 Görüntü bekleniyor (real signals).
  int get step;

  /// "Bu bilgisayara güven" is offered for the 2-step code (stock trusted devices).
  bool get trustAvailable;

  /// The stock "Parolayı hatırla" value of this computer (K5; off unless chosen before).
  Future<bool> remembered();

  void login(String password, bool remember);
  void send2fa(String code, bool trust);

  /// Connect again in this window.
  void retry();

  /// Sürüm 12: the panel's last-seen time (and whether it can wake it) for the offline card.
  /// Null when the panel has nothing (no sign-in, not a Sense computer, network error).
  Future<SenseOfflineInfo?> offlineInfo();

  /// Close this connection window.
  void close();
}

class SenseConnectController extends ChangeNotifier {
  SenseConnectController(
      {required this.host, this.kind = SenseConnectKind.screen, bool autoStart = true, DateTime Function()? now})
      : now = now ?? DateTime.now {
    if (autoStart) start();
  }

  final SenseConnectHost host;
  final SenseConnectKind kind;

  /// Clock for "12 dk'dır" and "son görülme" (tests: fixed).
  final DateTime Function() now;

  /// Sürüm 12: who holds the computer (busy card); null = the Host did not say.
  SenseBusyDetail? busy;

  /// Sürüm 12: last seen / wake (offline card); null until the panel answered.
  SenseOfflineInfo? offline;

  SenseConnectCard? _card;
  int _step = 0;
  bool _loginSent = false;
  int? _retryIn;
  int _backoff = 1;
  bool remember = false;
  bool trust = false;
  Timer? _timer;
  bool _disposed = false;

  /// RustDesk's stock retry starts at 1 s and doubles; the card keeps it, at most this long.
  static const int maxBackoff = 64;

  SenseConnectCard? get card => _card;
  int get step => _step < 1 && _loginSent ? 1 : _step;

  /// Seconds until RustDesk's automatic retry (null = none planned).
  int? get retryIn => _retryIn;

  /// Stops the one-second tick (the layer widget left the tree; it starts again when mounted).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void start() {
    if (_disposed) return;
    _timer ??= Timer.periodic(SenseLinkTiming.tick, (_) => tick());
    host.remembered().then((v) {
      if (_disposed) return;
      remember = v;
      _notify();
    }).catchError((_) {});
  }

  /// One second: steps from the session, the automatic retry, and stepping aside when up.
  void tick() {
    if (_disposed) return;
    _step = host.step;
    final c = _card;
    if ((c == SenseConnectCard.connecting || c == SenseConnectCard.waitingAccept) && host.connected) {
      _set(null);
      _loginSent = false;
      _backoff = 1;
      return;
    }
    final r = _retryIn;
    if (r != null) {
      if (r <= 1) {
        _retryIn = null;
        retryNow(auto: true);
        return;
      }
      _retryIn = r - 1;
    }
    _notify();
  }

  /// "Bağlanılıyor" (page start, RustDesk's reconnect).
  void showConnecting() {
    if (host.layerOwnsScreen) return;
    _retryIn = null;
    _set(SenseConnectCard.connecting);
  }

  /// A RustDesk message box of this session. True = a card took it (no stock box).
  bool onMessage(String type, String title, String text, bool hasRetry) {
    if (_disposed) return false;
    final card = senseConnectCardOf(type, title, text);
    if (card == null) return false;
    final loginCard = card == SenseConnectCard.password ||
        card == SenseConnectCard.passwordWrong ||
        card == SenseConnectCard.otp ||
        card == SenseConnectCard.otpWrong ||
        card == SenseConnectCard.waitingAccept;
    if (host.connected && !loginCard) return false;
    _loginSent = false;
    busy = card == SenseConnectCard.busy ? senseBusyDetailOf(text) : null;
    if (card == SenseConnectCard.offline) _loadOffline();
    final retryable = hasRetry &&
        (card == SenseConnectCard.timeout ||
            card == SenseConnectCard.network ||
            card == SenseConnectCard.failed ||
            card == SenseConnectCard.offline);
    if (retryable) {
      _retryIn = _backoff;
      _backoff = _backoff * 2 > maxBackoff ? maxBackoff : _backoff * 2;
    } else {
      _retryIn = null;
      _backoff = 1;
    }
    _set(card);
    return true;
  }

  void _loadOffline() {
    host.offlineInfo().then((info) {
      if (_disposed || info == null) return;
      offline = info;
      _notify();
    }).catchError((_) {});
  }

  void submitPassword(String password) {
    final p = password.trim();
    if (p.isEmpty) return;
    host.login(p, remember);
    _loginSent = true;
    _set(SenseConnectCard.connecting);
  }

  void submitCode(String code) {
    final c = code.replaceAll(' ', '').trim();
    if (c.isEmpty) return;
    host.send2fa(c, trust);
    _loginSent = true;
    _set(SenseConnectCard.connecting);
  }

  void retryNow({bool auto = false}) {
    if (!auto) _backoff = 1;
    _retryIn = null;
    host.retry();
    _set(SenseConnectCard.connecting);
  }

  void close() {
    _retryIn = null;
    _timer?.cancel();
    _timer = null;
    host.close();
  }

  void setRemember(bool v) {
    remember = v;
    _notify();
  }

  void setTrust(bool v) {
    trust = v;
    _notify();
  }

  void _set(SenseConnectCard? c) {
    final was = _card;
    _card = c;
    if (c != null && c != was) senseUiEvent('card', {'kind': senseConnectCardName(c)});
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// The layer of one connection window. [attach] gives the widget a page puts last in its
/// stack; it takes no clicks while no card is up.
abstract final class SenseConnectCards {
  static final Map<String, SenseConnectController> _byId = {};

  /// Stock RustDesk boxes shown since start (target 0; `ui/dialog`).
  static int stockDialogs = 0;

  /// §2.5: the card layer for [id] (tab key = peer id). [host] is the session's bridge
  /// (data/session_bridge.dart `SenseFfiConnectHost`). The controller lives until [remove].
  static Widget attach(String id, {required SenseConnectKind kind, required SenseConnectHost host, Key? key}) =>
      SenseConnectLayer(key: key, id: id, controller: controllerFor(id, kind: kind, host: host));

  static SenseConnectController controllerFor(String id,
          {required SenseConnectKind kind, required SenseConnectHost host}) =>
      // The layer widget runs the tick while it is mounted (no timer outlives the page).
      _byId.putIfAbsent(id, () => SenseConnectController(host: host, kind: kind, autoStart: false)..showConnecting());

  static SenseConnectController? find(String id) => _byId[id];

  /// The page closed.
  static void remove(String id) => _byId.remove(id)?.dispose();

  /// A stock RustDesk box is about to show instead of a Sense card: counted and recorded.
  static void noteStockDialog(String type, {String? title}) {
    stockDialogs++;
    final kind = type.isEmpty ? (title ?? 'unknown') : type;
    senseUiEvent('dialog', {'kind': kind.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_')});
  }
}

class SenseConnectLayer extends StatefulWidget {
  const SenseConnectLayer({super.key, required this.id, required this.controller});

  final String id;
  final SenseConnectController controller;

  @override
  State<SenseConnectLayer> createState() => _SenseConnectLayerState();
}

class _SenseConnectLayerState extends State<SenseConnectLayer> {
  SenseConnectController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
    _c.start();
    SenseSessionHub.registerConnect(widget.id, _c.onMessage, onConnecting: _c.showConnecting);
  }

  @override
  void didUpdateWidget(SenseConnectLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_changed);
      old.controller.stop();
      SenseSessionHub.unregisterConnect(old.id, old.controller.onMessage);
      _c.addListener(_changed);
      _c.start();
      SenseSessionHub.registerConnect(widget.id, _c.onMessage, onConnecting: _c.showConnecting);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    _c.stop();
    SenseSessionHub.unregisterConnect(widget.id, _c.onMessage);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final card = _c.card;
    if (card == null) return const SizedBox.shrink();
    return SenseConnectCardView(key: ValueKey('sense-connect-${senseConnectCardName(card)}'), controller: _c);
  }
}

/// Sizes of the card (prototype `.cstov`).
abstract final class SenseConnectLook {
  /// `.cstov .nc{width:380px}`; the inside is the width less the card's side padding.
  static const double cardWidth = 380;
  static double get innerWidth => cardWidth - 2 * SenseLayerLook.cardPadSide;

  /// `.csteps` gap 6, margin 8 0 2, 13 px marks.
  static const double stepGap = 6;
  static const double stepMark = 13;
  static const double buttonsTop = 8;
  static const double buttonGap = 8;
}

/// One card on its veil. Stateful for the field.
class SenseConnectCardView extends StatefulWidget {
  const SenseConnectCardView({super.key, required this.controller, this.appear = 1});

  final SenseConnectController controller;
  final double appear;

  @override
  State<SenseConnectCardView> createState() => _SenseConnectCardViewState();
}

class _SenseConnectCardViewState extends State<SenseConnectCardView> {
  final TextEditingController _field = TextEditingController();

  SenseConnectController get _c => widget.controller;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  String _offlineBody() {
    final seen = _c.offline?.lastSeenAt;
    if (seen == null || seen <= 0) return SenseConnectStrings.offlineBody;
    final at = DateTime.fromMillisecondsSinceEpoch(seen * 1000);
    return SenseConnectStrings.offlineBodySeen(SenseConnectStrings.seenAt(at, _c.now()));
  }

  void _submitPassword() {
    _c.submitPassword(_field.text);
    _field.clear();
  }

  void _submitCode() {
    _c.submitCode(_field.text);
    _field.clear();
  }

  @override
  Widget build(BuildContext context) {
    final card = _c.card!;
    final name = _c.host.peerName;
    final children = <Widget>[];
    Widget title(String t, Color color) => Text(t,
        textAlign: TextAlign.center,
        style: SenseTextStyles.of(size: SenseLayerLook.titleSize, weight: SenseFontWeight.bold, color: color));
    Widget sub(String t) => Text(t,
        textAlign: TextAlign.center,
        style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.textMuted, height: 1.5));
    Widget hint(String t) => Text(t,
        textAlign: TextAlign.center,
        style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim));
    Widget errLine(String t) => Align(
          alignment: Alignment.centerLeft,
          child: Text(t, style: SenseTextStyles.of(size: SenseFontSize.hintLarge, color: SenseColors.dangerText)),
        );
    SenseButton btn(String key, String label, VoidCallback? f, {bool primary = false}) => SenseButton(
        key: Key('sense-connect-$key'),
        label: label,
        onPressed: f,
        kind: primary ? SenseButtonKind.primary : SenseButtonKind.normal);
    final close = btn('close', SenseConnectStrings.close, _c.close);
    final retry = btn('retry', SenseConnectStrings.retry, _c.retryNow, primary: true);
    List<Widget> buttons = const [];
    final what = switch (_c.kind) {
      SenseConnectKind.screen => name,
      SenseConnectKind.file => '${SenseConnectStrings.kindFile} · $name',
      SenseConnectKind.terminal => '${SenseConnectStrings.kindTerminal} · $name',
      SenseConnectKind.tunnel => '${SenseConnectStrings.kindTunnel} · $name',
      SenseConnectKind.camera => '${SenseConnectStrings.kindCamera} · $name',
    };

    switch (card) {
      case SenseConnectCard.connecting:
      case SenseConnectCard.waitingAccept:
        children
          ..add(title(SenseConnectStrings.connectingTitle, SenseColors.text))
          ..add(sub(what))
          ..add(_Steps(step: _c.step, accept: card == SenseConnectCard.waitingAccept));
        buttons = [btn('cancel', SenseConnectStrings.cancel, _c.close)];
      case SenseConnectCard.busy:
        final since = _c.busy?.since;
        final held = since == null ? null : _c.now().millisecondsSinceEpoch ~/ 1000 - since;
        final minutes = held == null ? null : (held < 0 ? 0 : held) ~/ 60;
        children
          ..add(title(SenseConnectStrings.busyTitle, SenseColors.warn))
          ..add(sub(SenseConnectStrings.busyBodyDetail(name, by: _c.busy?.by, minutes: minutes)))
          ..add(hint(SenseConnectStrings.busyHint));
        buttons = [btn('later', SenseConnectStrings.later, _c.close), retry];
      case SenseConnectCard.offline:
      case SenseConnectCard.notFound:
        children
          ..add(title(SenseConnectStrings.offlineTitle, SenseColors.warn))
          ..add(sub(card == SenseConnectCard.offline ? _offlineBody() : SenseConnectStrings.notFoundBody));
        buttons = [close, retry];
      case SenseConnectCard.password:
      case SenseConnectCard.passwordWrong:
        final wrongPw = card == SenseConnectCard.passwordWrong;
        children
          ..add(title(wrongPw ? SenseConnectStrings.passwordWrongTitle : SenseConnectStrings.passwordTitle,
              wrongPw ? SenseColors.dangerText : SenseColors.text))
          ..add(sub(wrongPw ? SenseConnectStrings.passwordWrongBody(name) : SenseConnectStrings.passwordBody(name)))
          ..add(SenseDialogField(
              key: const Key('sense-connect-field'),
              controller: _field,
              hint: SenseConnectStrings.passwordHint,
              obscure: true,
              autofocus: true,
              error: wrongPw,
              onSubmitted: (_) => _submitPassword()));
        if (wrongPw) children.add(errLine(SenseConnectStrings.passwordWrongLine));
        children.add(Align(
          alignment: Alignment.centerLeft,
          child: SenseDialogCheck(
              key: const Key('sense-connect-remember'),
              label: SenseConnectStrings.rememberPassword,
              value: _c.remember,
              onChanged: _c.setRemember),
        ));
        buttons = [
          btn('give-up', SenseConnectStrings.giveUp, _c.close),
          btn('connect', SenseConnectStrings.connect, _submitPassword, primary: true),
        ];
      case SenseConnectCard.otp:
      case SenseConnectCard.otpWrong:
        final wrongCode = card == SenseConnectCard.otpWrong;
        children
          ..add(title(SenseConnectStrings.otpTitle, wrongCode ? SenseColors.dangerText : SenseColors.text))
          ..add(sub(SenseConnectStrings.otpBody))
          ..add(SenseDialogField(
              key: const Key('sense-connect-field'),
              controller: _field,
              hint: SenseConnectStrings.otpHint,
              autofocus: true,
              error: wrongCode,
              maxLength: 7,
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _submitCode()));
        if (wrongCode) children.add(errLine(SenseConnectStrings.otpWrongLine));
        if (_c.host.trustAvailable) {
          children.add(Align(
            alignment: Alignment.centerLeft,
            child: SenseDialogCheck(
                key: const Key('sense-connect-trust'),
                label: SenseConnectStrings.trustDevice,
                value: _c.trust,
                onChanged: _c.setTrust),
          ));
        }
        buttons = [
          btn('give-up', SenseConnectStrings.giveUp, _c.close),
          btn('verify', SenseConnectStrings.verify, _submitCode, primary: true),
        ];
      case SenseConnectCard.denied:
        children
          ..add(title(SenseConnectStrings.deniedTitle, SenseColors.dangerText))
          ..add(sub(SenseConnectStrings.deniedBody));
        buttons = [close, retry];
      case SenseConnectCard.noPermission:
        children
          ..add(title(SenseConnectStrings.noPermissionTitle, SenseColors.dangerText))
          ..add(sub(SenseConnectStrings.noPermissionBody));
        buttons = [close];
      case SenseConnectCard.timeout:
        children
          ..add(title(SenseConnectStrings.timeoutTitle, SenseColors.dangerText))
          ..add(sub(SenseConnectStrings.timeoutBody(name)));
        buttons = [close, retry];
      case SenseConnectCard.network:
        children
          ..add(title(SenseConnectStrings.networkTitle, SenseColors.dangerText))
          ..add(sub(SenseConnectStrings.networkBody));
        buttons = [close, retry];
      case SenseConnectCard.failed:
        children
          ..add(title(SenseConnectStrings.failedTitle, SenseColors.dangerText))
          ..add(sub(SenseConnectStrings.failedBody));
        buttons = [close, retry];
    }
    final retryIn = _c.retryIn;
    if (retryIn != null) children.add(hint(SenseConnectStrings.retryIn(retryIn)));

    final breathe = card == SenseConnectCard.connecting || card == SenseConnectCard.waitingAccept;
    const mark = Padding(
      padding: EdgeInsets.only(bottom: SenseLayerLook.logoGap),
      child: SenseMark(width: SenseLayerLook.logoWidth, height: SenseLayerLook.logoHeight),
    );
    return SenseLayerVeil(
      blur: SenseLayerLook.weakBlur,
      brightness: SenseLayerLook.weakBrightness,
      appear: widget.appear,
      child: SenseLayerCard(children: [
        breathe ? SenseBreathe(spec: SenseMotion.breathe, child: mark) : mark,
        SizedBox(
          width: SenseConnectLook.innerWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: SenseLayerLook.cardGap),
                children[i],
              ],
              Padding(
                padding: const EdgeInsets.only(top: SenseConnectLook.buttonsTop),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: SenseConnectLook.buttonGap,
                  runSpacing: SenseConnectLook.buttonGap,
                  children: buttons,
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// The three steps of "Bağlanılıyor" (`.csteps`): done ✓ green, current spinner white, next dot.
class _Steps extends StatelessWidget {
  const _Steps({required this.step, required this.accept});

  final int step;

  /// The second step waits for the person at the Host.
  final bool accept;

  @override
  Widget build(BuildContext context) {
    final labels = [
      SenseConnectStrings.stepFind,
      accept ? SenseConnectStrings.stepAccept : SenseConnectStrings.stepLink,
      SenseConnectStrings.stepImage,
    ];
    final int current = accept && step < 1 ? 1 : (step < 0 ? 0 : (step > 2 ? 2 : step));
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < labels.length; i++) ...[
              if (i > 0) const SizedBox(height: SenseConnectLook.stepGap),
              Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: SenseConnectLook.stepMark,
                  height: SenseConnectLook.stepMark,
                  child: Center(
                    child: i < current
                        ? const SenseGlyph(SenseGlyphKind.check, size: SenseFontSize.hint, color: SenseColors.ok)
                        : i == current
                            ? const SenseSpinner(size: SenseConnectLook.stepMark - 2)
                            : Text('·', style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textDim)),
                  ),
                ),
                const SizedBox(width: 8),
                Text(labels[i],
                    key: Key('sense-connect-step-$i'),
                    style: SenseTextStyles.of(
                        size: SenseFontSize.bodySmall,
                        color: i < current
                            ? SenseColors.ok
                            : i == current
                                ? SenseColors.text
                                : SenseColors.textDim)),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}
