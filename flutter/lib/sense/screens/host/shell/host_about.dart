// Sense Remote: "Hakkında" of the Host (YH H1, C4, TK9 Risk H1). Shown inside the
// Host window, never through the settings tab page, so the Host has no way to
// the settings. Same page as the Controller About (B4: status box, tiles,
// "Açık kaynak lisansları" category with the AGPL notice, © line); the Host has
// no Kimlik tile and no panel sign-in. The permanent password is not here (it is
// a category of "Bu bilgisayar").
import 'package:flutter/widgets.dart';

import '../../controller/about/sense_about_page.dart';
import '../../controller/sense_home_strings.dart' show SenseHomeRole;

/// The app's About data, always as a Host.
class SenseHostAboutBridge extends SenseAboutBridge {
  SenseHostAboutBridge();

  @override
  SenseHomeRole role() => SenseHomeRole.host;

  @override
  String account() => '';
}

class SenseHostAbout extends StatelessWidget {
  const SenseHostAbout({super.key});

  @override
  Widget build(BuildContext context) =>
      SenseAboutView(key: const Key('sense-host-about'), backend: SenseHostAboutBridge());
}
