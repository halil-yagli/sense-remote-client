// Sense Remote: what the "Ekran bilgisi" popup shows (YH O9; img c07, s07).
// Displays come from the panel (peer-status `displays`, EDID / connection /
// colour), the geometry and the live numbers from the session (RustDesk).
// Warning colour: a display whose refresh rate differs from the others, a
// YCbCr 4:2:2 / 4:2:0 signal, a slow frame rate (T6) and latency (#135: 150 / 300 ms, tokens).
import '../../../../tokens/sense_tokens.dart';
import '../../data/peer_status.dart';
import '../../data/screen_still.dart';
import '../status/status_format.dart';
import '../status/status_model.dart';
import '../status/status_strings.dart';
import 'display_data.dart';

export '../../data/screen_still.dart'
    show kSenseSessionLatency, kSenseStillMaxMbit, kSenseStillFrameAgeMs, kSenseStillMaxLossPct;

typedef _D = SenseDisplayStrings;

// kSenseSessionLatency and the still-screen limits live in ../../data/screen_still.dart
// (one rule for Ekran bilgisi, the link layer and the link card; denetim K44).

class SenseDisplayView {
  const SenseDisplayView({
    required this.liveText,
    required this.subtitle,
    required this.meters,
    required this.categories,
  });

  /// "3 ekran · Ekran 1 izleniyor".
  final String liveText;

  /// Header: "Ekran 1".
  final String subtitle;
  final List<SenseStatusRow> meters;
  final List<SenseStatusCategory> categories;

  SenseLevel get level {
    final ls = categories.map((c) => c.level).where((l) => l != SenseLevel.unknown);
    return ls.isEmpty ? SenseLevel.ok : senseWorstLevel(ls);
  }

  String get title => switch (level) {
        SenseLevel.hot => SenseStatusStrings.hot,
        SenseLevel.warn => SenseStatusStrings.warn,
        _ => SenseStatusStrings.allOk,
      };

  List<SenseStatusCategory> get alerts =>
      categories.where((c) => c.level == SenseLevel.warn || c.level == SenseLevel.hot).toList();
}

String senseDisplayName(int index, {bool primary = false}) =>
    primary ? _D.displayPrimary(index + 1) : _D.display(index + 1);

String? _colorFormat(String? f) => switch (f) {
      'rgb' => 'RGB 4:4:4',
      'ycbcr444' => 'YCbCr 4:4:4',
      'ycbcr422' => 'YCbCr 4:2:2',
      'ycbcr420' => 'YCbCr 4:2:0',
      _ => null,
    };

String? _connectionLong(String? c) => switch (c) {
      'hdmi' => 'HDMI',
      'displayport' => 'DisplayPort',
      'dvi' => 'DVI',
      'vga' => 'VGA',
      'usb_c' => 'USB-C',
      'internal' => 'Dahili',
      'other' => 'Diğer',
      _ => null,
    };

String? _quality(String? q) => switch (q) {
      'best' => _D.qualityBest,
      'balanced' => _D.qualityBalanced,
      'low' => _D.qualityLow,
      'custom' => _D.qualityCustom,
      _ => null,
    };

String? _join(Iterable<String?> parts, [String sep = ' · ']) {
  final p = parts.whereType<String>().where((s) => s.isNotEmpty).toList();
  return p.isEmpty ? null : p.join(sep);
}

/// Sürüm 10 (#118): a low frame rate on a still screen is normal (RustDesk sends a frame only
/// when the picture changed). The rule itself is [senseStillScreen] (K44: one rule everywhere).
bool senseScreenStill(SenseSessionVideo video) => senseStillScreen(
      fps: video.fps,
      rttMs: video.rttMs,
      lossPct: video.lossEstPct,
      mbit: video.bandwidthMbit,
      frameAgeMs: video.frameAgeMs,
    );

