// Sense Remote: display info card of the connection window — for each display
// connection type, resolution, refresh rate, colour, HDR (user request,
// 2026-11-17). Geometry comes from RustDesk (PeerInfo.displays); the rest from
// the panel (peer-status). A field the computer did not report is not shown.
// Prototype: Calisma/prototip/uygulama.html, screen 4 (.info).

import 'package:flutter/material.dart';

import '../../common/sense_peer_status.dart';
import '../../consts.dart' show kAllDisplayValue;
import '../pages/sense_cm_style.dart';
import '../pages/sense_cm_widgets.dart' show SenseCmTextButton;
import 'sense_remote_map.dart';
import 'sense_remote_strings.dart';

class SenseInfoRow {
  const SenseInfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  String toString() => '$label: $value';
}

String _size(int w, int h) => '$w × $h';

/// Rows of one display card. Pure; covered by tests.
List<SenseInfoRow> senseDisplayInfoRows(
    SenseMapDisplay map, SensePeerDisplay? panel) {
  String t(String k) => senseRemoteText(k);
  final rows = <SenseInfoRow>[];
  final conn = senseConnectionLabel(panel?.connection);
  if (conn != null) rows.add(SenseInfoRow(t('f_connection'), conn));
  final w = panel?.width ?? map.width;
  final h = panel?.height ?? map.height;
  if (w > 0 && h > 0) rows.add(SenseInfoRow(t('f_resolution'), _size(w, h)));
  final nw = panel?.nativeWidth;
  final nh = panel?.nativeHeight;
  if (nw != null && nh != null) {
    rows.add(SenseInfoRow(t('f_native'), _size(nw, nh)));
  }
  final hz = panel?.refreshHz;
  if (hz != null) rows.add(SenseInfoRow(t('f_refresh'), senseFormatHz(hz)));
  final color = [
    if (panel?.bitDepth != null) '${panel!.bitDepth} bit',
    if (senseColorFormatLabel(panel?.colorFormat) != null)
      senseColorFormatLabel(panel?.colorFormat)!,
  ];
  if (color.isNotEmpty) rows.add(SenseInfoRow(t('f_color'), color.join(' · ')));
  final hdr = panel?.hdr;
  if (hdr != null) {
    rows.add(SenseInfoRow(t('f_hdr'), hdr ? t('hdr_on') : t('hdr_off')));
  }
  final scale = panel?.scale;
  if (scale != null) {
    rows.add(SenseInfoRow(t('f_scale'), '%${(scale * 100).round()}'));
  }
  rows.add(SenseInfoRow(
      t('f_position'), 'x ${map.x.round()}, y ${map.y.round()}'));
  return rows;
}

/// A short note when the colour format softens detail (LED walls, text).
String? senseDisplayWarning(SensePeerDisplay? panel) {
  final f = panel?.colorFormat;
  if (f == 'ycbcr422' || f == 'ycbcr420') {
    return '${senseColorFormatLabel(f)} — ${senseRemoteText('warn_ycbcr')}';
  }
  return null;
}

/// The card(s) shown under the toolbar: one display, or every display when
/// "Tümü" is on.
class SenseDisplayInfoPanel extends StatelessWidget {
  const SenseDisplayInfoPanel({
    super.key,
    required this.displays,
    required this.current,
    required this.result,
    required this.loading,
    required this.onRetry,
  });

  final List<SenseMapDisplay> displays;
  final int current;
  final SensePeerStatusResult? result;
  final bool loading;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final shown = current == kAllDisplayValue
        ? displays
        : displays.where((d) => d.index == current).toList();
    final status = result?.status;
    return Container(
      key: const ValueKey('sense-remote-info'),
      width: 260,
      constraints: const BoxConstraints(maxHeight: 520),
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
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1, color: SenseCmTokens.line),
                ),
              _card(shown[i], status?.display(shown[i].index),
                  status != null),
            ],
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _card(SenseMapDisplay d, SensePeerDisplay? panel, bool panelOk) {
    final rows = senseDisplayInfoRows(d, panel);
    final warn = senseDisplayWarning(panel);
    final name = panel?.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(senseDisplayTitle(d),
            style: SenseCmTokens.text(size: 13, weight: FontWeight.w600)),
        if (name != null && name.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(name,
                style: SenseCmTokens.text(size: 11, color: SenseCmTokens.muted)),
          ),
        const SizedBox(height: 8),
        for (final r in rows) _row(r.label, r.value),
        if (panelOk && panel == null)
          _row(senseRemoteText('f_connection'),
              senseRemoteText('not_reported'),
              muted: true),
        if (warn != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: SenseRemoteTokens.warnFill,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: SenseRemoteTokens.warnBorder),
            ),
            child: Text('⚠ $warn',
                style:
                    SenseCmTokens.text(size: 10, color: SenseRemoteTokens.warn)),
          ),
      ],
    );
  }

  Widget _footer() {
    final r = result;
    if (r == null || r.status != null) {
      if (r == null && loading) {
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(senseRemoteText('loading'),
              style: SenseCmTokens.text(size: 10, color: SenseCmTokens.muted)),
        );
      }
      return const SizedBox.shrink();
    }
    return SenseRemotePanelNote(result: r, onRetry: onRetry);
  }

  static Widget _row(String label, String value, {bool muted = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(label,
                style: SenseCmTokens.text(size: 11, color: SenseCmTokens.muted)),
          ),
          Expanded(
            child: Text(value,
                style: SenseCmTokens.text(
                    size: 11,
                    weight: muted ? FontWeight.w300 : FontWeight.w400,
                    color: muted ? SenseCmTokens.muted : SenseCmTokens.white)),
          ),
        ],
      ),
    );
  }
}

/// "Panel bilgisi yok" / "Panel bilgisine ulaşılamadı · Yeniden dene".
class SenseRemotePanelNote extends StatelessWidget {
  const SenseRemotePanelNote(
      {super.key, required this.result, required this.onRetry});
  final SensePeerStatusResult result;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = !result.noPanelInfo;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
                senseRemoteText(failed ? 'panel_failed' : 'no_panel_info'),
                style: SenseCmTokens.text(size: 11, color: SenseCmTokens.muted)),
          ),
          if (failed)
            SenseCmTextButton(
                key: const ValueKey('sense-remote-retry'),
                label: senseRemoteText('retry'),
                strong: true,
                onTap: onRetry),
        ],
      ),
    );
  }
}
