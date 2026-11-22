// Sense Remote: "Bilgisayar durumu" box of the connection window — processor,
// graphics card °C, memory, disks, uptime, displays, network addresses
// (ethernet first, several in order; user request 2026-11-17) and version.
// Data: panel peer-status. Nothing that was not reported is shown as a value;
// no frame rate or latency (not measured). Prototype: uygulama.html (.hpop).

import 'package:flutter/material.dart';

import 'data/sense_peer_status.dart';
import '../host_live/sense_cm_style.dart';
import 'sense_remote_display_info.dart'
    show SenseInfoRow, SenseRemotePanelNote;
import 'sense_remote_strings.dart';

class SenseMeter {
  const SenseMeter(this.label, this.fraction, this.value, {this.hot = false});
  final String label;

  /// 0..1 bar fill.
  final double fraction;
  final String value;
  final bool hot;

  @override
  String toString() => '$label: $value${hot ? ' (!)' : ''}';
}

class SenseStatusView {
  const SenseStatusView({
    required this.subtitle,
    required this.meters,
    required this.rows,
    required this.network,
  });

  final String subtitle;
  final List<SenseMeter> meters;
  final List<SenseInfoRow> rows;
  final List<SenseInfoRow> network;
}

/// Thresholds for the warm colour of a bar (information only).
const double kSenseHotTempC = 80;
const double kSenseHotPct = 90;

double _frac(double v, double max) => (v / max).clamp(0.0, 1.0).toDouble();

/// Builds the box content. Pure; [nowS] is the current Unix time (s).
SenseStatusView senseStatusView(SensePeerStatus s, int nowS) {
  String t(String k) => senseRemoteText(k);
  final meters = <SenseMeter>[];
  final rows = <SenseInfoRow>[];
  final h = s.health;

  if (h != null) {
    final cpu = h.cpuPct;
    final cpuT = h.cpuTempC;
    if (cpu != null || cpuT != null) {
      final parts = [
        if (cpu != null) senseFormatPct(cpu),
        if (cpuT != null) '${cpuT.round()}°C',
      ];
      meters.add(SenseMeter(
          t('cpu'), cpu != null ? _frac(cpu, 100) : _frac(cpuT!, 100),
          parts.join(' · '),
          hot: (cpu ?? 0) >= kSenseHotPct || (cpuT ?? 0) >= kSenseHotTempC));
    }
    final gpu = h.gpuPct;
    final gpuT = h.gpuTempC;
    if (gpu != null || gpuT != null) {
      final parts = [
        if (gpu != null) senseFormatPct(gpu),
        if (gpuT != null) '${gpuT.round()}°C',
      ];
      meters.add(SenseMeter(
          t('gpu'), gpuT != null ? _frac(gpuT, 100) : _frac(gpu!, 100),
          parts.join(' · '),
          hot: (gpu ?? 0) >= kSenseHotPct || (gpuT ?? 0) >= kSenseHotTempC));
    }
    final used = h.memUsedMb;
    if (used != null) {
      final total = h.memTotalMb;
      final f = total != null && total > 0 ? used / total : 0.0;
      meters.add(SenseMeter(
          t('memory'), f.clamp(0.0, 1.0).toDouble(),
          senseFormatMemory(used, total),
          hot: f * 100 >= kSenseHotPct));
    }
    for (final d in h.disks) {
      meters.add(SenseMeter('${t('disk')} ${d.mount}', _frac(d.usedPct, 100),
          senseFormatPct(d.usedPct),
          hot: d.usedPct >= kSenseHotPct));
    }
  }
  if (h == null || h.isEmpty) {
    rows.add(SenseInfoRow(t('health'), t('not_reported')));
  }

  final up = h?.uptimeS;
  if (up != null) rows.add(SenseInfoRow(t('uptime'), senseFormatUptime(up)));

  if (s.displays.isEmpty) {
    rows.add(SenseInfoRow(t('displays'), t('not_reported')));
  } else {
    final conns = s.displays
        .map((d) => senseConnectionShort(d.connection))
        .whereType<String>()
        .toList();
    rows.add(SenseInfoRow(
        t('displays'),
        conns.length == s.displays.length
            ? '${s.displays.length} · ${conns.join(', ')}'
            : '${s.displays.length}'));
  }

  final v = s.appVersion;
  rows.add(SenseInfoRow(t('version'),
      v != null ? '${t('version')} $v' : t('not_reported')));

  final net = senseNetworkRows(s.network);

  final state = s.online ? t('online') : t('offline');
  final seen = s.lastSeenAt;
  final subtitle = seen == null
      ? state
      : '$state · ${t('last_seen')} ${senseFormatAgo(nowS - seen)}';

  return SenseStatusView(
      subtitle: subtitle, meters: meters, rows: rows, network: net);
}

