// Sense Remote (Sürüm 12, #157, ST 4–5): the body of one terminal tab in the Sense terminal
// window. Prototype `auxTerm`: in-place admin step (`.axask`), the black terminal box
// (`.axterm`, orange frame when it runs as admin) and the footer (`.axfoot`: rights badge,
// audit note, Çıktıyı kopyala · Yönetici olarak aç · Terminali kapat).
//
// A plain widget: the RustDesk terminal view comes in as [terminal], everything else as
// values and callbacks (goldens and tests draw it without a connection).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../sense.dart';
import '../../strings/terminal.dart';
import 'aux_parts.dart';
import 'terminal_admin.dart';

/// What the admin part of the tab shows.
enum SenseTerminalAdminView {
  /// Nothing (normal terminal, or admin granted).
  none,

  /// "Yönetici olarak açılsın mı?" (T7 second step).
  asking,

  /// Waiting for the panel ticket and the Host's answer.
  requesting,

  /// The request failed: [SenseTerminalBody.adminError] says why.
  failed,
}

/// Admin part of a tab from its controller (null = not an admin tab).
SenseTerminalAdminView senseTerminalAdminViewOf(SenseTermAdminController? c, {required bool asking}) {
  if (asking) return SenseTerminalAdminView.asking;
  return switch (c?.phase) {
    SenseTermAdminPhase.requesting => SenseTerminalAdminView.requesting,
    SenseTermAdminPhase.failed => SenseTerminalAdminView.failed,
    _ => SenseTerminalAdminView.none,
  };
}

class SenseTerminalBody extends StatefulWidget {
  const SenseTerminalBody({
    super.key,
    required this.computer,
    required this.terminal,
    this.admin = false,
    this.adminView = SenseTerminalAdminView.none,
    this.adminError,
    this.notice,
    this.onCopyOutput,
    this.onAskAdmin,
    this.onCancelAsk,
    this.onConfirmAdmin,
    this.onOpenNormal,
    this.onWindowsAccount,
    this.onRetryAdmin,
    this.onClose,
  });

  /// The computer's name (never its ID).
  final String computer;

  /// The terminal itself (RustDesk's xterm view, transparent background).
  final Widget terminal;

  /// The connection runs with admin rights.
  final bool admin;
  final SenseTerminalAdminView adminView;

  /// Error code when [adminView] is failed.
  final String? adminError;

  /// A strip above the terminal (clipboard notice).
  final Widget? notice;

  /// Returns the text to copy (whole buffer); null = nothing.
  final String? Function()? onCopyOutput;
  final VoidCallback? onAskAdmin;
  final VoidCallback? onCancelAsk;
  final VoidCallback? onConfirmAdmin;
  final VoidCallback? onOpenNormal;

  /// RustDesk's administrator sign-in box (only after `unsupported`).
  final VoidCallback? onWindowsAccount;
  final VoidCallback? onRetryAdmin;
  final VoidCallback? onClose;

  @override
  State<SenseTerminalBody> createState() => _SenseTerminalBodyState();
}

class _SenseTerminalBodyState extends State<SenseTerminalBody> {
  bool _copied = false;

  Future<void> _copy() async {
    final text = widget.onCopyOutput?.call();
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Widget? _adminStrip() {
    final w = widget;
    switch (w.adminView) {
      case SenseTerminalAdminView.none:
        return null;
      case SenseTerminalAdminView.asking:
        return SenseAuxStrip(
          key: const Key('sense-term-ask'),
          level: SenseLevel.warn,
          title: SenseTerminalStrings.askTitle,
          body: '${SenseTerminalStrings.askBody(w.computer)} ${SenseTerminalStrings.askReopenNote}',
          actions: [
            SenseButton(
              key: const Key('sense-term-ask-cancel'),
              label: SenseTerminalStrings.cancel,
              size: SenseButtonSize.small,
              onPressed: w.onCancelAsk,
            ),
            SenseButton(
              key: const Key('sense-term-ask-go'),
              label: SenseTerminalStrings.openAdmin,
              size: SenseButtonSize.small,
              kind: SenseButtonKind.danger,
              onPressed: w.onConfirmAdmin,
            ),
          ],
        );
      case SenseTerminalAdminView.requesting:
        return const SenseAuxStrip(
          key: Key('sense-term-requesting'),
          leading: SenseSpinner(size: 12),
          title: SenseTerminalStrings.requesting,
          body: SenseTerminalStrings.requestingBody,
        );
      case SenseTerminalAdminView.failed:
        final code = w.adminError ?? 'unknown';
        return SenseAuxStrip(
          key: const Key('sense-term-failed'),
          level: SenseLevel.warn,
          title: SenseTerminalStrings.failedTitle,
          body: SenseTerminalStrings.error(code),
          actions: [
            if (w.onClose != null)
              SenseButton(
                label: SenseTerminalStrings.closeTerminal,
                size: SenseButtonSize.small,
                onPressed: w.onClose,
              ),
            if (code == 'unsupported' && w.onWindowsAccount != null)
              SenseButton(
                key: const Key('sense-term-windows-account'),
                label: SenseTerminalStrings.windowsAccount,
                size: SenseButtonSize.small,
                onPressed: w.onWindowsAccount,
              ),
            if (SenseTerminalStrings.retryable(code) && w.onRetryAdmin != null)
              SenseButton(
                key: const Key('sense-term-retry'),
                label: SenseTerminalStrings.retry,
                size: SenseButtonSize.small,
                onPressed: w.onRetryAdmin,
              ),
            SenseButton(
              key: const Key('sense-term-open-normal'),
              label: SenseTerminalStrings.openNormal,
              size: SenseButtonSize.small,
              kind: SenseButtonKind.primary,
              onPressed: w.onOpenNormal,
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final strip = _adminStrip();
    // The admin step can only be asked from a normal, idle tab.
    final canAsk = !w.admin && w.adminView == SenseTerminalAdminView.none && w.onAskAdmin != null;
    return ColoredBox(
      color: SenseColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (strip != null) strip,
          if (w.notice != null) w.notice!,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Container(
                key: const Key('sense-term-box'),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: SenseColors.bg,
                  border: Border.all(color: w.admin ? SenseColors.warn : SenseColors.line),
                  borderRadius: BorderRadius.circular(SenseRadii.popup),
                ),
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                child: w.terminal,
              ),
            ),
          ),
          Container(
            key: const Key('sense-term-foot'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: SenseColors.line))),
            child: Row(children: [
              SenseAuxBadge(
                key: const Key('sense-term-rights'),
                label: w.admin ? SenseTerminalStrings.adminRights : SenseTerminalStrings.normalUser,
                level: w.admin ? SenseLevel.warn : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  SenseTerminalStrings.footNote,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textDim),
                ),
              ),
              const SizedBox(width: 8),
              SenseButton(
                key: const Key('sense-term-copy'),
                label: _copied ? SenseTerminalStrings.copied : SenseTerminalStrings.copyOutput,
                size: SenseButtonSize.small,
                onPressed: w.onCopyOutput == null ? null : _copy,
              ),
              if (w.onAskAdmin != null) ...[
                const SizedBox(width: 8),
                SenseButton(
                  key: const Key('sense-term-admin'),
                  label: SenseTerminalStrings.openAdmin,
                  size: SenseButtonSize.small,
                  onPressed: canAsk ? w.onAskAdmin : null,
                ),
              ],
              const SizedBox(width: 8),
              SenseButton(
                key: const Key('sense-term-close'),
                label: SenseTerminalStrings.closeTerminal,
                size: SenseButtonSize.small,
                onPressed: w.onClose,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
