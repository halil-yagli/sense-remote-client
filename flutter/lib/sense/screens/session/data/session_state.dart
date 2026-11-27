// Sense Remote: state of the session bar (YH O1, O2, O7, T9) that does not need the
// RustDesk session itself, so it can be tested on its own:
//  - the one open list or popup of the bar (T7: one popup at a time),
//  - the connection line "Doğrudan · 60 fps · 18 ms" and its colour (T6),
//  - the bar labels at the T9 widths,
//  - the ghost mode notes of the core (D1: `sense_privacy_note`).
import 'package:flutter/foundation.dart';

import '../../../strings/session.dart';
import '../record_notice.dart';
import '../../../tokens/sense_tokens.dart';

/// The four lists of the bar (O3–O6).
enum SenseBarMenu { screens, display, keyboard, actions }

/// The two popups of the bar (O8, O9; drawn by C2).
enum SenseBarPopup { status, info }

/// Which list is open. Popups are kept by their owner; the bar closes the list when
/// a popup opens and the other way round (T7).
class SenseBarController extends ChangeNotifier {
  SenseBarMenu? _menu;

  SenseBarMenu? get openMenu => _menu;
  bool isOpen(SenseBarMenu m) => _menu == m;

  /// Called whenever a list opens, so the owner can close its popups.
  VoidCallback? onMenuOpened;

  void toggle(SenseBarMenu m) {
    _menu = _menu == m ? null : m;
    if (_menu != null) onMenuOpened?.call();
    notifyListeners();
  }

  void close() {
    if (_menu == null) return;
    _menu = null;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Connection line (O1, T6, S10)
// ---------------------------------------------------------------------------

enum SenseLinkPath { direct, relay, unknown }

/// One reading of the connection. Any value may be missing (not measured yet).
@immutable
class SenseLinkSample {
  const SenseLinkSample({
    this.path = SenseLinkPath.unknown,
    this.fps,
    this.rttMs,
    this.lastFrameMs,
    this.lossPct,
    this.wavy,
    this.onRestoreLayer,
  });

  final SenseLinkPath path;
  final int? fps;
  final int? rttMs;

  /// Milliseconds since the last decoded frame (D1 `last_frame_ms`).
  final int? lastFrameMs;

  /// Loss estimate in percent (D1 `loss_est`; an estimate, not a measurement).
  final double? lossPct;

  /// "Dalgalı" as decided by the connection layer (`SenseLayerController.wavy`, C4);
  /// null where no layer runs (then the T6 limits decide here).
  final bool? wavy;

  /// Set while the weak card sits minimized in the logo area (karar #94): a click on
  /// the logo / status area opens it again instead of opening Ekran bilgisi.
  final VoidCallback? onRestoreLayer;

  SenseLinkSample copyWith({
    SenseLinkPath? path,
    int? fps,
    int? rttMs,
    int? lastFrameMs,
    double? lossPct,
    bool? wavy,
    VoidCallback? onRestoreLayer,
  }) =>
      SenseLinkSample(
        path: path ?? this.path,
        fps: fps ?? this.fps,
        rttMs: rttMs ?? this.rttMs,
        lastFrameMs: lastFrameMs ?? this.lastFrameMs,
        lossPct: lossPct ?? this.lossPct,
        wavy: wavy ?? this.wavy,
        onRestoreLayer: onRestoreLayer ?? this.onRestoreLayer,
      );
}

/// What the line says.
enum SenseLinkHealth { connecting, good, wavy, noImage }

/// No frame for this long and no delay answer either: "Görüntü gelmiyor". A still
/// Host screen sends no frames, so the frame age alone is not enough (D1 note).
/// Karar #94: the same 30 s as the connection layer's drop (`SenseLinkTiming.drop`).
const int kSenseNoImageMs = 30000;

/// No frame for this long: a still screen. Its 0 fps does not colour the line.
const int kSenseStillMs = 5000;

SenseLinkHealth senseLinkHealth(SenseLinkSample s) {
  if (s.fps == null && s.rttMs == null && s.lastFrameMs == null) {
    return SenseLinkHealth.connecting;
  }
  final noImage = (s.lastFrameMs ?? 0) >= kSenseNoImageMs;
  final frameOld = (s.lastFrameMs ?? 0) >= kSenseStillMs;
  final rtt = s.rttMs;
  if (noImage && (rtt == null || SenseThresholds.latency.levelOf(rtt.toDouble()) == SenseLevel.hot)) {
    return SenseLinkHealth.noImage;
  }
  final decided = s.wavy;
  if (decided != null) return decided ? SenseLinkHealth.wavy : SenseLinkHealth.good;
  final levels = <SenseLevel>[
    if (rtt != null) SenseThresholds.latency.levelOf(rtt.toDouble()),
    if (s.lossPct != null) SenseThresholds.packetLoss.levelOf(s.lossPct!),
    if (s.fps != null && !frameOld) SenseThresholds.frameRate.levelOf(s.fps!.toDouble()),
  ];
  final worst = senseWorstLevel(levels);
  return worst == SenseLevel.warn || worst == SenseLevel.hot
      ? SenseLinkHealth.wavy
      : SenseLinkHealth.good;
}

/// The small line under the computer name and its colour.
({String text, SenseLevel level}) senseLinkLine(SenseLinkSample s) {
  final health = senseLinkHealth(s);
  if (health == SenseLinkHealth.connecting) {
    return (text: SenseSessionStrings.connecting, level: SenseLevel.unknown);
  }
  if (health == SenseLinkHealth.noImage) {
    return (text: SenseSessionStrings.noImage, level: SenseLevel.hot);
  }
  final head = health == SenseLinkHealth.wavy
      ? SenseSessionStrings.wavy
      : s.path == SenseLinkPath.relay
          ? SenseSessionStrings.relay
          : SenseSessionStrings.direct;
  final parts = <String>[
    head,
    if (s.fps != null) SenseSessionStrings.fps(s.fps!),
    if (s.rttMs != null) SenseSessionStrings.ms(s.rttMs!),
  ];
  return (
    text: parts.join(' · '),
    level: health == SenseLinkHealth.wavy ? SenseLevel.warn : SenseLevel.ok,
  );
}

/// RustDesk sends fps as a JSON map per display (`{"0":60}`) already flattened by
/// QualityMonitorModel into "60" or "60 58" (all displays). The bar shows the lowest.
int? senseParseFps(String? raw) {
  if (raw == null) return null;
  final values = raw
      .split(RegExp(r'[\s,]+'))
      .map((e) => int.tryParse(e.trim()))
      .whereType<int>()
      .toList();
  if (values.isEmpty) return null;
  values.sort();
  return values.first;
}

/// "18" or "18ms" → 18.
int? senseParseMs(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'-?\d+').firstMatch(raw);
  return m == null ? null : int.tryParse(m.group(0)!);
}

double? senseParseDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  return double.tryParse(raw.toString().trim());
}

