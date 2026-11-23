// Sense Remote: the Sense shell gets the whole home tab inside
// `buildRemoteBlock` (Sürüm 4 black window: the shell was laid out 0 × 0).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:flutter_hbb/common.dart' show buildRemoteBlock;
import 'package:flutter_hbb/sense/screens/home_body.dart';

void main() {
  Widget tab(Widget body) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 900,
            height: 600,
            child: buildRemoteBlock(block: false.obs, mask: true, child: body),
          ),
        ),
      );

  testWidgets('shell fills the home tab', (tester) async {
    await tester.pumpWidget(tab(senseHomeBody(
      status: const SizedBox(width: 10, height: 10),
      shell: const ColoredBox(key: Key('shell'), color: Color(0xFF123456)),
    )));
    expect(tester.getSize(find.byKey(const Key('shell'))), const Size(900, 600));
  });

  testWidgets('the old loose Stack gave the shell no room', (tester) async {
    await tester.pumpWidget(tab(Stack(children: const [
      Offstage(child: SizedBox(width: 10, height: 10)),
      Positioned.fill(
          child: ColoredBox(key: Key('shell'), color: Color(0xFF123456))),
    ])));
    expect(tester.getSize(find.byKey(const Key('shell'))), Size.zero);
  });
}
