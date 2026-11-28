// Sense Remote: timings and sizes of the connection layers (YH O13, O14, O15).
// Values that design/tokens.json does not have yet live here, named once, each with
// the prototype rule it comes from (`.netov`, `.nc`, `.idlebar`; NET/END/IDLE in
// Calisma/prototip/SENSE-REMOTE_PROTOTIP.html). Token candidates: see the C4 report.
// Colours, fonts and limits come from the tokens.

/// O13 state machine timings (YH O13 table; prototype SHOW_WEAK, SHOW_LOST, HIDE_OK, DROP).
abstract final class SenseLinkTiming {
  /// The machine's own tick: no event arrives while the link is frozen (TK7).
  static const Duration tick = Duration(seconds: 1);

  /// Frame rate below [weakFpsBelow] without a break for this long: "Bağlantı zayıf"
  /// (karar #94). High delay or loss alone never opens the card; the bar reports them.
  static const Duration showWeak = Duration(seconds: 15);

  /// The weak card's frame rate limit (frames per second; 0 is excluded: a still screen).
  static const double weakFpsBelow = 5;

  /// After the weak card was closed with "×", it opens by itself again at most this often.
  static const Duration reopenEvery = Duration(minutes: 5);

  /// Card shrinks to the top-left logo area and back (the "×"), karar #94.
  static const Duration shrink = Duration(milliseconds: 250);

  /// Good without a break for this long: the layer goes ("Bağlantı düzeldi").
  static const Duration hideOk = Duration(seconds: 3);

  /// Neither frame nor delay measurement for this long: "Bağlantı kesildi" and the
  /// session closes (RustDesk io_loop gives up after 30 s, TK7 `io_loop.rs:337`).
  /// Same value as the bar's `kSenseNoImageMs`. While data keeps coming the layer
  /// never closes or reconnects the session by itself.
  static const Duration drop = Duration(seconds: 30);

  /// The Host sends the next delay probe one second after the last answer
  /// (`TEST_DELAY_TIMEOUT`); a probe older than this plus the round trip is late.
  static const Duration probeInterval = Duration(seconds: 1);

  /// A stall shorter than this is ordinary jitter (D1 `PROBE_SLACK_MS`).
  static const Duration probeSlack = Duration(milliseconds: 300);

  /// Sürüm 11 (O1): the first real reconnect attempt this long after the transport was lost;
  /// then 2, 4, 8 s apart, never more than [retryMaxGap] ([SenseRetryPlan]).
  static const Duration retryFirst = Duration(seconds: 1);
  static const Duration retryMaxGap = Duration(seconds: 8);

  /// Sürüm 11 (O1): neither frame nor delay measurement this long on a link that was up: the
  /// transport is lost (a TCP connection reports nothing by itself; KCP says so at 8 s).
  static const Duration lostAfter = Duration(seconds: 10);

  /// Sürüm 11 (#121): logged in and no picture this long: "Görüntü bekleniyor" instead of a
  /// black screen (the core asks for a key frame at 3 s and connects again at 8 s).
  static const Duration noImageAfter = Duration(seconds: 3);
}

/// O14 timing (YH O14 "5 sn sonra kendiliğinden ana ekrana").
abstract final class SenseEndTiming {
  static const Duration backHome = Duration(seconds: 5);

  /// Sürüm 11 (O7): "Yeniden bağlan" that brought no answer in this long gives the buttons
  /// back ("Bağlanılamadı") instead of spinning forever.
  static const Duration reconnectTimeout = Duration(seconds: 20);
}

/// O15 timing (YH O15 "Kesilmeden 1 dk önce").
abstract final class SenseIdleTiming {
  static const Duration warnBefore = Duration(minutes: 1);

  /// Only the wording of the ended card when no limit is known; it never cuts
  /// (the limit comes from the panel, see data/idle_policy.dart).
  static const Duration defaultLimit = Duration(minutes: 30);
}

