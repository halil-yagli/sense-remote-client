// Sense Remote: the computer's health and inventory as the panel sends them in
// peer-status (YH S6, O8). Contract `health_v2`:
// Calisma/plan/2026-11-23_saglik-sozlesmesi.md §2 (inventory) and §3 (health),
// panel packages/shared `SenseInventory` / `SenseHealth`.
//
// Parsing is tolerant: a field that is missing or has an unexpected shape stays
// null here and the interface writes "okunamadı". Nothing is ever guessed;
// values outside the contract range are dropped, not clamped.

int? _int(Object? v) {
  if (v is int) return v;
  if (v is double && v.isFinite && v == v.roundToDouble()) return v.toInt();
  return null;
}

double? _num(Object? v) {
  if (v is num && v.isFinite) return v.toDouble();
  return null;
}

bool? _bool(Object? v) => v is bool ? v : null;

String? _str(Object? v) {
  if (v is! String) return null;
  final t = v.trim();
  return t.isEmpty ? null : t;
}

/// "YYYY-MM-DD" only.
DateTime? _date(Object? v) {
  final s = _str(v);
  if (s == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return null;
  return DateTime.tryParse(s);
}

double? _range(double? v, double min, double max) =>
    v == null || v < min || v > max ? null : v;

/// Percentages are 0..100 in the contract.
double? _pct(Object? v) => _range(_num(v), 0, 100);

/// Temperatures -20..150 °C; 0 means "no sensor" on some machines (contract §4).
double? _temp(Object? v) {
  final t = _range(_num(v), -20, 150);
  return t == 0 ? null : t;
}

List<T> _list<T>(Object? v, T? Function(Object?) parse) {
  if (v is! List) return const [];
  final out = <T>[];
  for (final e in v) {
    final p = parse(e);
    if (p != null) out.add(p);
  }
  return out;
}

Map<String, Object?>? _map(Object? v) =>
    v is Map ? v.map((k, val) => MapEntry('$k', val)) : null;

// ---------------------------------------------------------------- inventory

class SenseInvCpu {
  const SenseInvCpu({this.model, this.cores, this.threads, this.baseMhz});
  final String? model;
  final int? cores;
  final int? threads;
  final int? baseMhz;

  static SenseInvCpu? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    final base = _int(m['base_mhz']);
    return SenseInvCpu(
      model: _str(m['model']),
      cores: _positive(_int(m['cores'])),
      threads: _positive(_int(m['threads'])),
      baseMhz: base != null && base >= 100 && base <= 10000 ? base : null,
    );
  }
}

int? _positive(int? v) => v != null && v > 0 ? v : null;

class SenseInvGpu {
  const SenseInvGpu({required this.name, this.integrated, this.vramMb, this.driverVersion, this.driverDate});
  final String name;
  final bool? integrated;
  final int? vramMb;
  final String? driverVersion;
  final DateTime? driverDate;

  static SenseInvGpu? fromJson(Object? json) {
    final m = _map(json);
    final name = _str(m?['name']);
    if (m == null || name == null) return null;
    return SenseInvGpu(
      name: name,
      integrated: _bool(m['integrated']),
      vramMb: _positive(_int(m['vram_mb'])),
      driverVersion: _str(m['driver_version']),
      driverDate: _date(m['driver_date']),
    );
  }
}

class SenseInvMemoryModule {
  const SenseInvMemoryModule({this.slot, this.sizeMb, this.kind, this.speedMts, this.model, this.manufacturer});
  final String? slot;
  final int? sizeMb;
  final String? kind;
  final int? speedMts;
  final String? model;
  final String? manufacturer;

  static SenseInvMemoryModule? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    final speed = _int(m['speed_mts']);
    return SenseInvMemoryModule(
      slot: _str(m['slot']),
      sizeMb: _positive(_int(m['size_mb'])),
      kind: _str(m['kind']),
      speedMts: speed != null && speed >= 100 && speed <= 20000 ? speed : null,
      model: _str(m['model']),
      manufacturer: _str(m['manufacturer']),
    );
  }
}

class SenseInvMemory {
  const SenseInvMemory({this.totalMb, this.slotsTotal, this.modules});
  final int? totalMb;
  final int? slotsTotal;

  /// Null: the list could not be read (different from an empty list).
  final List<SenseInvMemoryModule>? modules;

