// Sense Remote: timings and sizes of the connection layers (YH O13, O14, O15).
// Values that design/tokens.json does not have yet live here, named once, each with
// the prototype rule it comes from (`.netov`, `.nc`, `.idlebar`; NET/END/IDLE in
// Calisma/prototip/SENSE-REMOTE_PROTOTIP.html). Token candidates: see the C4 report.
// Colours, fonts and limits come from the tokens.

/// O13 state machine timings (YH O13 table; prototype SHOW_WEAK, SHOW_LOST, HIDE_OK, DROP).
abstract final class SenseLinkTiming {
  /// The machine's own tick: no event arrives while the link is frozen (TK7).
  static const Duration tick = Duration(seconds: 1);

  /// Values bad without a break for this long: "Bağlantı zayıf".
  static const Duration showWeak = Duration(seconds: 5);

  /// No picture for this long: "Bağlantı kesildi".
  static const Duration showLost = Duration(seconds: 3);

  /// Good without a break for this long: the layer goes ("Bağlantı düzeldi").
  static const Duration hideOk = Duration(seconds: 3);

  /// The session closes (RustDesk io_loop gives up after 30 s, TK7 `io_loop.rs:337`).
  static const Duration drop = Duration(seconds: 30);

  /// The Host sends the next delay probe one second after the last answer
  /// (`TEST_DELAY_TIMEOUT`); a probe older than this plus the round trip is late.
  static const Duration probeInterval = Duration(seconds: 1);

  /// A stall shorter than this is ordinary jitter (D1 `PROBE_SLACK_MS`).
  static const Duration probeSlack = Duration(milliseconds: 300);

  /// Prototype: one reconnect attempt is counted every 4 s of the outage.
  static const Duration attemptEvery = Duration(seconds: 4);
}

/// O14 timing (YH O14 "5 sn sonra kendiliğinden ana ekrana").
abstract final class SenseEndTiming {
  static const Duration backHome = Duration(seconds: 5);
}

/// O15 timing (YH O15 "Kesilmeden 1 dk önce").
abstract final class SenseIdleTiming {
  static const Duration warnBefore = Duration(minutes: 1);

  /// Used until the panel's "Hareketsiz bağlantıyı kes" value reaches the
  /// Controller (YH O14 reason text "30 dk hareketsiz"); see data/idle_policy.dart.
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
