// Sense Remote: the one popup holder of a connection window (T7: one popup at a time).
// The bar's popups (Bilgisayar durumu O8, Ekran bilgisi O9), the bar's lists (O7) and the
// chat (O10) share one [SensePopupController]: opening any of them closes the others.
// The worst value next to each popup button comes from the same data the popups show.
import 'package:flutter/widgets.dart';

import '../../../../models/model.dart' show FFI;
import '../../../components/popup_host.dart';
import '../../../tokens/sense_tokens.dart';
import '../data/peer_status.dart';
import '../data/session_state.dart' show SenseBarPopup;
import '../layers/layer_controller.dart' show SenseLayerController;
import '../popups/display/display_data.dart';
import '../popups/display/display_model.dart';
import '../popups/display/display_popup.dart';
import '../popups/status/status_model.dart';
import '../popups/status/status_popup.dart';
import '../popups/status/status_strings.dart';
import '../popups/status/status_widgets.dart' show SenseChatIconPlacement;
import 'sense_session_bar.dart';

class SenseSessionPopups extends ChangeNotifier implements SenseBarPopups {
  SenseSessionPopups._(this.peerId, FFI ffi)
      : feed = SensePeerStatusFeed.of(peerId),
        video = SenseSessionVideoSource(ffi) {
    controller.addListener(_onController);
    feed.addListener(notifyListeners);
    video.addListener(notifyListeners);
    // The dots next to the buttons need the data while the popups are closed too.
    feed.attach();
  }

  static final Map<String, SenseSessionPopups> _byId = {};

  /// One holder per connection tab (the tab key is the peer id).
  static SenseSessionPopups of(String peerId, FFI ffi) =>
      _byId.putIfAbsent(peerId, () => SenseSessionPopups._(peerId, ffi));

  static void remove(String peerId) => _byId.remove(peerId)?.dispose();

  /// Closes whatever holds the popup place (the session ended, O14).
  static void closeAllOf(String peerId) => _byId[peerId]?.controller.close();

  /// Popup id the bar's lists hold while one is open.
  static const String listId = 'sense-bar-list';

  final String peerId;
  final SensePopupController controller = SensePopupController();
  final SensePeerStatusFeed feed;
  final SenseSessionVideoSource video;

  /// Where the chat icon is, so the right popups end above it (O10).
  final ValueNotifier<SenseChatIconPlacement?> chatIcon = ValueNotifier(null);

  String? _last;
  bool _ours = false;
  bool _kicked = false;
  bool _disposed = false;

  void _onController() {
    final now = controller.openId;
    // B3: one popup at a time: the connection card (opened from the logo) gives way to
    // whatever opens here (a list, Bilgisayar durumu, Ekran bilgisi, the chat).
    if (now != null && now != _last) SenseLayerController.find(peerId)?.closeInfo();
    if (_last == listId && now != listId && !_ours) _kicked = true;
    _last = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    controller.removeListener(_onController);
    feed.removeListener(notifyListeners);
    video.removeListener(notifyListeners);
    feed.detach();
    video.dispose();
    controller.dispose();
    chatIcon.dispose();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  String _id(SenseBarPopup p) =>
      p == SenseBarPopup.status ? SenseStatusStrings.popupId : SenseDisplayStrings.popupId;

  @override
  bool isOpen(SenseBarPopup p) => controller.isOpenWith(_id(p));

  @override
  void toggle(SenseBarPopup p) {
    if (p == SenseBarPopup.status) {
      SenseStatusPopup.toggle(controller, feed: feed, chatIcon: chatIcon);
    } else {
      SenseDisplayPopup.toggle(controller, feed: feed, video: video, chatIcon: chatIcon);
    }
  }

  @override
  void closeAll() {
    controller.close(SenseStatusStrings.popupId);
    controller.close(SenseDisplayStrings.popupId);
  }

  @override
  SenseLevel? level(SenseBarPopup p) {
    final data = feed.data;
    if (p == SenseBarPopup.status) {
      return data == null ? null : senseBuildStatusView(data).level;
    }
    return senseBuildDisplayView(panel: data?.status.displays ?? const [], video: video.value).level;
  }

  @override
  bool get menuAllowed => !_kicked;

  @override
  void onMenu(bool open) {
    _ours = true;
    if (open) {
      _kicked = false;
      controller.open(listId, (_) => const SizedBox.shrink());
    } else {
      controller.close(listId);
    }
    _ours = false;
  }
}
