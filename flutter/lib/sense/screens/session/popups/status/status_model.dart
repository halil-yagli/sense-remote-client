// Sense Remote: what the "Bilgisayar durumu" popup shows, built from
// peer-status (YH O8; contract Calisma/plan/2026-11-23_saglik-sozlesmesi.md).
// Pure Dart: every row is either a value from the panel or null ("okunamadı",
// drawn faded and italic). Colours follow the T6 thresholds (SenseThresholds).
// A closed category takes the worst level inside it.
import '../../../../tokens/sense_tokens.dart';
import '../../data/peer_status.dart';
import 'status_format.dart';
import 'status_strings.dart';

typedef _S = SenseStatusStrings;

// ------------------------------------------------------------------ rows

/// One line of a popup body.
sealed class SenseStatusRow {
  const SenseStatusRow();

  /// Level used for the category / card colour; null = not a measurement.
  SenseLevel? get level => null;

  /// Plain text for Kopyala.
  String get copyText;
}

/// "Label ··· value" (`.r`). Null value = "okunamadı".
class SenseStatusLine extends SenseStatusRow {
  const SenseStatusLine(this.label, this.value,
      {this.valueLevel, this.tag, this.tagStrong = false, this.notReported = false});

  final String label;
  final String? value;

  /// Sürüm 11 (#124): a missing value the computer never gives (sensor / firmware has none):
  /// "bu bilgisayar bildirmiyor" instead of "okunamadı". Only used with a null [value].
  final bool notReported;

  /// What the row shows: the value, or why there is none.
  String get shownValue => value ?? (notReported ? _S.notReported : _S.unreadable);

  /// Coloured value (warn / hot); ok and null stay white.
  final SenseLevel? valueLevel;

  /// Small tag after the value (STATİK white, DHCP grey).
  final String? tag;
  final bool tagStrong;

  @override
  SenseLevel? get level => valueLevel;

  @override
  String get copyText => '$label: $shownValue${tag == null ? '' : ' ($tag)'}';
}

/// Meter row (`.mt`): label, 6 px bar, value. [pct] null = bar empty and the
/// value "okunamadı".
class SenseStatusMeter extends SenseStatusRow {
  const SenseStatusMeter(this.label, this.pct, this.text,
      {required this.barLevel, SenseLevel? valueLevel, this.traffic})
      : _valueLevel = valueLevel;

  /// Download / upload figures of a traffic row; drawn with arrow icons ([text] stays the
  /// plain copy text).
  final SenseTraffic? traffic;

  final String label;
  final double? pct;
  final String? text;
  final SenseLevel barLevel;
  final SenseLevel? _valueLevel;

  /// Text colour: the worse of the bar and an extra value (temperature).
  SenseLevel get valueLevel => _valueLevel ?? barLevel;

  @override
  SenseLevel? get level => pct == null && text == null ? SenseLevel.unknown : valueLevel;

  @override
  String get copyText => '$label: ${text ?? _S.unreadable}';
}

/// "12" down, "3" up, in Mbit/s.
class SenseTraffic {
  const SenseTraffic(this.down, this.up);
  final String down;
  final String up;
}

/// Small upper-case group title (`.gt2`).
class SenseStatusGroup extends SenseStatusRow {
  const SenseStatusGroup(this.title);
  final String title;

  @override
  String get copyText => title;
}

/// Grey note (`.hint2`).
class SenseStatusNote extends SenseStatusRow {
  const SenseStatusNote(this.text);
  final String text;

  @override
  String get copyText => text;
}

/// A whole list could not be read: one faded "okunamadı".
class SenseStatusUnreadable extends SenseStatusRow {
  const SenseStatusUnreadable();

  @override
  SenseLevel? get level => SenseLevel.unknown;

  @override
  String get copyText => _S.unreadable;
}

/// One object with its own Kopyala (`.sc`): a GPU, a disk, an adapter.
class SenseStatusCard extends SenseStatusRow {
  const SenseStatusCard(this.title, this.rows, {this.tags = const []});

  final String title;
  final List<String> tags;
  final List<SenseStatusRow> rows;

  @override
  SenseLevel get level => senseRowsLevel(rows);

  @override
  String get copyText => [
        [title, ...tags.map((t) => '($t)')].join(' '),
        for (final r in rows)
          if (r is! SenseStatusNote) r.copyText,
      ].join('\n');
}

/// Worst level of [rows] (T6): hot > warn > ok; unknown only when nothing was read.
SenseLevel senseRowsLevel(Iterable<SenseStatusRow> rows) {
  final levels = <SenseLevel>[];
  for (final r in rows) {
    final l = r.level;
    if (l != null) levels.add(l);
  }
  if (levels.isEmpty) return SenseLevel.ok;
  return senseWorstLevel(levels);
}

// ------------------------------------------------------------------ view

