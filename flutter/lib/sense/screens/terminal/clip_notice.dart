// Sense Remote (Sürüm 12, ST 4): the terminal's "panoya yazma" notice in Sense colours
// (stock: a white Material banner with `terminal-clipboard-write-tip`). Same choices as the
// stock notice: persistable → İzin ver / İzin verme; otherwise → Panoya kopyala / Kapat.
import 'package:flutter/widgets.dart';

import '../../sense.dart';
import '../../strings/terminal.dart';
import 'aux_parts.dart';

class SenseTerminalClipNotice extends StatelessWidget {
  const SenseTerminalClipNotice({
    super.key,
    required this.persistAllowed,
    required this.onPositive,
    required this.onNegative,
    this.enabled = true,
  });

  /// The stock "Enable / Decline" form (the option is not set yet).
  final bool persistAllowed;
  final VoidCallback onPositive;
  final VoidCallback onNegative;

  /// False while an answer is being saved.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: SenseSizes.popupWidth + 80,
      child: SenseAuxStrip(
        key: const Key('sense-term-clip'),
        margin: const EdgeInsets.all(12),
        level: SenseLevel.warn,
        title: SenseTerminalStrings.clipTitle,
        body: persistAllowed
            ? '${SenseTerminalStrings.clipBody} ${SenseTerminalStrings.clipPersist}'
            : SenseTerminalStrings.clipBody,
        actions: [
          SenseButton(
            key: const Key('sense-term-clip-no'),
            label: persistAllowed ? SenseTerminalStrings.clipDecline : SenseTerminalStrings.clipDismiss,
            size: SenseButtonSize.small,
            onPressed: enabled ? onNegative : null,
          ),
          SenseButton(
            key: const Key('sense-term-clip-yes'),
            label: persistAllowed ? SenseTerminalStrings.clipAllow : SenseTerminalStrings.clipCopy,
            size: SenseButtonSize.small,
            kind: SenseButtonKind.primary,
            onPressed: enabled ? onPositive : null,
          ),
        ],
      ),
    );
  }
}
