// Sense Remote: one computer of the Controller list (YH C2; prototype `pcRow`,
// `.pc2`, `ledTip`; images a01, a02, a12). Two signs that must not mix (#25,
// kabul C2): whether it can be reached is the tile itself (bright + white
// Bağlan / faded + "kapalı" + Yine de dene; no online dot), its health is the
// LED in the preview corner. Hovering the LED opens a 250 px box with the
// values; it goes when the pointer leaves.
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/controller.dart';
import '../data/peers.dart';

// Prototype `.pc2`: corner 12; `.th` 84 high; screens 30×19, gap 4, line 1.5,
// corner 2; os / tag at 9 px from the side, 7 / 8 px from the edge; LED 9 px in;
// `.bd` 10/11/11, gap 8; LED hit area 7 px around; detail box 250 wide, 8 px off.
const double _kScreenW = 30, _kScreenH = 19, _kScreenGap = 4, _kScreenLine = 1.5, _kScreenRadius = 2;
const double _kEdge = 9, _kOsBottom = 7, _kTagTop = 8, _kLedInset = 9, _kLedHit = 7;
const double _kBodyTop = 10, _kBodySide = 11, _kBodyGap = 8, _kMaxScreens = 6;
const double _kTipWidth = 250, _kTipGap = 8, _kTipLift = 6, _kTipPadV = 9, _kTipPadH = 11;
const double _kTipShadow = 50, _kTipShadowY = 18, _kSmallLed = 8;

/// Connect button state of a tile.
enum SenseTileAction { connect, tryAnyway, connecting, busy, noRight }

SenseTileAction senseTileAction(SenseComputer c, {required bool connecting, required bool canConnect}) {
  if (c.busy) return SenseTileAction.busy;
  if (connecting) return SenseTileAction.connecting;
  if (!canConnect) return SenseTileAction.noRight;
  return c.online ? SenseTileAction.connect : SenseTileAction.tryAnyway;
}

/// Line next to the button: "Çevrimiçi", "Meşgul · Mevlüt bağlı",
/// "Son görülme 3 gün önce" (or "Kapalı" while the time is not known).
String senseTileStatus(SenseComputer c, int now) {
  if (c.busy) return SenseControllerStrings.busyBy(c.busyBy!);
  if (c.online) return SenseControllerStrings.online;
  final ago = senseAgoFrom(c.lastSeenAt, now);
  return ago == null ? SenseControllerStrings.offline : SenseControllerStrings.lastSeen(ago);
}

/// "Lobi · 3 ekran" (parts that are not known are left out).
String senseTileSubtitle(SenseComputer c) => [
      if (c.location.isNotEmpty) c.location,
      if (c.displayCount != null) SenseControllerStrings.screens(c.displayCount!),
    ].join(' · ');

class SenseComputerTile extends StatelessWidget {
  const SenseComputerTile({
    super.key,
    required this.computer,
    required this.onConnect,
    required this.now,
    this.health,
    this.connecting = false,
    this.canConnect = true,
    this.onLedHover,
    this.dropMark = false,
    this.ghost = false,
    this.ledOpen = false,
  });

  final SenseComputer computer;
  final VoidCallback onConnect;

  /// Unix seconds, for "8 sn önce".
  final int now;

  /// Null = not read yet (hollow LED, box says "Panelden alınıyor…").
  final SenseComputerHealth? health;
  final bool connecting;
  final bool canConnect;

  /// Called when the pointer enters the LED (fetch now).
  final VoidCallback? onLedHover;

  /// Drag and drop: a white bar on the left where the dragged tile lands.
  final bool dropMark;

  /// The tile being dragged (faded in place).
  final bool ghost;

  /// Goldens: the LED box shown without a pointer.
  final bool ledOpen;

  SenseLevel get _ledLevel => computer.online ? (health?.level ?? SenseLevel.unknown) : SenseLevel.unknown;

