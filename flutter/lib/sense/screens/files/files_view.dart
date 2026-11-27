// Sense Remote (#155): the body of the remote files window, in the Sense frame
// (aux_window). Prototype "Uzak dosyalar": two panels (Bu bilgisayar | the remote
// computer), Gönder → / ← Al in the middle, transfers below. Selecting in one panel
// drops the other panel's selection; a row dragged to the other panel sends it.
// The stock FileController / JobController keep all data and actions (no Rust change).
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../models/file_model.dart';
import '../../sense.dart';
import '../../strings/files.dart';
import 'files_panel.dart';
import 'files_queue.dart';

const double _kMiddle = 112;

class SenseFilesView extends StatefulWidget {
  const SenseFilesView({
    super.key,
    required this.local,
    required this.remote,
    required this.jobs,
    required this.computer,
    required this.localOs,
    required this.remoteOs,
    this.connected = true,
    this.doubleClickMs = 300,
    this.wrapPanel,
  });

  final FileController local;
  final FileController remote;
  final JobController jobs;

  /// The remote computer's name (never its ID).
  final String computer;

  /// "Windows", "macOS".
  final String localOs;
  final String remoteOs;

  /// The remote side answered (PeerInfo set).
  final bool connected;
  final int doubleClickMs;

  /// Lets the page wrap a panel, e.g. in a drop target for files from the desktop.
  final Widget Function(Widget panel, bool isLocal)? wrapPanel;

  @override
  State<SenseFilesView> createState() => _SenseFilesViewState();
}

class _SenseFilesViewState extends State<SenseFilesView> {
  void _send() {
    final l = widget.local;
    if (l.selectedItems.items.isEmpty) return;
    l.sendFiles(l.selectedItems, widget.remote.directoryData());
    l.selectedItems.clear();
  }

  void _receive() {
    final r = widget.remote;
    if (r.selectedItems.items.isEmpty) return;
    r.sendFiles(r.selectedItems, widget.local.directoryData());
    r.selectedItems.clear();
  }

  Widget _panel({required bool isLocal}) {
    final panel = SenseFilesPanel(
      key: Key(isLocal ? 'sense-files-local' : 'sense-files-remote'),
      controller: isLocal ? widget.local : widget.remote,
      isRemote: !isLocal,
      title: isLocal ? SenseFilesStrings.thisComputer : widget.computer,
      tag: SenseFilesStrings.osTag(isLocal ? widget.localOs : widget.remoteOs, remote: !isLocal),
      connected: widget.connected,
      doubleClickMs: widget.doubleClickMs,
      windows: (isLocal ? widget.local : widget.remote).options.value.isWindows,
      onSelectionStart: () => (isLocal ? widget.remote : widget.local).selectedItems.clear(),
      onDropFromOther: isLocal ? _receive : _send,
    );
    return widget.wrapPanel?.call(panel, isLocal) ?? panel;
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: SenseColors.bg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _panel(isLocal: true)),
              SizedBox(
                width: _kMiddle,
                child: Obx(() {
                  final canSend = widget.connected && widget.local.selectedItems.items.isNotEmpty;
                  final canReceive = widget.connected && widget.remote.selectedItems.items.isNotEmpty;
                  return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SenseTransferButton(
                      key: const Key('sense-files-send'),
                      label: SenseFilesStrings.send,
                      toRight: true,
                      tooltip: SenseFilesStrings.sendTip(widget.computer),
                      onPressed: canSend ? _send : null,
                    ),
                    const SizedBox(height: 10),
                    SenseTransferButton(
                      key: const Key('sense-files-receive'),
                      label: SenseFilesStrings.receive,
                      toRight: false,
                      tooltip: SenseFilesStrings.receiveTip,
                      onPressed: canReceive ? _receive : null,
                    ),
                    const SizedBox(height: 10),
                    Text(SenseFilesStrings.dragHint,
                        textAlign: TextAlign.center,
                        style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim, height: 1.4)),
                  ]);
                }),
              ),
              Expanded(child: _panel(isLocal: false)),
            ]),
          ),
        ),
        SenseFilesQueue(jobs: widget.jobs, computer: widget.computer),
      ]),
    );
  }
}

/// Gönder → / ← Al (`.fmgo`): 92 × 40, white when there is a selection, faded otherwise.
class SenseTransferButton extends StatelessWidget {
  const SenseTransferButton(
      {super.key, required this.label, required this.toRight, required this.onPressed, this.tooltip});

  final String label;
  final bool toRight;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final on = onPressed != null;
    return SenseInteractive(
      onTap: onPressed,
      tooltip: tooltip,
      semanticLabel: label,
      builder: (context, s) {
        final bg = !on
            ? SenseColors.bg
            : s.hovered || s.pressed
                ? SenseColors.textSecondary
                : SenseColors.text;
        final fg = on ? SenseColors.bg : SenseColors.textDim;
        final arrow = Icon(toRight ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded, size: 14, color: fg);
        final text = Text(label,
            style: SenseTextStyles.of(size: SenseFontSize.body, weight: SenseFontWeight.bold, color: fg));
        return SenseFocusRing(
          visible: s.focused,
          radius: SenseRadii.categoryLarge,
          child: Container(
            width: 92,
            height: 40,
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(color: on ? SenseColors.text : SenseColors.line),
              borderRadius: BorderRadius.circular(SenseRadii.categoryLarge),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              if (!toRight) ...[arrow, const SizedBox(width: SenseUi.iconGap)],
              text,
              if (toRight) ...[const SizedBox(width: SenseUi.iconGap), arrow],
            ]),
          ),
        );
      },
    );
  }
}