class SenseStatusCategory {
  const SenseStatusCategory({required this.id, required this.title, this.summary, required this.rows, SenseLevel? level})
      : _level = level;

  final String id;
  final String title;
  final String? summary;
  final List<SenseStatusRow> rows;
  final SenseLevel? _level;

  SenseLevel get level => _level ?? senseRowsLevel(rows);
}

class SenseStatusView {
  const SenseStatusView({required this.meters, required this.categories});

  /// Rows of the overall box.
  final List<SenseStatusMeter> meters;
  final List<SenseStatusCategory> categories;

  /// Worst category; drives the box frame and title.
  SenseLevel get level {
    final ls = categories.map((c) => c.level).where((l) => l != SenseLevel.unknown);
    return ls.isEmpty ? SenseLevel.ok : senseWorstLevel(ls);
  }

  String get title => switch (level) {
        SenseLevel.hot => _S.hot,
        SenseLevel.warn => _S.warn,
        _ => _S.allOk,
      };

  /// Categories that get an alert tag.
  List<SenseStatusCategory> get alerts =>
      categories.where((c) => c.level == SenseLevel.warn || c.level == SenseLevel.hot).toList();
}

SenseLevel _usage(double? pct) => SenseThresholds.usage.levelOf(pct);
SenseLevel _chip(double? c) => SenseThresholds.chipTemp.levelOf(c);
SenseLevel _diskT(double? c) => SenseThresholds.diskTemp.levelOf(c);

/// Meter value level: worse of [a] and [b], ignoring unknown.
SenseLevel _worse(SenseLevel a, SenseLevel b) {
  final ls = [a, b].where((l) => l != SenseLevel.unknown);
  return ls.isEmpty ? SenseLevel.ok : senseWorstLevel(ls);
}

String? _join(Iterable<String?> parts, [String sep = ' · ']) {
  final p = parts.whereType<String>().where((s) => s.isNotEmpty).toList();
  return p.isEmpty ? null : p.join(sep);
}

/// Sürüm 11 (#124): the computer's operating system decides which rows exist at all. A value
/// macOS has no notion of (base clock, memory slots, graphics driver version, power plan …) is
/// not drawn on a Mac; Windows has no "start after power loss" reading.
enum SenseStatusPlatform { windows, mac, unknown }

/// From the panel's `platform` ("windows-x64", "macos-arm64") when it sends it, else from the
/// inventory (operating system name, board maker); unknown when neither says.
SenseStatusPlatform senseStatusPlatform(SensePeerStatusFull full) {
  final p = full.platform?.toLowerCase();
  if (p != null) {
    if (p.startsWith('mac')) return SenseStatusPlatform.mac;
    if (p.startsWith('win')) return SenseStatusPlatform.windows;
  }
  final inv = full.inventory;
  final os = inv?.os?.name?.toLowerCase() ?? '';
  if (os.startsWith('macos') || inv?.boardManufacturer == 'Apple') return SenseStatusPlatform.mac;
  if (os.contains('windows')) return SenseStatusPlatform.windows;
  return SenseStatusPlatform.unknown;
}

typedef _P = SenseStatusPlatform;

/// Builds the popup content. [now] is only for nothing time-related here.
SenseStatusView senseBuildStatusView(SensePeerStatusFull full) {
  final st = full.status;
  final h = full.health;
  final inv = full.inventory;
  final os = senseStatusPlatform(full);

  final cpu = _cpu(h, inv, os);
  final gpu = _gpu(h, inv, os);
  final mem = _memory(h, inv, os);
  final disk = _storage(h, inv, os);
  final net = _network(st, h, inv, os);
  final disp = _displays(st);
  final comp = _components(inv, os);
  final soft = _software(st, h, inv, os);

  return SenseStatusView(
    meters: _overview(h, inv),
    categories: [cpu, gpu, mem, disk, net, disp, comp, soft],
  );
}

// ------------------------------------------------------------------ overview

List<SenseStatusMeter> _overview(SenseHealthDetail? h, SenseInventory? inv) {
  final out = <SenseStatusMeter>[];
  // İşlemci: % · °C
  out.add(_pctTemp(_S.cpu, h?.cpuPct, h?.cpuTempC, _chip));
  out.add(_pctTemp(_S.gpu, h?.gpuPct, h?.gpuTempC, _chip));
  final used = h?.memUsedMb, total = h?.memTotalMb;
  final memPct = used != null && total != null ? used * 100 / total : null;
  out.add(SenseStatusMeter(_S.memory, memPct, used != null && total != null ? senseUsedOfTotalMb(used, total) : null,
      barLevel: _usage(memPct)));
  for (final d in h?.disks ?? const <SenseHealthDisk>[]) {
    final temp = _diskTempFor(d.mount, h, inv);
    out.add(_pctTemp(_S.disk(d.mount), d.usedPct, temp, _diskT));
  }
  out.add(_trafficMeter(_S.network, h?.netIo, inv?.network, null));
  return out;
}

