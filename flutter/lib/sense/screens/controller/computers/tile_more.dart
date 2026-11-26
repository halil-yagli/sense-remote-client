// Sense Remote: "⋯" menu of a computer tile (R6): open the computer for
// "Dosya aktarımı", "Terminal" or "TCP tünel" without opening its screen. Each
// entry is shown only when the person's grants allow it (plan §2.4; the panel
// is the real protection). The small menu is anchored to the button, like the
// LED box; a tap outside closes it.
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/controller.dart';

/// How a computer is opened.
enum SenseConnectKind { screen, fileTransfer, terminal, tcpTunnel }

/// The entries of the menu, in order, for the allowed kinds.
List<SenseConnectKind> senseMoreKinds({required bool fileTransfer, required bool terminalTunnel}) => [
      if (fileTransfer) SenseConnectKind.fileTransfer,
      if (terminalTunnel) SenseConnectKind.terminal,
      if (terminalTunnel) SenseConnectKind.tcpTunnel,
    ];

String senseConnectKindLabel(SenseConnectKind k) => switch (k) {
      SenseConnectKind.screen => SenseControllerStrings.connect,
      SenseConnectKind.fileTransfer => SenseControllerStrings.openFileTransfer,
      SenseConnectKind.terminal => SenseControllerStrings.openTerminal,
      SenseConnectKind.tcpTunnel => SenseControllerStrings.openTcpTunnel,
    };

const double _kButton = 26, _kMenuWidth = 168, _kMenuGap = 6, _kItemV = 8, _kItemH = 11, _kPad = 4;

class SenseTileMore extends StatefulWidget {
  const SenseTileMore({super.key, required this.computerId, required this.kinds, required this.onPick, this.initiallyOpen = false});

  final String computerId;
  final List<SenseConnectKind> kinds;
  final ValueChanged<SenseConnectKind> onPick;

  /// Goldens and tests: the menu shown without a pointer.
  final bool initiallyOpen;

  @override
  State<SenseTileMore> createState() => _SenseTileMoreState();
}

class _SenseTileMoreState extends State<SenseTileMore> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();

  @override
  void initState() {
    super.initState();
    if (widget.initiallyOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _portal.show();
      });
    }
  }

  void _toggle() {
    _portal.isShowing ? _portal.hide() : _portal.show();
    setState(() {});
  }

  void _pick(SenseConnectKind k) {
    _portal.hide();
    setState(() {});
    widget.onPick(k);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.computerId;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: (_) => Stack(children: [
          // A tap anywhere else closes the menu.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                _portal.hide();
                if (mounted) setState(() {});
              },
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.topRight,
              offset: const Offset(0, _kMenuGap),
              child: Container(
                key: Key('sense-tile-more-menu-$id'),
                width: _kMenuWidth,
                padding: const EdgeInsets.all(_kPad),
                decoration: BoxDecoration(
                  color: SenseColors.surface,
                  border: Border.all(color: SenseColors.line),
                  borderRadius: BorderRadius.circular(SenseRadii.categoryLarge + 1),
                  boxShadow: [BoxShadow(color: SenseColors.bg.withOpacity(0.7), blurRadius: 30, offset: const Offset(0, 10))],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final k in widget.kinds)
                      SenseInteractive(
                        key: Key('sense-tile-more-${k.name}-$id'),
                        onTap: () => _pick(k),
                        builder: (context, s) => Container(
                          padding: const EdgeInsets.symmetric(vertical: _kItemV, horizontal: _kItemH),
                          decoration: BoxDecoration(
                            color: s.hovered || s.focused ? SenseColors.hover : null,
                            borderRadius: BorderRadius.circular(SenseRadii.popup),
                          ),
                          child: Text(senseConnectKindLabel(k),
                              style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.text)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ]),
        child: SenseInteractive(
          key: Key('sense-tile-more-$id'),
          onTap: _toggle,
          semanticLabel: SenseControllerStrings.moreConnect,
          tooltip: SenseControllerStrings.moreConnect,
          builder: (context, s) => Container(
            width: _kButton,
            height: _kButton,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: s.hovered || _portal.isShowing ? SenseColors.hover : null,
              border: Border.all(color: s.focused ? SenseColors.text : SenseColors.line),
              borderRadius: BorderRadius.circular(SenseRadii.popup),
            ),
            child: Icon(Icons.more_horiz_rounded,
                size: 16, color: s.hovered || _portal.isShowing ? SenseColors.text : SenseColors.textMuted),
          ),
        ),
      ),
    );
  }
}