  @override
  Widget build(BuildContext context) {
    final c = computer;
    final tile = SenseHover(
      builder: (hovered) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: SenseColors.bg,
          border: Border.all(color: hovered ? SenseColors.lineStrong : SenseColors.line),
          borderRadius: BorderRadius.circular(SenseRadii.popup),
          boxShadow: dropMark ? const [BoxShadow(color: SenseColors.text, offset: Offset(-3, 0))] : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [_preview(context), _body()],
        ),
      ),
    );
    return Opacity(
      opacity: ghost ? 0.35 : 1,
      child: Semantics(
        container: true,
        label: c.name,
        child: tile,
      ),
    );
  }

  Widget _preview(BuildContext context) {
    final c = computer;
    final screens = (c.displayCount ?? 1).clamp(1, _kMaxScreens).toInt();
    final frame = c.online ? SenseColors.textDim : SenseColors.line;
    return Container(
      height: SenseSizes.tilePreview,
      decoration: BoxDecoration(
        color: c.online ? SenseColors.surface : Color.alphaBlend(SenseColors.surface.withOpacity(0.6), SenseColors.bg),
        gradient: c.online
            ? RadialGradient(
                center: const Alignment(-0.2, -0.4),
                radius: 0.9,
                colors: [
                  Color.alphaBlend(SenseColors.glowStart.withOpacity(0.35), SenseColors.surface),
                  SenseColors.surface,
                ],
              )
            : null,
        border: const Border(bottom: BorderSide(color: SenseColors.line)),
      ),
      child: Stack(children: [
        Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < screens; i++) ...[
              if (i > 0) const SizedBox(width: _kScreenGap),
              Container(
                width: _kScreenW,
                height: _kScreenH,
                decoration: BoxDecoration(
                  color: SenseColors.text.withOpacity(0.03),
                  border: Border.all(color: frame, width: _kScreenLine),
                  borderRadius: BorderRadius.circular(_kScreenRadius),
                ),
              ),
            ],
          ]),
        ),
        if (!c.online)
          Positioned(
            left: _kEdge,
            top: _kTagTop,
            child: Text(SenseControllerStrings.offTag,
                style: SenseTextStyles.of(
                    size: SenseFontSize.capsSmall, color: SenseColors.textDim, letterSpacingEm: SenseLetterSpacing.caps)),
          ),
        if (c.os.isNotEmpty)
          Positioned(
            left: _kEdge,
            bottom: _kOsBottom,
            child: Text(c.os, style: SenseTextStyles.of(size: SenseFontSize.capsSmall, color: SenseColors.textDim)),
          ),
        Positioned(
          right: _kLedInset - _kLedHit,
          top: _kLedInset - _kLedHit,
          child: SenseLedDetail(
            computer: c,
            health: health,
            now: now,
            onHover: onLedHover,
            initiallyOpen: ledOpen,
            child: Padding(
              padding: const EdgeInsets.all(_kLedHit),
              child: SenseLed(key: Key('sense-led-${c.id}'), level: _ledLevel, blink: _ledLevel == SenseLevel.hot),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _body() {
    final c = computer;
    final sub = senseTileSubtitle(c);
    return Padding(
      padding: const EdgeInsets.fromLTRB(_kBodySide, _kBodyTop, _kBodySide, _kBodySide),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(c.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.of(
                  size: SenseFontSize.categoryTitle,
                  weight: SenseFontWeight.bold,
                  color: c.online ? SenseColors.text : SenseColors.textMuted)),
          if (sub.isNotEmpty)
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim)),
          const SizedBox(height: _kBodyGap),
          Row(children: [
            Expanded(
              child: Text(senseTileStatus(c, now),
                  key: Key('sense-tile-status-${c.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted)),
            ),
            const SizedBox(width: _kBodyGap),
            _action(),
          ]),
        ],
      ),
    );
  }

  Widget _action() {
    final c = computer;
    switch (senseTileAction(c, connecting: connecting, canConnect: canConnect)) {
      case SenseTileAction.busy:
        return SenseButton(
          key: Key('sense-tile-busy-${c.id}'),
          label: SenseControllerStrings.busy,
          size: SenseButtonSize.small,
          tooltip: SenseControllerStrings.busyTip,
          onPressed: null,
        );
      case SenseTileAction.connecting:
        return Row(key: Key('sense-tile-connecting-${c.id}'), mainAxisSize: MainAxisSize.min, children: [
          const SenseSpinner(size: 11),
          const SizedBox(width: SenseUi.iconGap),
          Text(SenseControllerStrings.connecting,
              style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textMuted)),
        ]);
      case SenseTileAction.noRight:
        return SenseButton(
          key: Key('sense-tile-noright-${c.id}'),
          label: SenseControllerStrings.noRight,
          size: SenseButtonSize.small,
          tooltip: SenseControllerStrings.noRightTip,
          onPressed: null,
        );
      case SenseTileAction.connect:
        return SenseButton(
          key: Key('sense-tile-connect-${c.id}'),
          label: SenseControllerStrings.connect,
          kind: SenseButtonKind.primary,
          size: SenseButtonSize.small,
          onPressed: onConnect,
        );
      case SenseTileAction.tryAnyway:
        return SenseButton(
          key: Key('sense-tile-connect-${c.id}'),
          label: SenseControllerStrings.tryAnyway,
          size: SenseButtonSize.small,
          onPressed: onConnect,
        );
    }
  }
}

/// LED with its hover box (anchored to the LED, flips left near the edge).
class SenseLedDetail extends StatefulWidget {
  const SenseLedDetail({
    super.key,
    required this.computer,
    required this.health,
    required this.now,
    required this.child,
    this.onHover,
    this.initiallyOpen = false,
  });

  final SenseComputer computer;
  final SenseComputerHealth? health;
  final int now;
  final Widget child;
  final VoidCallback? onHover;

  /// Goldens: the box shown without a pointer.
  final bool initiallyOpen;

  @override
  State<SenseLedDetail> createState() => _SenseLedDetailState();
}