SenseStatusMeter _pctTemp(String label, double? pct, double? temp, SenseLevel Function(double?) tempLevel) {
  final text = _join([pct == null ? null : sensePct(pct), temp == null ? null : senseTemp(temp)]);
  final bar = _usage(pct);
  return SenseStatusMeter(label, pct, text, barLevel: bar, valueLevel: _worse(bar, tempLevel(temp)));
}

double? _diskTempFor(String mount, SenseHealthDetail? h, SenseInventory? inv) {
  final invDisks = inv?.physicalDisks ?? const <SenseInvDisk>[];
  for (final d in invDisks) {
    if (d.mounts.contains(mount)) {
      for (final p in h?.physicalDisks ?? const <SenseHealthPhysicalDisk>[]) {
        if (p.id == d.id) return p.tempC;
      }
    }
  }
  // Sürüm 11 (#119): without an inventory disk list (Windows Hosts up to Sürüm 10 never had
  // one), a computer with a single physical disk has every volume on it.
  final live = h?.physicalDisks ?? const <SenseHealthPhysicalDisk>[];
  if (invDisks.isEmpty && live.length == 1) return live.first.tempC;
  return null;
}

/// Traffic meter: whole computer ([only] null) or one adapter. Bar = busiest
/// direction against the link speed when known.
SenseStatusMeter _trafficMeter(
    String label, List<SenseHealthNetIo>? io, List<SenseInvNetwork>? adapters, SenseHealthNetIo? only) {
  final list = only != null ? [only] : (io ?? const <SenseHealthNetIo>[]);
  if (list.isEmpty) return SenseStatusMeter(label, null, null, barLevel: SenseLevel.unknown);
  var rx = 0.0, tx = 0.0;
  double? pct;
  for (final n in list) {
    rx += senseMbit(n.rxBps);
    tx += senseMbit(n.txBps);
    final speed = _adapterFor(n.name, adapters)?.speedMbps;
    if (speed != null) {
      final p = (senseMbit(n.rxBps) > senseMbit(n.txBps) ? senseMbit(n.rxBps) : senseMbit(n.txBps)) * 100 / speed;
      pct = pct == null || p > pct ? p : pct;
    }
  }
  final shown = pct?.clamp(0, 100).toDouble();
  return SenseStatusMeter(label, shown ?? 0, senseTraffic(rx, tx),
      barLevel: shown == null ? SenseLevel.ok : _usage(shown),
      traffic: SenseTraffic(senseMbitText(rx), senseMbitText(tx)));
}

SenseInvNetwork? _adapterFor(String name, List<SenseInvNetwork>? adapters) {
  for (final a in adapters ?? const <SenseInvNetwork>[]) {
    if (a.name == name || a.device == name) return a;
  }
  return null;
}

// ------------------------------------------------------------------ İşlemci

SenseStatusCategory _cpu(SenseHealthDetail? h, SenseInventory? inv, SenseStatusPlatform os) {
  final c = inv?.cpu;
  final pct = h?.cpuPct, temp = h?.cpuTempC;
  final cores = c?.cores, threads = c?.threads;
  final base = c?.baseMhz, cur = h?.cpuMhz;
  final procs = h?.topProcesses;
  return SenseStatusCategory(
    id: 'cpu',
    title: _S.cpu,
    summary: _join([c?.model == null ? null : senseShortCpu(c!.model!), pct == null ? null : sensePct(pct),
      temp == null ? null : senseTemp(temp)]),
    rows: [
      SenseStatusMeter(_S.usage, pct, pct == null ? null : sensePct(pct), barLevel: _usage(pct)),
      SenseStatusLine(_S.temperature, temp == null ? null : senseTemp(temp), valueLevel: _chip(temp)),
      SenseStatusLine(_S.model, c?.model),
      SenseStatusLine(_S.coresThreads,
          cores == null && threads == null ? null : '${cores ?? _S.unreadable} / ${threads ?? _S.unreadable}'),
      // Apple Silicon publishes neither a base nor a current clock (Sürüm 11).
      if (os != _P.mac || base != null || cur != null)
        SenseStatusLine(_S.baseCurrentSpeed,
            base == null && cur == null ? null : '${base == null ? _S.unreadable : senseGhz(base)} / ${cur == null ? _S.unreadable : senseGhz(cur)} GHz'),
      const SenseStatusGroup(_S.topProcesses),
      if (procs == null)
        const SenseStatusUnreadable()
      else
        for (final p in procs) SenseStatusLine(p.name, sensePct(p.cpuPct)),
    ],
  );
}

// ------------------------------------------------------------------ Ekran kartı

