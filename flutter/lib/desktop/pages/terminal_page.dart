import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/terminal_model.dart';
import 'package:flutter_hbb/models/terminal_mouse_handler.dart';
import 'terminal_connection_manager.dart';
import '../../models/platform_model.dart';
import '../../consts.dart' show kPeerPlatformWindows;
import '../../sense/screens/session/layers/connect_cards.dart'
    show SenseConnectCards, SenseConnectKind;
import '../../sense/screens/session/layers/data/session_bridge.dart'
    show SenseFfiConnectHost;
import '../../sense/screens/shared/aux_window/aux_label.dart';
import '../../sense/screens/terminal/terminal_admin.dart';
import '../../sense/screens/terminal/terminal_view.dart';

class TerminalPage extends StatefulWidget {
  TerminalPage({
    Key? key,
    required this.id,
    required this.password,
    this.loginMethod = '',
    required this.tabController,
    required this.isSharedPassword,
    required this.terminalId,
    required this.tabKey,
    this.forceRelay,
    this.connToken,
    this.onClipboardWriteBlocked,
    this.onClipboardWriteSucceeded,
    this.senseAdmin = false,
    this.onSenseClose,
    this.onSenseReopen,
  }) : super(key: key);
  final String id;
  final String? password;
  final String loginMethod;
  final DesktopTabController tabController;
  final bool? forceRelay;
  final bool? isSharedPassword;
  final String? connToken;
  final ValueChanged<String>? onClipboardWriteBlocked;
  final ValueChanged<String>? onClipboardWriteSucceeded;
  final int terminalId;

  /// Sense Remote (Sürüm 12, #157): this terminal opens as the admin terminal (panel ticket,
  /// no Windows password). Only on a new connection.
  final bool senseAdmin;

  /// Sense Remote: "Terminali kapat" and the connecting card's "Kapat" (the tab's own close).
  final VoidCallback? onSenseClose;

  /// Sense Remote: open this computer's terminal again on a new connection, as the admin
  /// terminal, or ([stockAdmin]) with RustDesk's administrator sign-in box (fallback).
  final void Function({required bool stockAdmin})? onSenseReopen;

  /// Tab key for focus management, passed from parent to avoid duplicate construction
  final String tabKey;
  final SimpleWrapper<State<TerminalPage>?> _lastState = SimpleWrapper(null);

  FFI get ffi => (_lastState.value! as _TerminalPageState)._ffi;

  @override
  State<TerminalPage> createState() {
    final state = _TerminalPageState();
    _lastState.value = state;
    return state;
  }
}

