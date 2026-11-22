// Sense Remote: golden images of the A2a components (İnşa planı §5; YH T7).
// Rendered on the Linux CI runner with the bundled Poppins (test/flutter_test_config.dart).
// Compare against the prototype classes: `.btn`, `.tgl`/`.sw`/`.srow`, `.seg`, `.chip3`,
// `.led`, `.spin`, `.kv`/`.nmv`, `.sc`, `.ahead`, `.mefld`. A missing image is skipped
// until the golden job creates it (harness.dart).
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/sense/components/button.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gallery.dart';
import 'harness.dart';

const _key = Key('golden');

Future<void> _shot(WidgetTester tester, Widget child, String name) async {
  await pumpSense(
    tester,
    RepaintBoundary(
      key: _key,
      child: Container(
        color: SenseColors.bg,
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
    size: const Size(1280, 720),
  );
  await expectLater(find.byKey(_key), matchesGoldenFile(goldenPath(name)));
}

void main() {
  final shots = <String, Widget Function()>{
    'button_states': galleryButtons,
    'toggle_rows': galleryToggles,
    'segment_states': gallerySegments,
    'chips_leds_spinner': galleryChipsAndLeds,
    'stat_tiles': galleryTiles,
    'cards': galleryCards,
    'header_inline_edit': galleryHeader,
  };
  shots.forEach((name, build) {
    testWidgets('golden $name', (tester) async {
      await _shot(tester, build(), name);
    }, skip: goldenSkip(name));
  });

  testWidgets('golden button_hover_focus', (tester) async {
    await pumpSense(
      tester,
      RepaintBoundary(
        key: _key,
        child: Container(
          color: SenseColors.bg,
          padding: const EdgeInsets.all(16),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SenseButton(label: 'Odakta', onPressed: () {}),
            const SizedBox(width: 12),
            SenseButton(label: 'Üzerinde', onPressed: () {}),
            const SizedBox(width: 12),
            SenseButton(label: 'Bağlan', kind: SenseButtonKind.primary, onPressed: () {}),
          ]),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await hover(tester, find.text('Üzerinde'));
    await expectLater(find.byKey(_key), matchesGoldenFile(goldenPath('button_hover_focus')));
  }, skip: goldenSkip('button_hover_focus'));
}