/// Sürüm 10 (#117): card names are compared without case and extra spaces (WMI and DXGI
/// write the same card's name slightly differently on some drivers).
String? _gpuKey(String? name) => name?.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

bool _gpuHasLive(SenseHealthGpu g) =>
    g.utilPct != null || g.vramUsedMb != null || g.tempC != null || g.fanPct != null || g.powerW != null;

SenseStatusCategory _gpu(SenseHealthDetail? h, SenseInventory? inv, SenseStatusPlatform os) {
  final cards = <SenseStatusCard>[];
  final live = List<SenseHealthGpu>.of(h?.gpus ?? const []);
  // A live entry with values is matched first, so a card listed twice by an older Host (one
  // entry without any value) never takes the inventory's place.
  int liveFor(String name) {
    final k = _gpuKey(name);
    final withValues = live.indexWhere((x) => _gpuKey(x.name) == k && _gpuHasLive(x));
    return withValues >= 0 ? withValues : live.indexWhere((x) => _gpuKey(x.name) == k);
  }

  final shown = <String?>{};
  for (final g in inv?.gpus ?? const <SenseInvGpu>[]) {
    final i = liveFor(g.name);
    cards.add(_gpuCard(g.name, g, i >= 0 ? live.removeAt(i) : null, os));
    shown.add(_gpuKey(g.name));
  }
  // Live-only cards; an entry without values whose name is already shown is the same card twice.
  final liveKeys = {for (final x in live.where(_gpuHasLive)) _gpuKey(x.name)};
  for (final x in live) {
    final k = _gpuKey(x.name);
    if (!_gpuHasLive(x) && k != null && (shown.contains(k) || liveKeys.contains(k))) continue;
    cards.add(_gpuCard(x.name ?? _S.gpu, null, x, os));
    shown.add(k);
  }
  // Summary: the busiest card (the one v1 gpu_pct / gpu_temp_c describe).
  String? name;
  if (inv?.gpus != null) {
    final discrete = inv!.gpus!.where((g) => g.integrated != true);
    name = (discrete.isNotEmpty ? discrete.first : (inv.gpus!.isEmpty ? null : inv.gpus!.first))?.name;
  }
  return SenseStatusCategory(
    id: 'gpu',
    title: _S.gpu,
    summary: _join([name == null ? null : senseShortGpu(name), h?.gpuPct == null ? null : sensePct(h!.gpuPct!),
      h?.gpuTempC == null ? null : senseTemp(h!.gpuTempC!)]),
    rows: cards.isEmpty
        ? [
            SenseStatusMeter(_S.usage, h?.gpuPct, h?.gpuPct == null ? null : sensePct(h!.gpuPct!),
                barLevel: _usage(h?.gpuPct)),
            SenseStatusLine(_S.temperature, h?.gpuTempC == null ? null : senseTemp(h!.gpuTempC!),
                valueLevel: _chip(h?.gpuTempC)),
          ]
        : cards,
  );
}

/// Sürüm 11 (#124): only NVIDIA's driver tool gives a card's temperature, fan and power on
/// Windows; AMD / Intel discrete cards publish none (no documented interface).
bool _isNvidia(String name) {
  final n = name.toLowerCase();
  return n.contains('nvidia') || n.contains('geforce') || n.contains('quadro') || n.contains('tesla');
}

SenseStatusCard _gpuCard(String name, SenseInvGpu? inv, SenseHealthGpu? live, SenseStatusPlatform os) {
  final integrated = inv?.integrated == true;
  final util = live?.utilPct;
  final used = live?.vramUsedMb;
  final total = live?.vramTotalMb ?? inv?.vramMb;
  final vramPct = used != null && total != null ? used * 100 / total : null;
  final temp = live?.tempC;
  // Windows: a non-NVIDIA card never reports these; an NVIDIA card that reports its temperature
  // but no fan (laptop, "[N/A]") or power has none to report.
  final noSensors = os == _P.windows && !_isNvidia(name);
  final nvidiaSaysNa = os == _P.windows && _isNvidia(name) && temp != null;
  return SenseStatusCard(
    name,
    tags: integrated ? const [_S.integrated] : const [],
    [
      SenseStatusMeter(_S.usage, util, util == null ? null : sensePct(util), barLevel: _usage(util)),
      // A Mac's integrated GPU uses the computer's memory; its total is the installed memory
      // (Sürüm 11: "Paylaşılan bellek").
      SenseStatusMeter(integrated && os == _P.mac ? _S.sharedMemory : _S.vram, vramPct,
          used != null && total != null ? senseUsedOfTotalMb(used, total) : null,
          barLevel: _usage(vramPct)),
      // An integrated GPU shares the processor's sensors: no own temperature, fan or power. On a
      // Mac no GPU publishes them (Sürüm 11).
      if (!integrated && os != _P.mac) ...[
        SenseStatusLine(_S.temperature, temp == null ? null : senseTemp(temp),
            valueLevel: _chip(temp), notReported: noSensors),
        SenseStatusLine(_S.fan, live?.fanPct == null ? null : sensePct(live!.fanPct!),
            notReported: noSensors || nvidiaSaysNa),
        SenseStatusLine(_S.power, live?.powerW == null ? null : '${live!.powerW!.round()} W',
            notReported: noSensors || nvidiaSaysNa),
      ],
      // The graphics driver is part of macOS (no version of its own).
      if (os != _P.mac || inv?.driverVersion != null) ...[
        SenseStatusLine(_S.driverVersion, inv?.driverVersion),
        SenseStatusLine(_S.driverDate, inv?.driverDate == null ? null : senseDate(inv!.driverDate!)),
      ],
    ],
  );
}

