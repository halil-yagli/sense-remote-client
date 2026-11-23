// Sense Remote: "Ekran bilgisi" popup (YH O9; img c07, s07). Same frame and
// parts as "Bilgisayar durumu" (locked popup layout): "3 ekran · Ekran 1
// izleniyor", a status box (frame rate, latency, connection), one category per
// display and "Oturum görüntüsü"; a note with the warning rules at the bottom.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../../sense.dart';
import '../../data/peer_status.dart';
import '../status/status_strings.dart';
import '../status/status_widgets.dart';
import 'display_data.dart';
import 'display_model.dart';

class SenseDisplayPopup extends StatefulWidget {
  const SenseDisplayPopup({
    super.key,
    required this.feed,
    required this.video,
    required this.onClose,
    this.chatIcon,
    this.initialOpenId,
  });

  /// Panel data (displays: monitor, connection, colour, HDR).
  final SensePeerStatusFeed feed;

  /// Live session numbers ([SenseSessionVideoSource] in the session).
  final ValueListenable<SenseSessionVideo> video;
  final VoidCallback onClose;
  final ValueListenable<SenseChatIconPlacement?>? chatIcon;

  /// Category open at start; null = the watched display.
  final String? initialOpenId;

  static void toggle(
    SensePopupController controller, {
    required SensePeerStatusFeed feed,
    required ValueListenable<SenseSessionVideo> video,
    ValueListenable<SenseChatIconPlacement?>? chatIcon,
  }) {
    controller.toggle(
      SenseDisplayStrings.popupId,
      (_) => SenseDisplayPopup(
        feed: feed,
        video: video,
        chatIcon: chatIcon,
        onClose: () => controller.close(SenseDisplayStrings.popupId),
      ),
    );
  }

  @override
  State<SenseDisplayPopup> createState() => _SenseDisplayPopupState();
}

class _SenseDisplayPopupState extends State<SenseDisplayPopup> {
  String? _open;
  bool _openSet = false;
  bool _minimized = false;

  @override
  void initState() {
    super.initState();
    widget.feed.attach();
    if (widget.initialOpenId != null) {
      _open = widget.initialOpenId;
      _openSet = true;
    }
  }

  @override
  void didUpdateWidget(SenseDisplayPopup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.feed, widget.feed)) {
      oldWidget.feed.detach();
      widget.feed.attach();
    }
  }

  @override
  void dispose() {
    widget.feed.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SenseAvoidChatIcon(
      chat: widget.chatIcon,
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.feed, widget.video]),
        builder: (context, _) {
          final video = widget.video.value;
          final view = senseBuildDisplayView(panel: widget.feed.data?.status.displays ?? const [], video: video);
          if (!_openSet) {
            // Opens on the watched display (prototype: Ekran 1 open).
            _open = video.watchingAll ? null : 'display-${video.watched}';
          }
          return SensePopupShell(
            title: SenseDisplayStrings.title,
            subtitle: view.subtitle,
            minimized: _minimized,
            onMinimizedChanged: (v) => setState(() => _minimized = v),
            onClose: widget.onClose,
            body: _body(view),
          );
        },
      ),
    );
  }

  void _select(String? id) => setState(() {
        _open = id;
        _openSet = true;
      });

  Widget _body(SenseDisplayView view) {
    final r = widget.feed.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SenseLiveLine(key: const Key('sense-display-live'), text: view.liveText),
        if (r != null && r.data == null && widget.feed.data == null)
          SenseStatusMessage(
            text: r.noPanelInfo ? SenseStatusStrings.noPanelInfo : SenseStatusStrings.panelFailed,
            onRetry: r.noPanelInfo ? null : widget.feed.refresh,
          ),
        SenseStatusBox(
          level: view.level,
          title: view.title,
          alerts: [
            for (final c in view.alerts)
              SenseStatusAlert(label: c.title, level: c.level, onTap: () => _select(c.id)),
          ],
          children: senseRowViews(view.meters),
        ),
        const SizedBox(height: kSenseStatusBoxGap),
        SenseAccordion(
          openId: _open,
          onChanged: _select,
          items: [
            for (final c in view.categories)
              SenseAccordionItem(
                id: c.id,
                title: c.title,
                summary: c.summary,
                level: c.level == SenseLevel.unknown ? null : c.level,
                builder: (context) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: senseRowViews(c.rows),
                ),
              ),
          ],
        ),
        const SenseHintView(text: SenseDisplayStrings.hint),
      ],
    );
  }
}