  static SenseInvMemory? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    final slots = _int(m['slots_total']);
    return SenseInvMemory(
      totalMb: _positive(_int(m['total_mb'])),
      slotsTotal: slots != null && slots >= 1 && slots <= 256 ? slots : null,
      modules: m['modules'] is List ? _list(m['modules'], SenseInvMemoryModule.fromJson) : null,
    );
  }
}

class SenseInvDisk {
  const SenseInvDisk({
    required this.id,
    required this.model,
    this.bus,
    this.media,
    this.sizeGb,
    this.firmware,
    this.health,
    this.lifeLeftPct,
    this.mounts = const [],
  });

  final String id;
  final String model;

  /// nvme, sata, usb, sas, raid, other
  final String? bus;

  /// ssd, hdd
  final String? media;
  final double? sizeGb;
  final String? firmware;

  /// ok, warning, failing
  final String? health;
  final double? lifeLeftPct;
  final List<String> mounts;

  static SenseInvDisk? fromJson(Object? json) {
    final m = _map(json);
    final id = _str(m?['id']);
    final model = _str(m?['model']);
    if (m == null || id == null || model == null) return null;
    final size = _num(m['size_gb']);
    return SenseInvDisk(
      id: id,
      model: model,
      bus: _str(m['bus']),
      media: _str(m['media']),
      sizeGb: size != null && size > 0 ? size : null,
      firmware: _str(m['firmware']),
      health: _str(m['health']),
      lifeLeftPct: _pct(m['life_left_pct']),
      mounts: _list(m['mounts'], _str),
    );
  }
}

class SenseInvNetwork {
  const SenseInvNetwork({
    required this.name,
    this.device,
    this.kind,
    this.description,
    this.mac,
    this.connected,
    this.dhcp,
    this.gateway = const [],
    this.dns = const [],
    this.speedMbps,
    this.driverVersion,
  });

  final String name;

  /// macOS BSD name ("en0").
  final String? device;

  /// ethernet, wifi, other
  final String? kind;
  final String? description;
  final String? mac;
  final bool? connected;

  /// true DHCP, false STATİK, null unknown.
  final bool? dhcp;
  final List<String> gateway;
  final List<String> dns;
  final int? speedMbps;
  final String? driverVersion;

  static SenseInvNetwork? fromJson(Object? json) {
    final m = _map(json);
    final name = _str(m?['name']);
    if (m == null || name == null) return null;
    final speed = _int(m['speed_mbps']);
    final mac = _str(m['mac']);
    return SenseInvNetwork(
      name: name,
      device: _str(m['device']),
      kind: _str(m['kind']),
      description: _str(m['description']),
      mac: mac != null && RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(mac) ? mac : null,
      connected: _bool(m['connected']),
      dhcp: _bool(m['dhcp']),
      gateway: _list(m['gateway'], _str),
      dns: _list(m['dns'], _str),
      speedMbps: speed != null && speed >= 1 && speed <= 400000 ? speed : null,
      driverVersion: _str(m['driver_version']),
    );
  }
}

class SenseInvOs {
  const SenseInvOs({this.name, this.version, this.build, this.lastUpdate, this.hostname, this.timezone});
  final String? name;
  final String? version;
  final String? build;
  final DateTime? lastUpdate;
  final String? hostname;
  final String? timezone;

  static SenseInvOs? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    return SenseInvOs(
      name: _str(m['name']),
      version: _str(m['version']),
      build: _str(m['build']),
      lastUpdate: _date(m['last_update']),
      hostname: _str(m['hostname']),
      timezone: _str(m['timezone']),
    );
  }
}

class SenseInvDriver {
  const SenseInvDriver({required this.kind, required this.device, this.version, this.date, this.provider});

  /// display, network, wifi, audio, chipset
  final String kind;
  final String device;
  final String? version;
  final DateTime? date;
  final String? provider;

  static SenseInvDriver? fromJson(Object? json) {
    final m = _map(json);
    final kind = _str(m?['class']);
    final device = _str(m?['device']);
    if (m == null || kind == null || device == null) return null;
    return SenseInvDriver(
      kind: kind,
      device: device,
      version: _str(m['version']),
      date: _date(m['date']),
      provider: _str(m['provider']),
    );
  }
}

/// Fixed inventory (contract §2). Lists that were not sent are null ("could not
/// be read"), an empty list means "the computer has none".
class SenseInventory {
  const SenseInventory({
    this.at,
    this.cpu,
    this.gpus,
    this.memory,
    this.physicalDisks,
    this.network,
    this.boardManufacturer,
    this.boardProduct,
    this.biosVendor,
    this.biosVersion,
    this.biosDate,
    this.serial,
    this.audio,
    this.usb,
    this.powerPlan,
    this.powerRestore,
    this.os,
    this.drivers,
  });