// ------------------------------------------------------------------ Bellek

SenseStatusCategory _memory(SenseHealthDetail? h, SenseInventory? inv, SenseStatusPlatform os) {
  final mac = os == _P.mac;
  final used = h?.memUsedMb;
  final total = h?.memTotalMb ?? inv?.memory?.totalMb;
  final pct = used != null && total != null ? used * 100 / total : null;
  final usedText = used != null && total != null ? senseUsedOfTotalMb(used, total) : null;
  final swapU = h?.swapUsedMb, swapT = h?.swapTotalMb;
  final mods = inv?.memory?.modules;
  final slots = inv?.memory?.slotsTotal;
  return SenseStatusCategory(
    id: 'memory',
    title: _S.memory,
    summary: _join([usedText, pct == null ? null : sensePct(pct)]),
    rows: [
      SenseStatusMeter(_S.used, pct, usedText, barLevel: _usage(pct)),
      SenseStatusLine(_S.available, h?.memAvailableMb == null ? null : senseSizeMb(h!.memAvailableMb!)),
      SenseStatusLine(_S.swap, swapU != null && swapT != null ? senseUsedOfTotalMb(swapU, swapT) : null),
      const SenseStatusGroup(_S.installedMemory),
      if (mods == null)
        const SenseStatusUnreadable()
      else
        for (var i = 0; i < mods.length; i++)
          // A Mac's memory is soldered unified memory: one entry, no slot (Sürüm 11).
          SenseStatusLine(mods[i].slot ?? (mac ? _S.unifiedMemory : _S.slot(i + 1)), _module(mods[i])),
      if (!mac || slots != null)
        SenseStatusLine(_S.freeSlots, slots == null || mods == null ? null : '${slots - mods.length} / $slots'),
    ],
  );
}

String? _module(SenseInvMemoryModule m) {
  final kind = m.kind == null ? null : (m.speedMts == null ? m.kind : '${m.kind}-${m.speedMts}');
  final size = _join([m.sizeMb == null ? null : senseSizeMb(m.sizeMb!), kind], ' ');
  final maker = _join([m.manufacturer, m.model], ' ');
  return _join([size, maker]);
}

// ------------------------------------------------------------------ Depolama

/// Disk temperature row; none on a Mac (no public interface, Sürüm 11).
List<SenseStatusRow> _diskTemp(SenseHealthPhysicalDisk? live, SenseStatusPlatform os) {
  final temp = live?.tempC;
  return [
    if (os != _P.mac || temp != null)
      SenseStatusLine(_S.temperature, temp == null ? null : senseTemp(temp), valueLevel: _diskT(temp)),
  ];
}

SenseStatusLine _diskRates(SenseHealthPhysicalDisk? live) => SenseStatusLine(_S.readWrite,
    live?.readBps == null || live?.writeBps == null ? null : '${senseMBps(live!.readBps!)} / ${senseMBps(live.writeBps!)} MB/s');