/// The refresh rate most displays use (ties: the primary display's).
double? _commonHz(List<SensePeerDisplay> ds) {
  final counts = <double, int>{};
  for (final d in ds) {
    final hz = d.refreshHz;
    if (hz != null) counts[hz.roundToDouble()] = (counts[hz.roundToDouble()] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  final best = counts.values.reduce((a, b) => a > b ? a : b);
  final tops = counts.entries.where((e) => e.value == best).map((e) => e.key).toList();
  if (tops.length == 1) return tops.first;
  for (final d in ds) {
    if (d.primary == true && d.refreshHz != null && tops.contains(d.refreshHz!.roundToDouble())) {
      return d.refreshHz!.roundToDouble();
    }
  }
  return null; // no majority and no primary: nothing to compare against
}

SenseDisplayView senseBuildDisplayView({
  required List<SensePeerDisplay> panel,
  required SenseSessionVideo video,
  SenseStatusPlatform platform = SenseStatusPlatform.unknown,
}) {
  // Sürüm 11 (#124): macOS gives no external monitor's connection type and no colour format;
  // its HDR value says whether the screen can show HDR (not whether it is on).
  final mac = platform == SenseStatusPlatform.mac;
  // Every display either side knows, by index.
  final indexes = <int>{for (final d in panel) d.index, for (final d in video.displays) d.index}.toList()..sort();
  SensePeerDisplay? p(int i) => panel.where((d) => d.index == i).firstOrNull;
  SenseSessionDisplay? g(int i) => video.displays.where((d) => d.index == i).firstOrNull;
  final common = indexes.length > 1 ? _commonHz(panel) : null;

  final categories = <SenseStatusCategory>[];
  for (final i in indexes) {
    final pd = p(i), gd = g(i);
    final w = pd?.width ?? gd?.width, h = pd?.height ?? gd?.height;
    final hz = pd?.refreshHz;
    final hzOff = common != null && hz != null && hz.roundToDouble() != common;
    final fmt = pd?.colorFormat;
    final subsampled = fmt == 'ycbcr422' || fmt == 'ycbcr420';
    String? res;
    if (w != null && h != null) {
      final size = senseRes(w, h, spaced: true);
      final nw = pd?.nativeWidth, nh = pd?.nativeHeight;
      if (nw == null || nh == null) {
        res = size;
      } else if (nw == w && nh == h) {
        res = _D.nativeSize(size);
      } else {
        res = _D.nativeOther(size, senseRes(nw, nh, spaced: true));
      }
    }
    final x = pd?.x ?? gd?.x, y = pd?.y ?? gd?.y;
    final colour = _join([pd?.bitDepth == null ? null : '${pd!.bitDepth} bit', _colorFormat(fmt)]);
    categories.add(SenseStatusCategory(
      id: 'display-$i',
      title: senseDisplayName(i, primary: pd?.primary == true),
      summary: _join([
        w == null || h == null ? null : senseRes(w, h),
        hz == null ? null : senseHz(hz),
        senseConnectionShort(pd?.connection),
      ]),
      rows: [
        SenseStatusLine(_D.monitor, pd?.name),
        SenseStatusLine(_D.connection, _connectionLong(pd?.connection), notReported: mac && pd != null),
        SenseStatusLine(_D.resolution, res),
        SenseStatusLine(_D.scale, pd?.scale == null ? null : '%${(pd!.scale! * 100).round()}'),
        SenseStatusLine(
          _D.refresh,
          hz == null ? null : (hzOff ? '${senseHz(hz)} ${_D.othersHz(senseHz(common!))}' : senseHz(hz)),
          valueLevel: hzOff ? SenseLevel.warn : null,
        ),
        SenseStatusLine(_D.color, colour, valueLevel: subsampled ? SenseLevel.warn : null, notReported: mac && pd != null),
        SenseStatusLine(
            _D.hdr,
            pd?.hdr == null
                ? null
                : mac
                    ? (pd!.hdr! ? _D.hdrCapable : _D.hdrNotCapable)
                    : (pd!.hdr! ? _D.hdrOn : _D.hdrOff),
            notReported: mac && pd != null),
        SenseStatusLine(_D.position, x == null || y == null ? null : '$x, $y'),
        if (subsampled) SenseStatusNote('${_colorFormat(fmt)}: ${_D.ycbcrNote}'),
      ],
    ));
  }

  // Session image.
  final fps = video.fps;
  final watchedHz = video.watchingAll ? null : p(video.watched)?.refreshHz;
  final target = watchedHz?.round();
  final fpsPct = fps == null ? null : (target == null ? 100.0 : (fps * 100 / target).clamp(0, 100).toDouble());
  // #118: a still screen sends few frames on purpose: no warning, "durağan" next to the rate.
  final still = senseScreenStill(video);
  final fpsLevel = still ? SenseLevel.ok : SenseThresholds.frameRate.levelOf(fps);
  final rtt = video.rttMs;
  final rttLevel = SenseThresholds.latency.levelOf(rtt); // #135: one limit everywhere (150 / 300)
  final fpsText = fps == null ? null : (still ? '${fps.round()} fps · ${_D.still}' : '${fps.round()} fps');
  final rttText = rtt == null ? null : '${rtt.round()} ms';
  final fpsMeter = SenseStatusMeter(_D.frameRate, fpsPct, fpsText, barLevel: fpsLevel);
  final rttMeter = SenseStatusMeter(_D.latency, rtt == null ? null : rtt.clamp(0, 100).toDouble(), rttText,
      barLevel: rttLevel);
  final path = video.direct == null ? null : (video.direct! ? _D.pathDirect : _D.pathRelay);
  final codec = video.codec;
  final quality = _quality(video.quality);
  final loss = video.lossEstPct;

  categories.add(SenseStatusCategory(
    id: 'session',
    title: _D.session,
    summary: _join([codec, fpsText, rttText]),
    rows: [
      SenseStatusLine(_D.pathType, video.direct == null ? null : (video.direct! ? _D.pathDirectLong : _D.pathRelayLong)),
      SenseStatusLine(_D.codec, codec),
      SenseStatusLine(_D.quality, quality),
      fpsMeter,
      rttMeter,
      SenseStatusLine(_D.bandwidth,
          video.bandwidthMbit == null ? null : '${senseNum(video.bandwidthMbit!)} Mbit/s'),
      SenseStatusLine(_D.lostFrames, loss == null ? null : _D.estimated(sensePct(loss))),
    ],
  ));

  final count = indexes.length;
  final watchedName = video.watchingAll ? _D.allDisplays : _D.display(video.watched + 1);
  return SenseDisplayView(
    liveText: _D.watching(count, watchedName),
    subtitle: video.watchingAll ? _D.allDisplays : _D.display(video.watched + 1),
    meters: [
      SenseStatusMeter(_D.frameRate, fpsPct,
          fps == null
              ? null
              : (target == null ? fpsText : '${fps.round()} / $target fps${still ? ' · ${_D.still}' : ''}'),
          barLevel: fpsLevel),
      rttMeter,
      SenseStatusLine(_D.connection, _join([path, codec, quality])),
    ],
    categories: categories,
  );
}