/// Network addresses, ethernet first; a kind with several adapters is
/// numbered ("Ethernet 1", "Ethernet 2"). IPv4 addresses one per line; an
/// adapter with only IPv6 shows that. Adapters without any address are left
/// out. Empty list → one "Bildirilmedi" row.
List<SenseInfoRow> senseNetworkRows(List<SensePeerNetwork> network) {
  final withIp = senseOrderNetwork(network)
      .where((n) => n.ipv4.isNotEmpty || n.ipv6.isNotEmpty)
      .toList();
  if (withIp.isEmpty) {
    return [SenseInfoRow(senseRemoteText('network'), senseRemoteText('not_reported'))];
  }
  final perKind = <String, int>{};
  for (final n in withIp) {
    perKind[n.kind] = (perKind[n.kind] ?? 0) + 1;
  }
  final seen = <String, int>{};
  return withIp.map((n) {
    final no = (seen[n.kind] ?? 0) + 1;
    seen[n.kind] = no;
    final kind = senseNetworkKindLabel(n.kind);
    final label = (perKind[n.kind] ?? 0) > 1 ? '$kind $no' : kind;
    final ips = n.ipv4.isNotEmpty ? n.ipv4 : n.ipv6;
    var value = ips.join('\n');
    if (n.up == false) value = '$value · ${senseRemoteText('not_connected')}';
    return SenseInfoRow(label, value);
  }).toList();
}

class SenseStatusPopup extends StatelessWidget {
  const SenseStatusPopup({
    super.key,
    required this.result,
    required this.loading,
    required this.nowS,
    required this.onRetry,
  });

  final SensePeerStatusResult? result;
  final bool loading;
  final int nowS;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final status = result?.status;
    final view = status == null ? null : senseStatusView(status, nowS);
    return Container(
      key: const ValueKey('sense-remote-status'),
      width: 300,
      constraints: const BoxConstraints(maxHeight: 560),
      decoration: BoxDecoration(
        color: SenseCmTokens.black,
        borderRadius: BorderRadius.circular(SenseCmTokens.radiusCard),
        border: Border.all(color: SenseCmTokens.border),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: senseRemoteText('status'),
                    style: SenseCmTokens.text(size: 13, weight: FontWeight.w600)),
                if (view != null)
                  TextSpan(
                      text: '  ${view.subtitle}',
                      style: SenseCmTokens.text(
                          size: 10, color: SenseCmTokens.muted)),
              ]),
            ),
            const SizedBox(height: 10),
            if (view == null && result == null && loading)
              Text(senseRemoteText('loading'),
                  style:
                      SenseCmTokens.text(size: 11, color: SenseCmTokens.muted)),
            if (view == null && result != null)
              SenseRemotePanelNote(result: result!, onRetry: onRetry),
            if (view != null) ...[
              for (final m in view.meters) _meter(m),
              if (view.meters.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Divider(height: 1, color: SenseCmTokens.line),
                ),
              for (final r in view.rows) _row(r),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(height: 1, color: SenseCmTokens.line),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(senseRemoteText('network'),
                    style: SenseCmTokens.text(
                        size: 10,
                        weight: FontWeight.w600,
                        color: SenseCmTokens.muted)),
              ),
              for (final r in view.network)
                _row(r, key: ValueKey('sense-remote-net-${r.label}')),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _meter(SenseMeter m) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(m.label,
                overflow: TextOverflow.ellipsis,
                style: SenseCmTokens.text(size: 11, color: SenseCmTokens.soft)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 5,
                child: Stack(
                  children: [
                    Container(color: SenseRemoteTokens.barTrack),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: m.fraction,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: m.hot
                              ? SenseRemoteTokens.hot
                              : SenseRemoteTokens.bar,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: 92,
            child: Text(m.value,
                textAlign: TextAlign.right,
                style: SenseCmTokens.text(size: 11, weight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  static Widget _row(SenseInfoRow r, {Key? key}) {
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(r.label,
                style: SenseCmTokens.text(size: 11, color: SenseCmTokens.muted)),
          ),
          Expanded(
            child: SelectableText(r.value,
                textAlign: TextAlign.right,
                style: SenseCmTokens.text(size: 11, weight: FontWeight.w400)),
          ),
        ],
      ),
    );
  }
}