SenseStatusCategory _storage(SenseHealthDetail? h, SenseInventory? inv, SenseStatusPlatform os) {
  final volumes = h?.disks ?? const <SenseHealthDisk>[];
  final used = <String>{};
  final cards = <SenseStatusCard>[];
  final liveDisks = List<SenseHealthPhysicalDisk>.of(h?.physicalDisks ?? const []);
  final invDisks = inv?.physicalDisks ?? const <SenseInvDisk>[];
  for (final d in invDisks) {
    final at = liveDisks.indexWhere((p) => p.id == d.id);
    final live = at >= 0 ? liveDisks.removeAt(at) : null;
    final rows = <SenseStatusRow>[];
    for (final m in d.mounts) {
      final v = volumes.where((x) => x.mount == m).firstOrNull;
      used.add(m);
      rows.add(_volumeMeter(m, v));
    }
    rows
      ..addAll(_diskTemp(live, os))
      ..add(_diskHealth(d))
      // Sürüm 9 (O8): lifetime total if read; macOS only knows since boot (own label); else "okunamadı".
      ..add(senseWrittenLine(live))
      ..add(_diskRates(live))
      ..add(SenseStatusLine(_S.firmware, d.firmware));
    cards.add(SenseStatusCard(d.model, rows, tags: [if (_diskTag(d) != null) _diskTag(d)!]));
  }
  // Sürüm 11 (#119): disks the computer measures but the inventory does not list (a Windows
  // Host up to Sürüm 10 sent no disk list) still show their temperature, written total and
  // rates. A single physical disk carries the volumes; with several they stay separate. With an
  // inventory list, a measured disk it does not have (a mounted disk image on a Mac) is left out
  // as before.
  final volumesOnLive = invDisks.isEmpty && liveDisks.length == 1;
  for (final p in invDisks.isEmpty ? liveDisks : const <SenseHealthPhysicalDisk>[]) {
    final rows = <SenseStatusRow>[
      if (volumesOnLive)
        for (final v in volumes) _volumeMeter(v.mount, v),
      ..._diskTemp(p, os),
      senseWrittenLine(p),
      _diskRates(p),
    ];
    if (volumesOnLive) used.addAll(volumes.map((v) => v.mount));
    cards.add(SenseStatusCard(_S.physicalDisk(p.id), rows));
  }
  // Volumes the inventory does not place on a disk (or no inventory at all).
  for (final v in volumes) {
    if (used.contains(v.mount)) continue;
    cards.add(SenseStatusCard(_S.disk(v.mount), [_volumeMeter(v.mount, v)]));
  }
  return SenseStatusCategory(
    id: 'storage',
    title: _S.storage,
    summary: _join([for (final v in volumes) '${v.mount} ${sensePct(v.usedPct)}']),
    rows: cards.isEmpty ? const [SenseStatusUnreadable()] : cards,
  );
}

SenseStatusMeter _volumeMeter(String mount, SenseHealthDisk? v) {
  final name = v?.label == null ? mount : '$mount ${v!.label}';
  if (v == null) return SenseStatusMeter(mount, null, null, barLevel: SenseLevel.unknown);
  final total = v.totalGb;
  final text = total == null ? sensePct(v.usedPct) : senseUsedOfTotalGb(total * v.usedPct / 100, total);
  return SenseStatusMeter(name, v.usedPct, text, barLevel: _usage(v.usedPct));
}

String? _diskTag(SenseInvDisk d) {
  final bus = switch (d.bus) {
    'nvme' => 'NVMe',
    'sata' => 'SATA',
    'usb' => 'USB',
    'sas' => 'SAS',
    'raid' => 'RAID',
    _ => null,
  };
  final media = switch (d.media) { 'ssd' => 'SSD', 'hdd' => 'HDD', _ => null };
  if (d.bus == 'nvme') return bus;
  return _join([bus, media], ' ');
}

SenseStatusLine _diskHealth(SenseInvDisk d) {
  final (text, level) = switch (d.health) {
    'ok' => (_S.healthOk, SenseLevel.ok),
    'warning' => (_S.healthWarning, SenseLevel.warn),
    'failing' => (_S.healthFailing, SenseLevel.hot),
    _ => (null, null),
  };
  final life = d.lifeLeftPct == null ? null : _S.lifeLeft(sensePct(d.lifeLeftPct!));
  return SenseStatusLine(_S.diskHealth, _join([text, life]), valueLevel: level);
}

// ------------------------------------------------------------------ Ağ

/// "192.168.10.42/24" → "192.168.10.42 /24" (prefix only when the peer sends one).
String _ipText(String ip) => ip.contains('/') ? ip.replaceFirst('/', ' /') : ip;

