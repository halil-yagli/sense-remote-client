// Sense Remote (C2): peer-status answers for the session popup tests. The
// values follow the locked design's example computer (img c06, s01–s06, c07);
// every address and serial is made up (public repo).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/screens/session/data/peer_status.dart';
import 'package:flutter_hbb/sense/screens/session/popups/display/display_data.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

/// Panel time of the example; "Canlı · 8 sn önce" at [kNow].
const int kLastSeen = 1795000000;
final DateTime kNow = DateTime.fromMillisecondsSinceEpoch((kLastSeen + 8) * 1000);

Map<String, Object?> fullJson() => {
      'online': true,
      'last_seen_at': kLastSeen,
      'app_version': 3,
      'role': 'host',
      'envelope': {'state': 'applied'},
      'busy': null,
      'displays': [
        {'index': 0, 'name': 'Samsung QM55B', 'x': 0, 'y': 0, 'width': 3840, 'height': 2160, 'scale': 1.5,
          'primary': true, 'refresh_hz': 60, 'connection': 'hdmi', 'bit_depth': 10, 'color_format': 'rgb',
          'hdr': false, 'native_width': 3840, 'native_height': 2160},
        {'index': 1, 'name': 'LED işlemci girişi', 'x': 3840, 'y': 0, 'width': 3840, 'height': 2160, 'scale': 1.5,
          'refresh_hz': 50, 'connection': 'hdmi', 'bit_depth': 8, 'color_format': 'ycbcr422', 'hdr': false},
        {'index': 2, 'name': 'Dell P2422H', 'x': 7680, 'y': 0, 'width': 1920, 'height': 1080, 'scale': 1.0,
          'refresh_hz': 60, 'connection': 'displayport', 'bit_depth': 8, 'color_format': 'rgb', 'hdr': false,
          'native_width': 1920, 'native_height': 1080},
      ],
      'network': [
        {'name': 'Wi-Fi', 'kind': 'wifi', 'ipv4': ['172.16.4.118'], 'up': true},
        {'name': 'Ethernet', 'kind': 'ethernet', 'ipv4': ['192.168.10.42', '10.0.0.5'],
          'ipv6': ['fe80::1c2a:9bff:fe31:7d10'], 'up': true},
      ],
      'health': {
        'at': kLastSeen,
        'cpu_pct': 23,
        'gpu_pct': 71,
        'cpu_temp_c': 58,
        'gpu_temp_c': 84,
        'mem_used_mb': 14438,
        'mem_total_mb': 32768,
        'disks': [
          {'mount': 'C:', 'used_pct': 62, 'total_gb': 931},
          {'mount': 'D:', 'used_pct': 96, 'total_gb': 1820},
        ],
        'uptime_s': 274000,
        'cpu_mhz': 4050,
        'top_processes': [
          {'name': 'TouchDesigner.exe', 'cpu_pct': 14},
          {'name': 'chrome.exe', 'cpu_pct': 3},
          {'name': 'SenseRemote.exe', 'cpu_pct': 1},
        ],
        'mem_available_mb': 18330,
        'swap_used_mb': 2150,
        'swap_total_mb': 8192,
        'gpus': [
          {'name': 'NVIDIA GeForce RTX 4070', 'util_pct': 71, 'vram_used_mb': 5939, 'vram_total_mb': 12282,
            'temp_c': 84, 'fan_pct': 62, 'power_w': 148},
          {'name': 'Intel UHD Graphics 770', 'util_pct': 0},
        ],
        'physical_disks': [
          {'id': '0', 'read_bps': 24000000, 'write_bps': 3000000, 'temp_c': 41},
          {'id': '1', 'read_bps': 82000000, 'write_bps': 0},
        ],
        'net_io': [
          {'name': 'Ethernet', 'rx_bps': 1500000, 'tx_bps': 375000},
        ],
        'wifi': {'name': 'Wi-Fi', 'ssid': 'Ornek-Personel', 'band': '5 GHz', 'signal_pct': 78},
      },
      'inventory': {
        'at': kLastSeen - 3600,
        'cpu': {'model': '12th Gen Intel(R) Core(TM) i7-12700', 'cores': 12, 'threads': 20, 'base_mhz': 2100},
        'gpus': [
          {'name': 'NVIDIA GeForce RTX 4070', 'integrated': false, 'vram_mb': 12282,
            'driver_version': '31.0.15.6636', 'driver_date': '2025-12-05'},
          {'name': 'Intel UHD Graphics 770', 'integrated': true, 'driver_version': '31.0.101.5590'},
        ],
        'memory': {
          'total_mb': 32768,
          'slots_total': 4,
          'modules': [
            {'slot': 'Yuva A2', 'size_mb': 16384, 'kind': 'DDR4', 'speed_mts': 3200, 'manufacturer': 'Kingston',
              'model': 'KF432C16BB/16'},
            {'slot': 'Yuva B2', 'size_mb': 16384, 'kind': 'DDR4', 'speed_mts': 3200, 'manufacturer': 'Kingston',
              'model': 'KF432C16BB/16'},
          ],
        },
        'physical_disks': [
          {'id': '0', 'model': 'Samsung SSD 980 PRO 1TB', 'bus': 'nvme', 'media': 'ssd', 'size_gb': 931.5,
            'firmware': '5B2QGXA7', 'health': 'ok', 'life_left_pct': 96, 'mounts': ['C:']},
          {'id': '1', 'model': 'WDC WD20EZBX 2TB', 'bus': 'sata', 'media': 'hdd', 'size_gb': 1863,
            'health': 'ok', 'mounts': ['D:']},
        ],
        'network': [
          {'name': 'Ethernet', 'kind': 'ethernet', 'description': 'Intel Ethernet I219-V', 'mac': '02:00:00:00:00:01',
            'connected': true, 'dhcp': false, 'gateway': ['192.168.10.1'], 'dns': ['192.168.10.1', '1.1.1.1'],
            'speed_mbps': 1000, 'driver_version': '12.19.2.45'},
          {'name': 'Wi-Fi', 'kind': 'wifi', 'description': 'Intel Wi-Fi 6 AX201', 'mac': '02:00:00:00:00:02',
            'connected': true, 'dhcp': true, 'gateway': ['172.16.4.1'], 'speed_mbps': 866,
            'driver_version': '23.60.0.10'},
          {'name': 'Ethernet 2', 'kind': 'ethernet', 'description': 'Realtek USB GbE', 'mac': '02:00:00:00:00:03',
            'connected': false},
        ],
        'board': {'manufacturer': 'ASUS', 'product': 'PRIME B660M-A D4'},
        'bios': {'vendor': 'American Megatrends', 'version': '2611', 'date': '2025-10-24'},
        'serial': 'MB-ORNEK-0001',
        'audio': ['Realtek High Definition Audio'],
        'usb': ['Logitech K400', 'Elo Touch 2201L', 'Stream Deck MK.2'],
        'power_plan': 'Yüksek performans',
        'os': {'name': 'Windows 11 Pro', 'version': '24H2', 'build': '26100.2605', 'last_update': '2026-11-12',
          'hostname': 'ORNEK-PC2', 'timezone': 'İstanbul (UTC+3)'},
        'drivers': [
          {'class': 'display', 'device': 'NVIDIA', 'version': '566.36'},
          {'class': 'network', 'device': 'Intel I219-V', 'version': '12.19.2.45'},
          {'class': 'wifi', 'device': 'Intel AX201', 'version': '23.60.0.10'},
          {'class': 'audio', 'device': 'Realtek', 'version': '6.0.9600.1'},
          {'class': 'chipset', 'device': 'Intel', 'version': '10.1.19444.8378'},
        ],
      },
    };