  final int? at;
  final SenseInvCpu? cpu;
  final List<SenseInvGpu>? gpus;
  final SenseInvMemory? memory;
  final List<SenseInvDisk>? physicalDisks;
  final List<SenseInvNetwork>? network;
  final String? boardManufacturer;
  final String? boardProduct;
  final String? biosVendor;
  final String? biosVersion;
  final DateTime? biosDate;
  final String? serial;
  final List<String>? audio;
  final List<String>? usb;
  final String? powerPlan;
  final bool? powerRestore;
  final SenseInvOs? os;
  final List<SenseInvDriver>? drivers;

  static List<T>? _opt<T>(Object? v, T? Function(Object?) parse) => v is List ? _list(v, parse) : null;

  static SenseInventory? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    final board = _map(m['board']);
    final bios = _map(m['bios']);
    return SenseInventory(
      at: _int(m['at']),
      cpu: SenseInvCpu.fromJson(m['cpu']),
      gpus: _opt(m['gpus'], SenseInvGpu.fromJson),
      memory: SenseInvMemory.fromJson(m['memory']),
      physicalDisks: _opt(m['physical_disks'], SenseInvDisk.fromJson),
      network: _opt(m['network'], SenseInvNetwork.fromJson),
      boardManufacturer: _str(board?['manufacturer']),
      boardProduct: _str(board?['product']),
      biosVendor: _str(bios?['vendor']),
      biosVersion: _str(bios?['version']),
      biosDate: _date(bios?['date']),
      serial: _str(m['serial']),
      audio: _opt(m['audio'], _str),
      usb: _opt(m['usb'], _str),
      powerPlan: _str(m['power_plan']),
      powerRestore: _bool(m['power_restore']),
      os: SenseInvOs.fromJson(m['os']),
      drivers: _opt(m['drivers'], SenseInvDriver.fromJson),
    );
  }
}

// ---------------------------------------------------------------- health

class SenseHealthDisk {
  const SenseHealthDisk({required this.mount, required this.usedPct, this.totalGb});
  final String mount;
  final double usedPct;
  final double? totalGb;

  static SenseHealthDisk? fromJson(Object? json) {
    final m = _map(json);
    final mount = _str(m?['mount']);
    final used = _pct(m?['used_pct']);
    if (m == null || mount == null || used == null) return null;
    final total = _num(m['total_gb']);
    return SenseHealthDisk(mount: mount, usedPct: used, totalGb: total != null && total > 0 ? total : null);
  }
}

class SenseHealthProcess {
  const SenseHealthProcess({required this.name, required this.cpuPct});
  final String name;
  final double cpuPct;

  static SenseHealthProcess? fromJson(Object? json) {
    final m = _map(json);
    final name = _str(m?['name']);
    final pct = _pct(m?['cpu_pct']);
    if (name == null || pct == null) return null;
    return SenseHealthProcess(name: name, cpuPct: pct);
  }
}

class SenseHealthGpu {
  const SenseHealthGpu({this.name, this.utilPct, this.vramUsedMb, this.vramTotalMb, this.tempC, this.fanPct, this.powerW});
  final String? name;
  final double? utilPct;
  final int? vramUsedMb;
  final int? vramTotalMb;
  final double? tempC;
  final double? fanPct;
  final double? powerW;

  static SenseHealthGpu? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    final used = _int(m['vram_used_mb']);
    final power = _range(_num(m['power_w']), 0, 2000);
    return SenseHealthGpu(
      name: _str(m['name']),
      utilPct: _pct(m['util_pct']),
      vramUsedMb: used != null && used >= 0 ? used : null,
      vramTotalMb: _positive(_int(m['vram_total_mb'])),
      tempC: _temp(m['temp_c']),
      fanPct: _pct(m['fan_pct']),
      powerW: power == 0 ? null : power,
    );
  }
}

class SenseHealthPhysicalDisk {
  const SenseHealthPhysicalDisk({required this.id, this.readBps, this.writeBps, this.tempC});
  final String id;
  final int? readBps;
  final int? writeBps;
  final double? tempC;

