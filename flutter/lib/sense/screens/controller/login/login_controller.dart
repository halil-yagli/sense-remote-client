// Sense Remote: Controller sign-in with the Sense account (YH C1, #32, #35).
// Same flow as the setup wizard and the stock OIDC login: the browser opens
// the panel's Google sign-in, the panel and this window show the same pairing
// code, the person approves (two-step on the panel side). The token stays in
// Rust (`main_account_auth*`); Dart only sees the state, the URL and the code.
// No window: every step is on the sign-in page.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../../../../common.dart' show gFFI;
import '../../../../models/platform_model.dart' show bind;
import '../../../../models/user_model.dart' show UserModel;

enum SenseLoginStage { idle, starting, waiting, failed, done }

/// Why the last attempt stopped.
enum SenseLoginError { noProvider, failed }

abstract class SenseLoginBackend {
  /// The OIDC provider to use ("google" when the panel offers it); null when
  /// the panel could not be reached or offers none.
  Future<String?> provider();
  Future<void> start(String op);

  /// `main_account_auth_result`: `{state_msg, failed_msg, url, url_launched,
  /// pairing_code, auth_body}`.
  Future<String> result();
  Future<void> cancel();

  /// Signs the app in with the answer (user model, lists).
  Future<bool> complete(Map<String, dynamic> authBody);
  Future<void> openUrl(String url);
  Future<void> copy(String text);
}

class SenseLoginBridge implements SenseLoginBackend {
  const SenseLoginBridge();

  @override
  Future<String?> provider() async {
    try {
      final ops = await UserModel.queryOidcLoginOptions();
      final names = [
        for (final o in ops)
          if (o is Map && o['name'] is String) o['name'] as String,
      ];
      if (names.isEmpty) return null;
      return names.firstWhere((n) => n.toLowerCase() == 'google', orElse: () => names.first);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> start(String op) async {
    await bind.mainAccountAuthCancel();
    await bind.mainAccountAuth(op: op, rememberMe: true);
  }

  @override
  Future<String> result() => bind.mainAccountAuthResult();

  @override
  Future<void> cancel() => bind.mainAccountAuthCancel();

  @override
  Future<bool> complete(Map<String, dynamic> authBody) async {
    try {
      // The access token is already stored on the Rust side; this reads the
      // user and keeps it (same as the stock login dialog).
      final resp = gFFI.userModel.getLoginResponseFromAuthBody(authBody);
      if (resp.access_token == null) return false;
      unawaited(UserModel.updateOtherModels());
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      debugPrint('Sense Remote: the sign-in page could not be opened');
    }
  }

  @override
  Future<void> copy(String text) => Clipboard.setData(ClipboardData(text: text));
}

class SenseLoginController extends ChangeNotifier {
  SenseLoginController(this.backend, {this.interval = const Duration(seconds: 1)});

  final SenseLoginBackend backend;
  final Duration interval;

  SenseLoginStage _stage = SenseLoginStage.idle;
  SenseLoginError? _error;
  String _code = '';
  String _url = '';
  Timer? _timer;
  int _attempt = 0;
  bool _polling = false;
  bool _disposed = false;

  SenseLoginStage get stage => _stage;
  SenseLoginError? get error => _error;
  String get code => _code;
  String get url => _url;
  bool get busy => _stage == SenseLoginStage.starting || _stage == SenseLoginStage.waiting;

  void _set(void Function() f) {
    if (_disposed) return;
    f();
    notifyListeners();
  }

  Future<void> start() async {
    if (busy) return;
    final attempt = ++_attempt;
    _set(() {
      _stage = SenseLoginStage.starting;
      _error = null;
      _code = '';
      _url = '';
    });
    final op = await backend.provider();
    if (attempt != _attempt || _disposed) return;
    if (op == null) {
      _set(() {
        _stage = SenseLoginStage.failed;
        _error = SenseLoginError.noProvider;
      });
      return;
    }
    try {
      await backend.start(op);
    } catch (_) {
      _fail(attempt);
      return;
    }
    if (attempt != _attempt || _disposed) return;
    _set(() => _stage = SenseLoginStage.waiting);
    _timer?.cancel();
    unawaited(_poll(attempt));
    _timer = Timer.periodic(interval, (_) => unawaited(_poll(attempt)));
  }

  void _fail(int attempt) {
    if (attempt != _attempt) return;
    _timer?.cancel();
    _set(() {
      _stage = SenseLoginStage.failed;
      _error = SenseLoginError.failed;
      _code = '';
    });
  }

  Future<void> _poll(int attempt) async {
    if (_polling || attempt != _attempt || _stage != SenseLoginStage.waiting) return;
    _polling = true;
    try {
      final raw = await backend.result();
      if (attempt != _attempt || _disposed || raw.isEmpty) return;
      final v = jsonDecode(raw);
      if (v is! Map) return;
      final body = v['auth_body'];
      if (body is Map) {
        _timer?.cancel();
        final ok = await backend.complete(Map<String, dynamic>.from(body));
        if (attempt != _attempt || _disposed) return;
        if (!ok) return _fail(attempt);
        _set(() {
          _stage = SenseLoginStage.done;
          _code = '';
        });
        return;
      }
      final failed = v['failed_msg'];
      if (failed is String && failed.isNotEmpty) return _fail(attempt);
      final url = v['url'] is String ? v['url'] as String : '';
      final code = v['pairing_code'] is String ? v['pairing_code'] as String : '';
      final launched = v['url_launched'] == true;
      final newUrl = _url.isEmpty && url.isNotEmpty;
      if (newUrl || code != _code) {
        _set(() {
          if (newUrl) _url = url;
          _code = code;
        });
      }
      if (newUrl && !launched) unawaited(backend.openUrl(url));
    } catch (_) {
      _fail(attempt);
    } finally {
      _polling = false;
    }
  }

  /// Vazgeç: stops the attempt here and on the Rust side.
  Future<void> cancel() async {
    _attempt++;
    _timer?.cancel();
    _set(() {
      _stage = SenseLoginStage.idle;
      _error = null;
      _code = '';
      _url = '';
    });
    try {
      await backend.cancel();
    } catch (_) {}
  }

  Future<void> copyLink() async {
    if (_url.isNotEmpty) await backend.copy(_url);
  }

  @override
  void dispose() {
    _disposed = true;
    _attempt++;
    _timer?.cancel();
    if (_stage == SenseLoginStage.waiting || _stage == SenseLoginStage.starting) {
      unawaited(backend.cancel().catchError((_) {}));
    }
    super.dispose();
  }
}
