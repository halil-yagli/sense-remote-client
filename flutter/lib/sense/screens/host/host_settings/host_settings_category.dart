// Sense Remote: "Ses ve ağ" category (FU-A4; prototype `cgH('hset', ...)`): the panel's
// signed Host settings, all locked. Values are read, never made up ("okunamadı").
import 'package:flutter/widgets.dart';

import '../../../strings/host.dart';
import '../../controller/settings/widgets.dart' show SenseLockedValueRow;
import '../data/host_settings.dart';
import '../this_computer/widgets.dart';

export '../data/host_settings.dart';

class SenseHostNetCategoryBody extends StatelessWidget {
  const SenseHostNetCategoryBody({super.key, required this.net});

  final SenseHostNet net;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SenseHostMeta(SenseHostStrings.netHint),
          SenseLockedValueRow(
              key: const Key('sense-net-audio-input'),
              label: SenseHostStrings.netAudioIn,
              value: net.audioText),
          SenseLockedValueRow(
              key: const Key('sense-net-keep-awake'),
              label: SenseHostStrings.netAwake,
              value: net.awakeText),
          SenseLockedValueRow(
              key: const Key('sense-net-relay-delay'),
              label: SenseHostStrings.netRelay,
              value: net.relayText),
          SenseLockedValueRow(
              key: const Key('sense-net-udp'), label: SenseHostStrings.netUdp, value: net.udpText),
          SenseLockedValueRow(
              key: const Key('sense-net-tcp-only'),
              label: SenseHostStrings.netTcpOnly,
              value: net.tcpOnlyText,
              last: true),
        ],
      );
}