/// Look of the layers (prototype CSS).
abstract final class SenseLayerLook {
  // `.netov` backdrop-filter: blur(4px) brightness(.62) / netlost blur(6px) brightness(.45).
  static const double weakBlur = 4;
  static const double weakBrightness = 0.62;
  static const double lostBlur = 6;
  static const double lostBrightness = 0.45;

  // `.nc`: card background rgba(10,10,14,.78) (surface at 78 %), radius 14,
  // padding 18 22 14, gap 6, min width 330, shadow 0 20px 60px rgba(0,0,0,.6).
  static const double cardOpacity = 0.78;
  static const double cardRadius = 14;
  static const double cardPadTop = 18;
  static const double cardPadSide = 22;
  static const double cardPadBottom = 14;
  static const double cardGap = 6;
  static const double cardMinWidth = 330;
  static const double cardShadowBlur = 60;
  static const double cardShadowY = 20;
  static const double cardShadowOpacity = 0.6;

  // "x" of the weak card (karar #94): 26 px target, 7 px from the card corner; the card
  // shrinks to 6 % of its size into the logo area.
  static const double closeSize = 26;
  static const double closeInset = 7;
  static const double shrinkScale = 0.06;

  // `.nc svg` 40 × 36, 4 px below.
  static const double logoWidth = 40;
  static const double logoHeight = 36;
  static const double logoGap = 4;

  // `.nc>b` 15 px / 600; `.nmv b` 15 px (same size as the large stat tile).
  static const double titleSize = 15;

  // `.nm` grid gap 8, margin 10 0 4; `.nbtn` margin-top 10; `.nre` margin-top 6, gap 8.
  static const double tilesGap = 8;
  static const double tilesTop = 10;
  static const double tilesBottom = 4;
  static const double buttonsTop = 10;
  static const double retryTop = 6;
  static const double retryGap = 8;

  // Ended card: `.endov .nc svg` opacity .9, `.endov .nbtn` gap 8, margin-top 6.
  static const double endLogoOpacity = 0.9;
  static const double endButtonsGap = 8;
  static const double endButtonsTop = 6;

  // `.idlebar`: 34 px, padding 0 16, gap 12, rgba(255,151,0,.12) ground,
  // rgba(255,151,0,.45) bottom line, #ffb84d text 12 / 500, 7 px blinking dot.
  static const double idleHeight = 34;
  static const double idlePadSide = 16;
  static const double idleGap = 12;
  static const double idleGroundOpacity = 0.12;
  static const double idleLineOpacity = 0.45;
  static const double idleTextLighten = 0.3;
  static const double idleDot = 7;
}

/// Sürüm 12 (FO-B1): the small connection card that drops from the bar's logo area
/// (prototype `.qcard`, `qcardToggle`: no veil, no blur).
abstract final class SenseQuickCardLook {
  // `.qcard`: min-width 270, padding 12 14, gap 3, radius 12, shadow 0 16px 44px rgba(0,0,0,.6).
  static const double minWidth = 270;
  static const double padV = 12;
  static const double padH = 14;
  static const double gap = 3;
  static const double shadowBlur = 44;
  static const double shadowY = 16;
  static const double shadowOpacity = 0.6;

  // Placed under `#qual` (the computer name): `.brand` padding 14 + logo 26 + gap 10, and
  // 8 px under the bar.
  static const double left = 50;
  static const double below = 8;

  // The v11 value boxes and the limits line, as lines (a little apart from the rest).
  static const double valuesTop = 4;
}

/// Sürüm 12 (FO-A4): the note row of the ended card (prototype `.endnote`, `.nsaved`).
abstract final class SenseEndNoteLook {
  // `.endnote`: gap 6, margin 10 0 2; the input padding 6 10. `.nsaved` margin 10 0 2.
  // "Not ekle" `margin-top:10px`.
  static const double top = 10;
  static const double bottom = 2;
  static const double gap = 6;
  static const double fieldPadH = 10;
  static const double fieldPadV = 6;
  static const double fieldWidth = 240;
  static const int maxLength = 1000;
}