SenseStatusCategory _network(SensePeerStatus st, SenseHealthDetail? h, SenseInventory? inv, SenseStatusPlatform os) {
  final mac = os == _P.mac;
  // Adapters: the base list (IPs) joined with the inventory by name; inventory-only
  // adapters (unplugged ones) come after. Order: ethernet, Wi-Fi, other (#: kablolu önce).
  final entries = <({String name, String kind, SensePeerNetwork? base, SenseInvNetwork? inv})>[];
  final invList = List<SenseInvNetwork>.of(inv?.network ?? const []);
  for (final b in st.network) {
    final i = invList.indexWhere((x) => x.name == b.name);
    entries.add((name: b.name, kind: b.kind, base: b, inv: i >= 0 ? invList.removeAt(i) : null));
  }
  for (final x in invList) {
    entries.add((name: x.name, kind: x.kind ?? 'other', base: null, inv: x));
  }
  int rank(String k) => k == 'ethernet' ? 0 : (k == 'wifi' ? 1 : 2);
  final ordered = entries.asMap().entries.toList()
    ..sort((a, b) {
      final r = rank(a.value.kind).compareTo(rank(b.value.kind));
      return r != 0 ? r : a.key.compareTo(b.key);
    });

  final cards = <SenseStatusRow>[];
  String? firstIp;
  for (final e in ordered.map((x) => x.value)) {
    final i = e.inv;
    final b = e.base;
    final connected = i?.connected ?? b?.up;
    if (connected != false && firstIp == null && (b?.ipv4.isNotEmpty ?? false)) firstIp = b!.ipv4.first.split('/').first;
    final tag = connected == null
        ? null
        : connected
            ? _S.connected
            : (e.kind == 'wifi' ? _S.notConnected : _S.cableOut);
    // macOS names no adapter model; the card title already says Wi-Fi / Ethernet (Sürüm 11).
    final rows = <SenseStatusRow>[
      if (!mac || i?.description != null) SenseStatusLine(_S.card, i?.description),
    ];
    if (connected == false) {
      rows.add(SenseStatusLine(_S.mac, i?.mac));
    } else {
      if (e.kind == 'wifi') {
        final w = h?.wifi;
        rows.add(SenseStatusLine(_S.wifiName,
            _join([w?.ssid, w?.band, w?.signalPct == null ? null : _S.signal(sensePct(w!.signalPct!))])));
      }
      final dhcpTag = i?.dhcp == null ? null : (i!.dhcp! ? _S.tagDhcp : _S.tagStatic);
      final ips = b?.ipv4 ?? const <String>[];
      rows.add(SenseStatusLine(_S.ipv4, ips.isEmpty ? null : _ipText(ips.first),
          tag: ips.isEmpty ? null : dhcpTag, tagStrong: i?.dhcp == false));
      for (final ip in ips.skip(1)) {
        rows.add(SenseStatusLine(_S.ipv4Extra, _ipText(ip), tag: dhcpTag, tagStrong: i?.dhcp == false));
      }
      final v6 = b?.ipv6 ?? const <String>[];
      rows
        ..add(SenseStatusLine(_S.ipv6, v6.isEmpty ? null : v6.first))
        ..add(SenseStatusLine(_S.gateway, _join(i?.gateway ?? const [])))
        ..add(SenseStatusLine(_S.dns, _join(i?.dns ?? const [])))
        ..add(SenseStatusLine(_S.mac, i?.mac))
        ..add(SenseStatusLine(_S.speed, i?.speedMbps == null ? null : senseLinkSpeed(i!.speedMbps!)));
      SenseHealthNetIo? io;
      for (final n in h?.netIo ?? const <SenseHealthNetIo>[]) {
        if (n.name == e.name || (i?.device != null && n.name == i!.device)) io = n;
      }
      rows.add(io == null
          ? SenseStatusMeter(_S.traffic, null, null, barLevel: SenseLevel.unknown)
          : _trafficMeter(_S.traffic, null, inv?.network, io));
      // Network drivers are part of macOS (Sürüm 11).
      if (!mac || i?.driverVersion != null) rows.add(SenseStatusLine(_S.driverVersion, i?.driverVersion));
    }
    final title = e.name.isNotEmpty ? e.name : (e.kind == 'wifi' ? _S.wifi : _S.ethernet);
    cards.add(SenseStatusCard(title, rows, tags: [if (tag != null) tag]));
  }
  if (cards.isEmpty) {
    cards.add(const SenseStatusUnreadable());
  } else {
    cards.add(const SenseStatusNote(_S.networkNote));
  }
  final count = entries.length;
  return SenseStatusCategory(
    id: 'network',
    title: _S.network,
    summary: count == 0 ? null : _join([_S.adapters(count), firstIp]),
    rows: cards,
  );
}

// ------------------------------------------------------------------ Ekranlar

String? senseConnectionShort(String? c) => switch (c) {
      'hdmi' => 'HDMI',
      'displayport' => 'DP',
      'dvi' => 'DVI',
      'vga' => 'VGA',
      'usb_c' => 'USB‑C',
      'internal' => 'Dahili',
      'other' => 'Diğer',
      _ => null,
    };

SenseStatusCategory _displays(SensePeerStatus st) {
  final ds = List<SensePeerDisplay>.of(st.displays)..sort((a, b) => a.index.compareTo(b.index));
  return SenseStatusCategory(
    id: 'displays',
    title: _S.displays,
    summary: ds.isEmpty
        ? null
        : _join([_S.displayCount(ds.length), senseResolutionMix([for (final d in ds) if (d.width != null && d.height != null) (w: d.width!, h: d.height!)])]),
    rows: ds.isEmpty
        ? const [SenseStatusUnreadable()]
        : [
            for (final d in ds)
              SenseStatusLine(
                d.primary == true ? '${d.index + 1} · ${_S.primary}' : '${d.index + 1}',
                _join([
                  d.name,
                  d.width == null || d.height == null ? null : senseRes(d.width!, d.height!),
                  d.refreshHz == null ? null : senseHz(d.refreshHz!),
                  senseConnectionShort(d.connection),
                  d.scale == null ? null : '%${(d.scale! * 100).round()}',
                ]),
              ),
          ],
  );
}

