// Sense Remote: "Bilgisayar durumu" popup (YH O8; locked design
// prototip/onayli/2026-11-22_bilgisayar-durumu_ONAYLI.html, img c06, s01–s06).
// Top: "Canlı · 8 sn önce" (no Tümünü aç / Hepsini kopyala, #10); overall box with
// the troubled categories as tags (a tag opens its category); eight closable
// categories, one open at a time; bottom note with the thresholds.
// Data: panel peer-status (health + inventory, S6), refreshed every 30 s while open.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../../sense.dart';
import '../../data/peer_status.dart';
import 'status_format.dart';
import 'status_model.dart';
import 'status_strings.dart';
import 'status_widgets.dart';

class SenseStatusPopup extends StatefulWidget {
  const SenseStatusPopup({
    super.key,
    required this.feed,
    required this.onClose,
    this.chatIcon,
    this.initialOpenId,
    this.tick = const Duration(seconds: 1),
  });

  final SensePeerStatusFeed feed;
  final VoidCallback onClose;

  /// Where the chat icon is, so the popup ends above it (O10, #14).
  final ValueListenable<SenseChatIconPlacement?>? chatIcon;
  final String? initialOpenId;

  /// How often "8 sn önce" is redrawn; null = never (golden tests).
  final Duration? tick;

  /// Shows the popup as the only one (T7). A second call closes it (toolbar toggle).
  static void toggle(
    SensePopupController controller, {
    required SensePeerStatusFeed feed,
    ValueListenable<SenseChatIconPlacement?>? chatIcon,
  }) {
    controller.toggle(
      SenseStatusStrings.popupId,
      (_) => SenseStatusPopup(
        feed: feed,
        chatIcon: chatIcon,
        onClose: () => controller.close(SenseStatusStrings.popupId),
      ),
    );
  }

  @override
  State<SenseStatusPopup> createState() => _SenseStatusPopupState();
}

class _SenseStatusPopupState extends State<SenseStatusPopup> {
  late String? _open = widget.initialOpenId;
  bool _minimized = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.feed.attach();
    final t = widget.tick;
    if (t != null) _timer = Timer.periodic(t, (_) => setState(() {}));
  }

  @override
  void didUpdateWidget(SenseStatusPopup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.feed, widget.feed)) {
      oldWidget.feed.detach();
      widget.feed.attach();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.feed.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SenseAvoidChatIcon(
      chat: widget.chatIcon,
      child: ListenableBuilder(
        listenable: widget.feed,
        builder: (context, _) {
          final feed = widget.feed;
          final data = feed.data;
          final lastSeen = data?.status.lastSeenAt;
          final age = lastSeen == null
              ? null
              : senseAgo(feed.now().difference(DateTime.fromMillisecondsSinceEpoch(lastSeen * 1000)));
          return SensePopupShell(
            title: SenseStatusStrings.title,
            subtitle: age,
            minimized: _minimized,
            onMinimizedChanged: (v) => setState(() => _minimized = v),
            onClose: widget.onClose,
            body: _body(feed, data, age),
          );
        },
      ),
    );
  }

  Widget _body(SensePeerStatusFeed feed, SensePeerStatusFull? data, String? age) {
    if (data == null) {
      final r = feed.result;
      if (r == null || feed.loading) {
        return const SenseStatusMessage(text: SenseStatusStrings.loading, busy: true);
      }
      if (r.noPanelInfo) return const SenseStatusMessage(text: SenseStatusStrings.noPanelInfo);
      return SenseStatusMessage(text: SenseStatusStrings.panelFailed, onRetry: feed.refresh);
    }
    final view = senseBuildStatusView(data);
    final online = data.status.online;
    final failed = feed.result?.data == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SenseLiveLine(
          key: const Key('sense-status-live'),
          text: online ? SenseStatusStrings.live(age) : SenseStatusStrings.offline(age),
          level: online ? SenseLevel.ok : SenseLevel.unknown,
        ),
        if (failed) SenseStatusMessage(text: SenseStatusStrings.panelFailed, onRetry: feed.refresh),
        SenseStatusBox(
          level: view.level,
          title: view.title,
          alerts: [
            for (final c in view.alerts)
              SenseStatusAlert(label: c.title, level: c.level, onTap: () => setState(() => _open = c.id)),
          ],
          children: [for (final m in view.meters) SenseMeterRowView(row: m)],
        ),
        const SizedBox(height: kSenseStatusBoxGap),
        SenseAccordion(
          openId: _open,
          onChanged: (id) => setState(() => _open = id),
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
        const SenseHintView(text: SenseStatusStrings.hint),
      ],
    );
  }
}