class _SenseLedDetailState extends State<SenseLedDetail> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  bool _left = false;

  @override
  void initState() {
    super.initState();
    if (widget.initiallyOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _show();
      });
    }
  }

  void _show() {
    final box = context.findRenderObject() as RenderBox?;
    final screen = MediaQuery.maybeSizeOf(context)?.width ?? double.infinity;
    if (box != null && box.hasSize) {
      final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
      _left = right + _kTipGap + _kTipWidth > screen - _kTipGap;
    }
    widget.onHover?.call();
    _portal.show();
    setState(() {});
  }

  void _hide() {
    _portal.hide();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _portal,
          overlayChildBuilder: (_) => Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: _left ? Alignment.topLeft : Alignment.topRight,
              followerAnchor: _left ? Alignment.topRight : Alignment.topLeft,
              offset: Offset(_left ? -_kTipGap + _kLedHit : _kTipGap - _kLedHit, _kLedHit - _kTipLift),
              child: IgnorePointer(
                child: SenseHealthBox(computer: widget.computer, health: widget.health, now: widget.now),
              ),
            ),
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.help,
            onEnter: (_) => _show(),
            onExit: (_) => _hide(),
            child: widget.child,
          ),
        ),
      );
}

/// The 250 px box: head (LED, Sağlıklı / Uyarı var / Dikkat gerekiyor / Veri
/// yok, name), values in their colours, "Son veri 8 sn önce · panel".
class SenseHealthBox extends StatelessWidget {
  const SenseHealthBox({super.key, required this.computer, required this.health, required this.now});

  final SenseComputer computer;
  final SenseComputerHealth? health;
  final int now;

  @override
  Widget build(BuildContext context) {
    final c = computer;
    final h = health;
    final level = c.online ? (h?.level ?? SenseLevel.unknown) : SenseLevel.unknown;
    final title = senseHealthTitle(level, online: c.online);
    final titleColor = switch (level) {
      SenseLevel.ok => SenseColors.ok,
      SenseLevel.warn => SenseColors.warn,
      SenseLevel.hot => SenseColors.dangerText,
      SenseLevel.unknown => SenseColors.text,
    };
    final lines = c.online ? (h?.lines ?? const <SenseHealthLine>[]) : const <SenseHealthLine>[];
    final seenAgo = senseAgoFrom(h?.lastSeenAt ?? c.lastSeenAt, now);
    final dataAgo = senseAgoFrom(h?.at, now);
    final String? note;
    if (!c.online) {
      note = SenseControllerStrings.healthOffline(seenAgo);
    } else if (h == null) {
      note = SenseControllerStrings.healthLoading;
    } else if (lines.isEmpty) {
      note = SenseControllerStrings.healthMissing;
    } else {
      note = null;
    }
    final footer = dataAgo ?? (c.online ? null : seenAgo);
    return Container(
      key: Key('sense-health-${c.id}'),
      width: _kTipWidth,
      padding: const EdgeInsets.symmetric(vertical: _kTipPadV, horizontal: _kTipPadH),
      decoration: BoxDecoration(
        color: SenseColors.surface,
        border: Border.all(
            color: level == SenseLevel.hot
                ? SenseColors.hot.withOpacity(0.6)
                : level == SenseLevel.warn
                    ? SenseColors.warn.withOpacity(0.5)
                    : SenseColors.line),
        borderRadius: BorderRadius.circular(SenseRadii.categoryLarge + 1),
        boxShadow: [
          BoxShadow(color: SenseColors.bg.withOpacity(0.7), blurRadius: _kTipShadow, offset: const Offset(0, _kTipShadowY)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            SenseLed(level: level, size: _kSmallLed, blink: false),
            const SizedBox(width: SenseUi.iconGap + 1),
            Text(title, style: SenseTextStyles.of(weight: SenseFontWeight.bold, color: titleColor)),
            const SizedBox(width: SenseUi.iconGap),
            Expanded(
              child: Text(c.name,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim)),
            ),
          ]),
          const SizedBox(height: SenseUi.iconGap),
          for (var i = 0; i < lines.length; i++)
            SenseCardRow(
              label: lines[i].label,
              value: lines[i].value,
              level: lines[i].level,
              last: i == lines.length - 1,
            ),
          if (note != null)
            Text(note, style: SenseTextStyles.of(size: SenseFontSize.hintSmall, color: SenseColors.textDim, height: 1.5)),
          if (footer != null) ...[
            const SizedBox(height: SenseUi.iconGap),
            Text(SenseControllerStrings.healthFooter(footer),
                style: SenseTextStyles.of(size: SenseFontSize.capsSmall, color: SenseColors.textDim)),
          ],
        ],
      ),
    );
  }
}

/// Hover state for a box that is not a button (tile frame `.pc2:hover`).
class SenseHover extends StatefulWidget {
  const SenseHover({super.key, required this.builder});
  final Widget Function(bool hovered) builder;

  @override
  State<SenseHover> createState() => _SenseHoverState();
}

class _SenseHoverState extends State<SenseHover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: widget.builder(_hovered),
      );
}