/// An older computer: v1 health only, no inventory.
Map<String, Object?> v1Json() => {
      'online': true,
      'last_seen_at': kLastSeen,
      'app_version': 3,
      'role': 'host',
      'envelope': {'state': 'none'},
      'displays': [],
      'network': [],
      'health': {
        'at': kLastSeen,
        'cpu_pct': 12,
        'mem_used_mb': 4096,
        'mem_total_mb': 16384,
        'disks': [
          {'mount': 'C:', 'used_pct': 40, 'total_gb': 476},
        ],
      },
      'inventory': null,
    };

SensePeerStatusFull parseFull(Map<String, Object?> json) => SensePeerStatusFull.parse(jsonEncode(json))!;

SensePeerStatusFeed feedWith(Map<String, Object?> json) {
  final feed = SensePeerStatusFeed(
    peerId: '123456789',
    fetch: (_) async => SensePeerStatusFullResult.ok(parseFull(json)),
    now: () => kNow,
    refreshEvery: null,
  );
  feed.debugSet(SensePeerStatusFullResult.ok(parseFull(json)), at: kNow);
  return feed;
}

/// Session numbers of img c07 / s07.
const SenseSessionVideo kVideo = SenseSessionVideo(
  fps: 60,
  rttMs: 18,
  direct: true,
  codec: 'VP9',
  quality: 'balanced',
  bandwidthMbit: 6.4,
  lossEstPct: 0.2,
  displays: [
    SenseSessionDisplay(index: 0, x: 0, y: 0, width: 3840, height: 2160),
    SenseSessionDisplay(index: 1, x: 3840, y: 0, width: 3840, height: 2160),
    SenseSessionDisplay(index: 2, x: 7680, y: 0, width: 1920, height: 1080),
  ],
  watched: 0,
);

/// Black app frame.
Widget app(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: ColoredBox(
            color: SenseColors.bg,
            child: DefaultTextStyle(
              style: const TextStyle(fontFamily: SenseFont.family, color: SenseColors.text),
              child: child,
            ),
          ),
        ),
      ),
    );
