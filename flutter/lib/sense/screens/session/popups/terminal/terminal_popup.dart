// Sense Remote (Sürüm 12, FO-A5, #157): the session's terminal popup (Eylemler › Gelişmiş).
// Prototype `termHTML` (st 'ask'): the in-place second step of the admin terminal in the
// locked popup layout — live line "Henüz açılmadı", status box "Yönetici yetkisiyle açılacak"
// (Bilgisayar · Yetki · Denetim kaydı), the "Dikkat" category and Vazgeç / Yönetici olarak aç.
//
// The terminal itself opens in the Sense terminal window (screens/terminal/): with
// [senseRequestAdminTerminal] that window asks the panel ticket before it opens the terminal
// (no Windows password). A normal terminal ([admin] false) opens straight away, no popup.
//
// Plan §2.5: `senseShowTerminalPopup(BuildContext, {required bool admin})`; the session part
// (OT) also passes the computer and the opener (its normal "terminal" connect).
import 'package:flutter/widgets.dart';

import '../../../../sense.dart';
import '../../../../strings/terminal.dart';
import '../../../terminal/terminal_admin.dart';
import '../status/status_model.dart';
import '../status/status_widgets.dart';

/// Opens the terminal of this session's computer. [admin]: the popup's second step first.
/// [onOpen] connects the terminal window (normal terminal connect of the session);
/// [peerId] is the computer's id (only handed to the terminal window, never shown).
void senseShowTerminalPopup(
  BuildContext context, {
  required bool admin,
  String computer = '',
  String? peerId,
  VoidCallback? onOpen,
}) {
  if (!admin) {
    onOpen?.call();
    return;
  }
  final controller = SensePopupHost.maybeOf(context);
  void go() {
    if (peerId != null && peerId.isNotEmpty) senseRequestAdminTerminal(peerId);
    onOpen?.call();
  }

  if (controller == null) {
    // No popup host here: the terminal window asks in place instead.
    onOpen?.call();
    return;
  }
  controller.open(
    SenseTerminalStrings.popupId,
    (_) => SenseTerminalPopup(
      computer: computer,
      onClose: () => controller.close(SenseTerminalStrings.popupId),
      onOpenAdmin: () {
        controller.close(SenseTerminalStrings.popupId);
        go();
      },
    ),
  );
}

class SenseTerminalPopup extends StatefulWidget {
  const SenseTerminalPopup({
    super.key,
    required this.computer,
    required this.onClose,
    required this.onOpenAdmin,
  });

  final String computer;
  final VoidCallback onClose;
  final VoidCallback onOpenAdmin;

  @override
  State<SenseTerminalPopup> createState() => _SenseTerminalPopupState();
}

class _SenseTerminalPopupState extends State<SenseTerminalPopup> {
  bool _minimized = false;
  String? _open = 'attention';

  @override
  Widget build(BuildContext context) {
    final computer = widget.computer.isEmpty ? SenseTerminalStrings.rowComputer : widget.computer;
    return SensePopupShell(
      title: SenseTerminalStrings.title,
      minimized: _minimized,
      onMinimizedChanged: (v) => setState(() => _minimized = v),
      onClose: widget.onClose,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SenseLiveLine(
              key: Key('sense-term-popup-live'), text: SenseTerminalStrings.notOpenYet, level: SenseLevel.unknown),
          SenseStatusBox(
            level: SenseLevel.warn,
            title: SenseTerminalStrings.adminWillOpen,
            children: senseRowViews([
              SenseStatusLine(SenseTerminalStrings.rowComputer, computer),
              const SenseStatusLine(SenseTerminalStrings.rowRights, SenseTerminalStrings.adminWindows),
              const SenseStatusLine(SenseTerminalStrings.rowAudit, SenseTerminalStrings.auditAdmin),
            ]),
          ),
          SenseAccordion(
            openId: _open,
            onChanged: (id) => setState(() => _open = id),
            items: [
              SenseAccordionItem(
                id: 'attention',
                title: SenseTerminalStrings.attention,
                summary: SenseTerminalStrings.attentionSummary,
                level: SenseLevel.warn,
                builder: (context) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: senseRowViews(const [
                    SenseStatusNote(SenseTerminalStrings.attentionNote),
                    SenseStatusLine(SenseTerminalStrings.whoCan, SenseTerminalStrings.whoCanValue),
                    SenseStatusLine(SenseTerminalStrings.inPanel, SenseTerminalStrings.inPanelValue),
                  ]),
                ),
              ),
            ],
          ),
          const SenseHintView(text: SenseTerminalStrings.popupHint),
        ],
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(children: [
          SenseButton(
            key: const Key('sense-term-popup-cancel'),
            label: SenseTerminalStrings.cancel,
            onPressed: widget.onClose,
          ),
          const Spacer(),
          SenseButton(
            key: const Key('sense-term-popup-go'),
            label: SenseTerminalStrings.openAdmin,
            kind: SenseButtonKind.primary,
            onPressed: widget.onOpenAdmin,
          ),
        ]),
      ),
    );
  }
}
