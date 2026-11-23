// Sense Remote: "Hakkında" of the Host (YH H1, TK9 Risk H1). Shown inside the
// Host window, never through the settings tab page, so the Host has no way to
// the settings. Same content as the About page; the permanent password is not
// here (it is a category of "Bu bilgisayar"). The AGPL "Açık kaynak lisansları"
// link stays (SenseAboutView).
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../../../models/platform_model.dart';
import '../../controller/sense_home_about.dart';
import '../../controller/sense_home_strings.dart';
import '../../controller/sense_update_model.dart';
import '../../../components/sense_version_chip.dart' show senseAppVersion;

class SenseHostAbout extends StatelessWidget {
  const SenseHostAbout({super.key});

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: bind.mainSenseUpdateStatus(),
        builder: (context, update) => FutureBuilder<String>(
          future: bind.mainGetVersion(),
          builder: (context, base) => SenseAboutView(
            key: const Key('sense-host-about'),
            version: senseAppVersion(),
            role: SenseHomeRole.host,
            account: '',
            baseVersion: base.data ?? '',
            onOpenUrl: (url) => launchUrlString(url),
            updateText: senseAboutUpdateText(SenseUpdateStatus.parse(update.data ?? ''),
                DateTime.now().millisecondsSinceEpoch ~/ 1000),
          ),
        ),
      );
}
