// Sense Remote: new-message card (#62, YH O10; n09.png). Shown at the bottom
// right while the window is not in focus: logo, "Sense Remote · şimdi",
// "Bilgisayar adı · yeni mesaj", the start of the message. Slides in from the
// right in 0.3 s, leaves after 6 s; a press brings the window forward and
// opens the chat.

import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/chat.dart';

abstract final class SenseChatNoticeSize {
  static const double width = 340;
  static const EdgeInsets padding = EdgeInsets.fromLTRB(14, 12, 16, 12);
  static const double logoWidth = 22;
  static const double logoHeight = 20;
  static const double gap = 12;

  /// How long the card stays (#62: 6 sn).
  static const Duration hold = Duration(seconds: 6);

  /// Slide distance from the right edge.
  static const double slide = 24;
}

class SenseChatNotice extends StatelessWidget {
  const SenseChatNotice({
    super.key,
    required this.computer,
    required this.line,
    required this.onTap,
  });

  /// Name of the remote computer ("Giriş Salonu PC-2").
  final String computer;

  /// "Sahadaki kişi: Ekran 2'de görüntü yine kaydı, bakabilir misiniz?"
  final String line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SenseInteractive(
      key: const Key('sense-chat-notice'),
      onTap: onTap,
      semanticLabel: SenseChatStrings.noticeTitle(computer),
      builder: (context, s) => Container(
        width: SenseChatNoticeSize.width,
        padding: SenseChatNoticeSize.padding,
        decoration: BoxDecoration(
          color: s.hovered ? SenseColors.raised : SenseColors.surface,
          border: Border.all(color: s.focused ? SenseColors.text : SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.popup),
          boxShadow: SensePopupShell.shadow,
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: SenseMark(
              width: SenseChatNoticeSize.logoWidth,
              height: SenseChatNoticeSize.logoHeight,
            ),
          ),
          const SizedBox(width: SenseChatNoticeSize.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  SenseChatStrings.noticeNow,
                  style: TextStyle(
                    fontFamily: SenseFont.family,
                    fontSize: SenseFontSize.hint,
                    color: SenseColors.textDim,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  SenseChatStrings.noticeTitle(computer),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: SenseFont.family,
                    fontSize: SenseFontSize.categoryTitle,
                    fontWeight: SenseFontWeight.bold,
                    color: SenseColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  line,
                  key: const Key('sense-chat-notice-line'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: SenseFont.family,
                    fontSize: SenseFontSize.body,
                    height: 1.45,
                    color: SenseColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

/// Slides [child] in from the right (0.3 s) when [visible] turns on and fades
/// it out when it turns off.
class SenseChatNoticeSlide extends StatelessWidget {
  const SenseChatNoticeSlide({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final spec = SenseMotion.layerFade;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: spec.duration,
        curve: spec.curve,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0.08, 0),
          duration: spec.duration,
          curve: spec.curve,
          child: child,
        ),
      ),
    );
  }
}