// ---------------------------------------------------------------------------
// Space above the remote screen (decision 3, O1)
// ---------------------------------------------------------------------------

/// What sits above the remote screen in a Sense connection window: the 28 px tab strip
/// (only with more than one session, never in full screen) and the Sense bar (46 px, 0
/// while hidden). The canvas subtracts this to fit the image ("Sığdır").
double senseTopInset({required bool tabStrip, required double barHeight}) =>
    (tabStrip ? kSenseTabStripHeight : 0) + barHeight;

/// RustDesk's tab strip (`kDesktopRemoteTabBarHeight`).
const double kSenseTabStripHeight = 28;

// ---------------------------------------------------------------------------
// Labels at the T9 widths
// ---------------------------------------------------------------------------

@immutable
class SenseBarLabels {
  const SenseBarLabels._(this.short);
  final bool short;

  String get screens => SenseSessionStrings.screens;
  String get display => SenseSessionStrings.display;
  String get keyboard => short ? SenseSessionStrings.keyboardShort : SenseSessionStrings.keyboard;
  String get actions => SenseSessionStrings.actions;
  String get status => short ? SenseSessionStrings.statusShort : SenseSessionStrings.status;
  String get info => short ? SenseSessionStrings.infoShort : SenseSessionStrings.info;
  String ghost(bool on) => on
      ? (short ? SenseSessionStrings.ghostOnShort : SenseSessionStrings.ghostOn)
      : (short ? SenseSessionStrings.ghostShort : SenseSessionStrings.ghost);
  String get fullscreen => short ? SenseSessionStrings.fullscreenShort : SenseSessionStrings.fullscreen;
  String get end => SenseSessionStrings.end;
}

/// T9: at or under 1500 px the bar uses the short names (prototype `fitBar`).
SenseBarLabels senseBarLabels(double windowWidth) =>
    SenseBarLabels._(windowWidth <= SenseBreakpoints.medium);

// ---------------------------------------------------------------------------
// Core events (D1) for one session
// ---------------------------------------------------------------------------

/// Ghost mode notes of the core instead of dialogs (S9-b).
class SenseSessionSignals extends ChangeNotifier {
  String? _privacyNote;
  int _privacySerial = 0;

  /// Code of the last ghost mode note (`unsupported`, `denied`, `on_failed`,
  /// `off_failed`, `off_by_peer`, `off_unknown`), or null.
  String? get privacyNote => _privacyNote;

  /// Grows with every note, so the same note twice is shown twice.
  int get privacySerial => _privacySerial;

  void onPrivacyNote(String code) {
    _privacyNote = code;
    _privacySerial++;
    notifyListeners();
  }

  void clearPrivacyNote() {
    if (_privacyNote == null) return;
    _privacyNote = null;
    notifyListeners();
  }
}

abstract final class SenseSessionEvents {
  static final Map<String, SenseSessionSignals> _byPeer = {};

  static SenseSessionSignals of(String peerId) =>
      _byPeer.putIfAbsent(peerId, SenseSessionSignals.new);

  static void remove(String peerId) => _byPeer.remove(peerId)?.dispose();

  /// Handles a Sense-only event; false when [evt] is not one.
  static bool handle(String peerId, Map<String, dynamic> evt) {
    if (evt['name'] == 'sense_privacy_note') {
      of(peerId).onPrivacyNote((evt['code'] ?? '').toString());
      return true;
    }
    if (SenseRecordNotice.handle(evt)) return true; // Sense Remote (#114): "Klasörü aç" note
    return false;
  }
}