  static SenseHealthPhysicalDisk? fromJson(Object? json) {
    final m = _map(json);
    final id = _str(m?['id']);
    if (m == null || id == null) return null;
    return SenseHealthPhysicalDisk(
      id: id,
      readBps: _bps(m['read_bps']),
      writeBps: _bps(m['write_bps']),
      tempC: _temp(m['temp_c']),
    );
  }
}

int? _bps(Object? v) {
  final b = _int(v);
  return b != null && b >= 0 && b <= 100000000000 ? b : null;
}

class SenseHealthNetIo {
  const SenseHealthNetIo({required this.name, required this.rxBps, required this.txBps});
  final String name;
  final int rxBps;
  final int txBps;

  static SenseHealthNetIo? fromJson(Object? json) {
    final m = _map(json);
    final name = _str(m?['name']);
    final rx = _bps(m?['rx_bps']);
    final tx = _bps(m?['tx_bps']);
    if (name == null || rx == null || tx == null) return null;
    return SenseHealthNetIo(name: name, rxBps: rx, txBps: tx);
  }
}

class SenseHealthWifi {
  const SenseHealthWifi({this.name, this.ssid, this.band, this.signalPct});
  final String? name;
  final String? ssid;

  /// "2.4 GHz", "5 GHz", "6 GHz"
  final String? band;
  final double? signalPct;

  static SenseHealthWifi? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    return SenseHealthWifi(
      name: _str(m['name']),
      ssid: _str(m['ssid']),
      band: _str(m['band']),
      signalPct: _pct(m['signal_pct']),
    );
  }
}

/// Changing values (contract §3), v1 and v2 fields together.
class SenseHealthDetail {
  const SenseHealthDetail({
    this.at,
    this.cpuPct,
    this.gpuPct,
    this.cpuTempC,
    this.gpuTempC,
    this.memUsedMb,
    this.memTotalMb,
    this.disks = const [],
    this.uptimeS,
    this.cpuMhz,
    this.topProcesses,
    this.memAvailableMb,
    this.swapUsedMb,
    this.swapTotalMb,
    this.gpus,
    this.physicalDisks,
    this.netIo,
    this.wifi,
  });

  final int? at;
  final double? cpuPct;
  final double? gpuPct;
  final double? cpuTempC;
  final double? gpuTempC;
  final int? memUsedMb;
  final int? memTotalMb;
  final List<SenseHealthDisk> disks;
  final int? uptimeS;
  final int? cpuMhz;

  /// Null: not read (v1 computer); empty: read, nothing busy.
  final List<SenseHealthProcess>? topProcesses;
  final int? memAvailableMb;
  final int? swapUsedMb;
  final int? swapTotalMb;
  final List<SenseHealthGpu>? gpus;
  final List<SenseHealthPhysicalDisk>? physicalDisks;
  final List<SenseHealthNetIo>? netIo;
  final SenseHealthWifi? wifi;

  static List<T>? _opt<T>(Object? v, T? Function(Object?) parse) => v is List ? _list(v, parse) : null;

  static SenseHealthDetail? fromJson(Object? json) {
    final m = _map(json);
    if (m == null) return null;
    final mhz = _int(m['cpu_mhz']);
    int? nonNeg(Object? v) {
      final i = _int(v);
      return i != null && i >= 0 ? i : null;
    }

    return SenseHealthDetail(
      at: _int(m['at']),
      cpuPct: _pct(m['cpu_pct']),
      gpuPct: _pct(m['gpu_pct']),
      cpuTempC: _temp(m['cpu_temp_c']),
      gpuTempC: _temp(m['gpu_temp_c']),
      memUsedMb: nonNeg(m['mem_used_mb']),
      memTotalMb: _positive(_int(m['mem_total_mb'])),
      disks: _list(m['disks'], SenseHealthDisk.fromJson),
      uptimeS: nonNeg(m['uptime_s']),
      cpuMhz: mhz != null && mhz >= 100 && mhz <= 10000 ? mhz : null,
      topProcesses: _opt(m['top_processes'], SenseHealthProcess.fromJson),
      memAvailableMb: nonNeg(m['mem_available_mb']),
      swapUsedMb: nonNeg(m['swap_used_mb']),
      swapTotalMb: _positive(_int(m['swap_total_mb'])),
      gpus: _opt(m['gpus'], SenseHealthGpu.fromJson),
      physicalDisks: _opt(m['physical_disks'], SenseHealthPhysicalDisk.fromJson),
      netIo: _opt(m['net_io'], SenseHealthNetIo.fromJson),
      wifi: SenseHealthWifi.fromJson(m['wifi']),
    );
  }
}
