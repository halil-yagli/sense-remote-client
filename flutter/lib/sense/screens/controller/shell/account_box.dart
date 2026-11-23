// Sense Remote: the person at the bottom of the Controller menu (YH C1;
// prototype `.ame`, `.aname`, `.acctpop`; image a06). Only the name and the
// "Sürüm N" chip (no avatar, no e-mail). A click on the name opens a box above
// it: the e-mail (faded) and a red "Çıkış yap"; that turns, in the same box,
// into "Çıkış yapılsın mı? Açık bağlantı yok." Vazgeç / Çıkış yap. A click
// outside closes the box. Signing out removes the session from this computer.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../common.dart' show getHttpHeaders, gFFI;
import '../../../../models/platform_model.dart' show bind;
import '../../../../utils/http_service.dart' as http;
import '../../../../utils/multi_window_manager.dart' show rustDeskWinManager;
import '../../../sense.dart';
import '../../../strings/controller.dart';

// Prototype `.acctpop`: padding 8, gap 6, corner 11, 6 px above the name;
// `.ap-h` 2×4; `.ap-it` 7×8, corner 7; `.aname` 4×6, corner 7.
const double _kPad = 8, _kGap = 6, _kRadius = 11, _kHeadPadV = 2, _kHeadPadH = 4;
const double _kItemPadV = 7, _kItemPadH = 8, _kItemRadius = 7, _kNamePadV = 4, _kNamePadH = 6;
const double _kShadow = 50, _kShadowY = 18;
// `.ame` 10/8/2.
const double _kMeTop = 10, _kMeSide = 8, _kMeBottom = 2;

/// Sign out and open connections of this app.
abstract class SenseAccountBackend {
  /// Open session windows (remote, file transfer…).
  Future<int> openConnections();

  /// `POST /api/logout`, then the stored token and user are removed.
  Future<void> signOut();
}

class SenseAccountBridge implements SenseAccountBackend {
  const SenseAccountBridge();

  @override
  Future<int> openConnections() async {
    try {
      return (await rustDeskWinManager.getAllSubWindowIds()).length;
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      final url = await bind.mainGetApiServer();
      final headers = getHttpHeaders();
      headers['Content-Type'] = 'application/json';
      await http
          .post(Uri.parse('$url/api/logout'),
              body: jsonEncode({'id': await bind.mainGetMyId(), 'uuid': await bind.mainGetUuid()}), headers: headers)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // The session is removed here whatever the panel answered.
    } finally {
      await gFFI.userModel.reset(resetOther: true);
      // The token is gone now: the core deletes this person's grants (grants.json).
      try {
        await bind.mainSenseGrantsRefresh();
      } catch (_) {}
    }
  }
}

/// Name button + box. Pure apart from [onSignOut].
class SenseAccountBox extends StatefulWidget {
  const SenseAccountBox({
    super.key,
    required this.name,
    required this.email,
    required this.onSignOut,
    this.openConnections,
    this.initiallyOpen = false,
    this.initiallyAsking = false,
    this.trailing,
  });

  final String name;
  final String email;
  final VoidCallback onSignOut;

  /// Asked when the box opens; null = none.
  final Future<int> Function()? openConnections;

  /// Goldens.
  final bool initiallyOpen;
  final bool initiallyAsking;

  /// Right of the name ("Sürüm N" chip).
  final Widget? trailing;

  @override
  State<SenseAccountBox> createState() => _SenseAccountBoxState();
}

class _SenseAccountBoxState extends State<SenseAccountBox> {
  final Object _region = Object();
  late bool _open = widget.initiallyOpen;
  late bool _asking = widget.initiallyAsking;
  int _connections = 0;

  void _toggle() {
    setState(() {
      _open = !_open;
      _asking = false;
    });
    if (_open && widget.openConnections != null) {
      unawaited(widget.openConnections!().then((n) {
        if (mounted) setState(() => _connections = n);
      }));
    }
  }

  void _close() {
    if (_open) setState(() {
      _open = false;
      _asking = false;
    });
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Above the line of the footer, like the prototype's floating box.
            if (_open)
              TapRegion(
                groupId: _region,
                onTapOutside: (_) => _close(),
                child: Padding(padding: const EdgeInsets.only(bottom: _kGap), child: _box()),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(_kMeSide, _kMeTop, _kMeSide, _kMeBottom),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: SenseColors.line))),
              child: Row(children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TapRegion(groupId: _region, child: _nameButton()),
                  ),
                ),
                if (widget.trailing != null) widget.trailing!,
              ]),
            ),
          ],
        ),
      );

  Widget _nameButton() => SenseInteractive(
        key: const Key('sense-account-name'),
        onTap: _toggle,
        semanticLabel: widget.name,
        builder: (_, s) => SenseFocusRing(
          visible: s.focused,
          radius: _kItemRadius,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: _kNamePadV, horizontal: _kNamePadH),
            decoration: BoxDecoration(
              color: s.hovered || _open ? SenseColors.hover : null,
              borderRadius: BorderRadius.circular(_kItemRadius),
            ),
            child: Text(widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SenseTextStyles.of(weight: SenseFontWeight.medium)),
          ),
        ),
      );

  Widget _box() => SensePopupEnter(
        from: SensePopupFrom.bottom,
        child: Container(
          key: const Key('sense-account-box'),
          padding: const EdgeInsets.all(_kPad),
          decoration: BoxDecoration(
            color: SenseColors.surface,
            border: Border.all(color: SenseColors.line),
            borderRadius: BorderRadius.circular(_kRadius),
            boxShadow: [
              BoxShadow(color: SenseColors.bg.withOpacity(0.7), blurRadius: _kShadow, offset: const Offset(0, _kShadowY)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: _kHeadPadV, horizontal: _kHeadPadH),
                child: Text(widget.email,
                    key: const Key('sense-account-email'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted)),
              ),
              const SizedBox(height: _kGap),
              if (_asking)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _kHeadPadH),
                  child: SenseConfirmStrip(
                    question: _connections > 0
                        ? SenseControllerStrings.signOutQuestionBusy
                        : SenseControllerStrings.signOutQuestionIdle,
                    confirmLabel: SenseControllerStrings.signOut,
                    onCancel: () => setState(() => _asking = false),
                    onConfirm: () {
                      _close();
                      widget.onSignOut();
                    },
                  ),
                )
              else
                SenseInteractive(
                  key: const Key('sense-account-signout'),
                  onTap: () => setState(() => _asking = true),
                  builder: (_, s) => SenseFocusRing(
                    visible: s.focused,
                    radius: _kItemRadius,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: _kItemPadV, horizontal: _kItemPadH),
                      decoration: BoxDecoration(
                        color: s.hovered ? SenseColors.hover : null,
                        borderRadius: BorderRadius.circular(_kItemRadius),
                      ),
                      child: Text(SenseControllerStrings.signOut,
                          style: SenseTextStyles.of(
                              size: SenseFontSize.bodySmall,
                              weight: SenseFontWeight.medium,
                              color: SenseColors.dangerTextSoft)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}