class _TerminalPageState extends State<TerminalPage>
    with AutomaticKeepAliveClientMixin {
  static const EdgeInsets _defaultTerminalPadding =
      EdgeInsets.symmetric(horizontal: 5.0, vertical: 2.0);

  late FFI _ffi;
  late TerminalModel _terminalModel;
  double? _cellHeight;
  final FocusNode _terminalFocusNode = FocusNode(canRequestFocus: false);
  StreamSubscription<DesktopTabState>? _tabStateSubscription;

  // Sense Remote (Sürüm 12): the Sense terminal window (ST 4, #157).
  late final bool _senseOn = senseAuxFrameOn();

  /// This page started the connection: it carries the connecting cards (#164).
  bool _ownsConnection = false;
  SenseTermAdminController? _admin;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _ownsConnection = !TerminalConnectionManager.hasConnection(widget.id);

    // Listen for tab selection changes to request focus
    _tabStateSubscription = widget.tabController.state.listen(_onTabStateChanged);

    // Use shared FFI instance from connection manager
    _ffi = TerminalConnectionManager.getConnection(
      peerId: widget.id,
      password: widget.password,
      loginMethod: widget.loginMethod,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
      connToken: widget.connToken,
    );

    // Create terminal model with specific terminal ID
    _terminalModel = TerminalModel(_ffi, widget.terminalId);
    _terminalModel.onClipboardWriteBlocked = widget.onClipboardWriteBlocked;
    _terminalModel.onClipboardWriteSucceeded = widget.onClipboardWriteSucceeded;
    debugPrint(
        '[TerminalPage] Terminal model created for terminal ${widget.terminalId}');

    _terminalModel.onResizeExternal = (w, h, pw, ph) {
      _cellHeight = ph * 1.0;

      // Enable focus once terminal has valid dimensions (first valid resize)
      if (!_terminalFocusNode.canRequestFocus && w > 0 && h > 0) {
        _terminalFocusNode.canRequestFocus = true;
        // Auto-focus if this tab is currently selected
        _requestFocusIfSelected();
      }

      // Schedule the setState for the next frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
    };

    // Register this terminal model with FFI for event routing
    _ffi.registerTerminalModel(widget.terminalId, _terminalModel);

    // Sense Remote (#157): the admin ticket goes before `TerminalAction::Open`.
    if (_senseOn && widget.senseAdmin && _ownsConnection) {
      _admin = SenseTermAdminController(
        peerId: widget.id,
        begin: () =>
            bind.sessionSenseTermAdminBegin(sessionId: _ffi.sessionId),
      );
      _terminalModel.senseBeforeOpen = _admin!.run;
    }

    // Auto-close tab when shell exits
    _terminalModel.onClosed = () {
      if (mounted) {
        widget.tabController.closeBy(widget.tabKey);
      }
    };

    // Initialize terminal connection
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.tabController.onSelected?.call(widget.id);

      // Check if this is a new connection or additional terminal
      // Note: When a connection exists, the ref count will be > 1 after this terminal is added
      final isExistingConnection =
          TerminalConnectionManager.hasConnection(widget.id) &&
              TerminalConnectionManager.getTerminalCount(widget.id) > 1;

      if (!isExistingConnection) {
        // First terminal - show loading dialog, wait for onReady
        // Sense Remote (#164): the Sense connecting card says "Bağlanılıyor" instead.
        if (!_senseOn) {
          _ffi.dialogManager.showLoading(translate('Connecting...'),
              onCancel: closeConnection);
        }
      } else {
        // Additional terminal - connection already established
        // Open the terminal directly
        _terminalModel.openTerminal();
      }
    });
  }

  @override
  void dispose() {
    // Cancel tab state subscription to prevent memory leak
    _tabStateSubscription?.cancel();
    // Unregister terminal model from FFI
    _ffi.unregisterTerminalModel(widget.terminalId);
    _terminalModel.dispose();
    _terminalFocusNode.dispose();
    _admin?.dispose();
    // Release connection reference instead of closing directly
    TerminalConnectionManager.releaseConnection(widget.id);
    // Sense Remote: the connection is gone: no admin chip, no card controller.
    if (_senseOn && !TerminalConnectionManager.hasConnection(widget.id)) {
      SenseTermAdminEvents.setGranted(widget.id, false);
      SenseConnectCards.remove(widget.id);
    }
    super.dispose();
  }

  // ---- Sense Remote (Sürüm 12, #157): admin choices of the tab ----

  void _openNormal() {
    _terminalModel.senseBeforeOpen = null;
    _admin?.reset();
    _terminalModel.openTerminal().catchError((e) {
      debugPrint('[TerminalPage] Error opening terminal: $e');
    });
  }

  void _retryAdmin() {
    final a = _admin;
    if (a == null || a.busy) return;
    a.run().then((ok) {
      if (!ok || !mounted) return;
      _terminalModel.senseBeforeOpen = null;
      _terminalModel.openTerminal().catchError((e) {
        debugPrint('[TerminalPage] Error opening terminal: $e');
      });
    });
  }

  bool get _adminPossible {
    final p = _ffi.ffiModel.pi.platform;
    return p.isEmpty || p == kPeerPlatformWindows;
  }

  void _onTabStateChanged(DesktopTabState state) {
    // Check if this tab is now selected and request focus
    if (state.selected >= 0 && state.selected < state.tabs.length) {
      final selectedTab = state.tabs[state.selected];
      if (selectedTab.key == widget.tabKey && mounted) {
        _requestFocusIfSelected();
      }
    }
  }

  void _requestFocusIfSelected() {
    if (!mounted || !_terminalFocusNode.canRequestFocus) return;
    // Use post-frame callback to ensure widget is fully laid out in focus tree
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Re-check conditions after frame: mounted, focusable, still selected, not already focused
      if (!mounted || !_terminalFocusNode.canRequestFocus || _terminalFocusNode.hasFocus) return;
      final state = widget.tabController.state.value;
      if (state.selected >= 0 && state.selected < state.tabs.length) {
        if (state.tabs[state.selected].key == widget.tabKey) {
          _terminalFocusNode.requestFocus();
        }
      }
    });
  }

  // This method ensures that the number of visible rows is an integer by computing the
  // extra space left after dividing the available height by the height of a single
  // terminal row (`_cellHeight`) and distributing it evenly as top and bottom padding.
  EdgeInsets _calculatePadding(double heightPx) {
    final cellHeight = _cellHeight;
    if (!heightPx.isFinite ||
        heightPx <= 0 ||
        cellHeight == null ||
        !cellHeight.isFinite ||
        cellHeight <= 0) {
      return _defaultTerminalPadding;
    }
    final rows = (heightPx / cellHeight).floor();
    if (rows <= 0) {
      return _defaultTerminalPadding;
    }
    final extraSpace = heightPx - rows * cellHeight;
    if (!extraSpace.isFinite || extraSpace < 0) {
      return _defaultTerminalPadding;
    }
    final topBottom = extraSpace / 2.0;
    return EdgeInsets.symmetric(
      horizontal: _defaultTerminalPadding.horizontal / 2,
      vertical: topBottom,
    );
  }

  Widget _terminalView({required double backgroundOpacity}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final heightPx = constraints.maxHeight;
        return TerminalMouseInteraction(
          _terminalModel.terminal,
          controller: _terminalModel.terminalController,
          focusNode: _terminalFocusNode,
          // Note: autofocus is not used here because focus is managed manually
          // via _onTabStateChanged() to handle tab switching properly.
          backgroundOpacity: backgroundOpacity,
          padding: _calculatePadding(heightPx),
          onSecondaryTapDown: (details, offset) async {
            final selection = _terminalModel.terminalController.selection;
            if (selection != null) {
              final text = _terminalModel.terminal.buffer.getText(selection);
              _terminalModel.terminalController.clearSelection();
              await Clipboard.setData(ClipboardData(text: text));
            } else {
              final data = await Clipboard.getData('text/plain');
              final text = data?.text;
              if (text != null) {
                _terminalModel.terminal.paste(text);
              }
            }
          },
        );
      },
    );
  }

  /// Sense Remote (Sürüm 12, ST 4, #157): the Sense terminal tab (admin step, black box,
  /// footer) with the connecting cards over it (#164).
  Widget _senseBuild(BuildContext context) {
    final terminal = _terminalView(backgroundOpacity: 0);
    final reopen = widget.onSenseReopen;
    final body = ListenableBuilder(
      listenable: Listenable.merge([
        SenseTermAdminEvents.grantedOf(widget.id),
        if (_admin != null) _admin!,
      ]),
      builder: (context, _) => SenseTerminalBody(
        computer: senseAuxPeerLabel(widget.id),
        terminal: terminal,
        admin: SenseTermAdminEvents.isGranted(widget.id),
        adminView: senseTerminalAdminViewOf(_admin, asking: _asking),
        adminError: _admin?.error,
        onCopyOutput: () => _terminalModel.terminal.buffer.getText(),
        onAskAdmin: reopen == null || !_adminPossible
            ? null
            : () => setState(() => _asking = true),
        onCancelAsk: () => setState(() => _asking = false),
        onConfirmAdmin: () {
          setState(() => _asking = false);
          reopen?.call(stockAdmin: false);
        },
        onOpenNormal: _openNormal,
        onWindowsAccount:
            reopen == null ? null : () => reopen(stockAdmin: true),
        onRetryAdmin: _retryAdmin,
        onClose: widget.onSenseClose,
      ),
    );
    return Stack(children: [
      Positioned.fill(child: body),
      if (_ownsConnection)
        Positioned.fill(
          child: SenseConnectCards.attach(widget.id,
              kind: SenseConnectKind.terminal,
              host: SenseFfiConnectHost(widget.id, _ffi,
                  kind: SenseConnectKind.terminal,
                  onClose: widget.onSenseClose)),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Sense Remote (Sürüm 12, ST 4): the Sense tab; the stock one below stays the fallback.
    if (_senseOn) return _senseBuild(context);
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: _terminalView(backgroundOpacity: 1.0),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