// ------------------------------------------------------------------ Bileşenler

SenseStatusCategory _components(SenseInventory? inv, SenseStatusPlatform os) {
  final board = _join([inv?.boardManufacturer, inv?.boardProduct], ' ');
  // Sürüm 11 (#124): the firmware was read but has no serial (vendor placeholder dropped).
  final serialNotGiven = inv?.serial == null && inv?.biosVersion != null;
  return SenseStatusCategory(
    id: 'components',
    title: _S.components,
    summary: _join([inv?.boardProduct, inv?.biosVersion == null ? null : '${_S.bios} ${inv!.biosVersion}']),
    level: inv == null ? SenseLevel.unknown : null,
    rows: [
      SenseStatusLine(_S.board, board),
      SenseStatusLine(_S.bios, _join([inv?.biosVersion, inv?.biosDate == null ? null : senseDate(inv!.biosDate!)])),
      SenseStatusLine(_S.serial, inv?.serial, notReported: serialNotGiven),
      SenseStatusLine(_S.audio, inv?.audio == null ? null : _join(inv!.audio!, ', ')),
      SenseStatusLine(_S.usb, inv?.usb == null ? null : _join(inv!.usb!, ', ')),
      // Power plans are Windows', "start after power loss" is read on a Mac only (Sürüm 11).
      if (os != _P.mac || inv?.powerPlan != null) SenseStatusLine(_S.powerPlan, inv?.powerPlan),
      if (os != _P.windows || inv?.powerRestore != null)
        SenseStatusLine(_S.powerRestore, inv?.powerRestore == null ? null : _S.powerRestoreValue(inv!.powerRestore!)),
    ],
  );
}

// ------------------------------------------------------------------ Yazılım

String? _role(String? r) => switch (r) {
      'host' => _S.roleHost,
      'controller' => _S.roleController,
      'host_controller' => _S.roleBoth,
      _ => null,
    };

SenseStatusCategory _software(SensePeerStatus st, SenseHealthDetail? h, SenseInventory? inv, SenseStatusPlatform platform) {
  // A Mac's drivers are part of macOS: the group is left out (Sürüm 11).
  final showDrivers = platform != _P.mac || inv?.drivers != null;
  final os = inv?.os;
  final osName = _join([os?.name, os?.version], ' ');
  final drivers = inv?.drivers;
  String? driver(String kind) {
    if (drivers == null) return null;
    return _join([
      for (final d in drivers)
        if (d.kind == kind) _join([d.device, d.version], ' '),
    ]);
  }

  final version = st.appVersion?.toString();
  return SenseStatusCategory(
    id: 'software',
    title: _S.software,
    summary: _join([osName, version == null ? null : _S.senseSummary(version)]),
    rows: [
      const SenseStatusGroup(_S.osGroup),
      SenseStatusLine(_S.osVersion, osName),
      SenseStatusLine(_S.osBuild, os?.build),
      SenseStatusLine(_S.lastUpdate, os?.lastUpdate == null ? null : senseDate(os!.lastUpdate!)),
      SenseStatusLine(_S.hostname, os?.hostname),
      SenseStatusLine(_S.timezone, os?.timezone),
      SenseStatusLine(_S.uptime, h?.uptimeS == null ? null : senseUptime(h!.uptimeS!)),
      if (showDrivers) ...[
        const SenseStatusGroup(_S.driversGroup),
        SenseStatusLine(_S.driverDisplay, driver('display')),
        SenseStatusLine(_S.driverNetwork, driver('network')),
        SenseStatusLine(_S.driverWifi, driver('wifi')),
        SenseStatusLine(_S.driverAudio, driver('audio')),
        SenseStatusLine(_S.driverChipset, driver('chipset')),
      ],
      const SenseStatusGroup(_S.senseGroup),
      SenseStatusLine(_S.senseVersion, version == null ? null : _S.senseVersionValue(version, _role(st.role))),
      // The heartbeat comes from the Sense service: a computer the panel sees
      // online has it running. Whether it starts at boot is not reported.
      SenseStatusLine(_S.service, st.online ? _S.serviceRunning : null),
    ],
  );
}

/// "Toplam yazılan" row: lifetime GB when read, else the since-boot figure under its own honest
/// label (macOS), else unread. Nothing is estimated.
SenseStatusLine senseWrittenLine(SenseHealthPhysicalDisk? live) {
  final total = live?.writtenGb;
  if (total != null) return SenseStatusLine(_S.totalWritten, senseDiskSize(total));
  final boot = live?.writtenBootGb;
  if (boot != null) return SenseStatusLine(_S.writtenSinceBoot, senseDiskSize(boot));
  return const SenseStatusLine(_S.totalWritten, null);
}
