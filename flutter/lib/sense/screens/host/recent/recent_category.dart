// Sense Remote: "Son bağlantılar" category (YH H2): kişi · tarih · süre · ekran sayısı.
import 'package:flutter/widgets.dart';

import '../../../sense.dart';
import '../../../strings/host.dart';
import '../data/recent.dart';
import '../host_format.dart';
import '../this_computer/widgets.dart';

export '../data/recent.dart';

/// "dün · Mevlüt · 14 dk" (the newest), or "henüz yok".
String senseRecentSummary(List<SenseRecentConnection> list, DateTime now) {
  if (list.isEmpty) return SenseHostStrings.recentNone;
  final r = list.first;
  return [
    senseHostDay(r.at, now),
    r.who,
    if (r.seconds != null) SenseHostStrings.duration(r.seconds!),
  ].join(' · ');
}

/// "dün 17:10 · 14 dk · 2 ekran".
String senseRecentLine(SenseRecentConnection r, DateTime now) => [
      senseHostDayTime(r.at, now),
      if (r.seconds != null) SenseHostStrings.duration(r.seconds!),
      if (r.screens != null) SenseHostStrings.screens(r.screens!),
    ].join(' · ');

class SenseRecentCategoryBody extends StatelessWidget {
  const SenseRecentCategoryBody({super.key, required this.list, required this.now});

  final List<SenseRecentConnection> list;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) return const SenseHostMeta(SenseHostStrings.recentEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < list.length; i++)
          SenseSettingRow(
            key: Key('sense-recent-$i'),
            label: list[i].who,
            description: senseRecentLine(list[i], now),
            last: i == list.length - 1,
          ),
      ],
    );
  }
}
