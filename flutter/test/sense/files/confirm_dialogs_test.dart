// Sense Remote (Sürüm 12, #162, UD'nin bıraktığı): overwrite / delete questions of the remote
// files window in the Sense dialog — answers stay the stock ones (true / null / false), the
// "for all" check row works, Esc stops, Enter confirms; goldens.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/sense/components/sense_dialog.dart';
import 'package:flutter_hbb/sense/screens/files/file_confirm_dialogs.dart';
import 'package:flutter_hbb/sense/strings/files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../connect_cards/support.dart' show pumpCard;

const String _dir = 'test/goldens/files';
String _file(String name) => '../../goldens/files/$name.png';
bool _skip(String name) => !autoUpdateGoldenFiles && !File('$_dir/$name.png').existsSync();

class _Harness extends StatefulWidget {
  const _Harness({required this.overwrite, required this.answers, this.animateIn = true});
  final bool overwrite;
  final List<Object?> answers;
  final bool animateIn;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool remember = false;
  @override
  Widget build(BuildContext context) {
    final a = widget.answers;
    return Center(
      child: widget.overwrite
          ? senseFileOverwriteDialog(
              path: r'C:\Sergi\video\giris.mp4',
              identical: true,
              showRemember: true,
              remember: remember,
              onRemember: (v) => setState(() => remember = v),
              onStop: () => a.add(false),
              onSkip: () => a.add(null),
              onOverwrite: () => a.add(remember ? 'true+all' : true),
              animateIn: widget.animateIn,
            )
          : senseFileDeleteDialog(
              headline: senseFileDeleteHeadline(SenseFileDeleteKind.dirFile, index: 2, count: 5),
              path: r'C:\Sergi\eski\kayit-02.log',
              showRemember: true,
              remember: remember,
              onRemember: (v) => setState(() => remember = v),
              onCancel: () => a.add(false),
              onDelete: () => a.add(remember ? 'true+all' : true),
              animateIn: widget.animateIn,
            ),
    );
  }
}

void main() {
  test('delete headline: file, empty folder, a folder file with its count', () {
    expect(senseFileDeleteHeadline(SenseFileDeleteKind.file), 'Bu dosya silinsin mi?');
    expect(senseFileDeleteHeadline(SenseFileDeleteKind.emptyDir), 'Bu boş klasör silinsin mi?');
    expect(senseFileDeleteHeadline(SenseFileDeleteKind.dirFile, index: 2, count: 5),
        'Klasördeki bu dosya silinsin mi? (2/5)');
    expect(senseFileDeleteHeadline(SenseFileDeleteKind.file, index: 1, count: 1), 'Bu dosya silinsin mi?');
  });

  testWidgets('overwrite: Sense dialog, three stock answers, Esc stops', (tester) async {
    final answers = <Object?>[];
    await pumpCard(tester, _Harness(overwrite: true, answers: answers));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('sense-dialog')), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(SenseFilesStrings.overwriteHeadline), findsOneWidget);
    expect(find.text(SenseFilesStrings.overwriteIdentical), findsOneWidget);
    await tester.tap(find.byKey(const Key('sense-files-overwrite-skip')));
    await tester.tap(find.byKey(const Key('sense-files-overwrite-stop')));
    await tester.tap(find.byKey(const Key('sense-files-overwrite-remember')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sense-files-overwrite-ok')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(answers, [null, false, 'true+all', false]);
  });

  testWidgets('delete: red Sil, irreversible line, Enter confirms', (tester) async {
    final answers = <Object?>[];
    await pumpCard(tester, _Harness(overwrite: false, answers: answers));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Klasördeki bu dosya silinsin mi? (2/5)'), findsOneWidget);
    expect(find.text(SenseFilesStrings.deleteIrreversible), findsOneWidget);
    expect(tester.widget<SenseDialog>(find.byType(SenseDialog)).actions.last.kind.name, 'danger');
    await tester.tap(find.byKey(const Key('sense-files-delete-cancel')));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(answers, [false, true]);
  });

  testWidgets('golden: overwrite question', (tester) async {
    await pumpCard(tester, _Harness(overwrite: true, answers: [], animateIn: false));
    await tester.pump();
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file('files_overwrite')));
  }, skip: _skip('files_overwrite'), tags: const ['golden']);

  testWidgets('golden: delete question', (tester) async {
    await pumpCard(tester, _Harness(overwrite: false, answers: [], animateIn: false));
    await tester.pump();
    await expectLater(find.byKey(const Key('golden')), matchesGoldenFile(_file('files_delete')));
  }, skip: _skip('files_delete'), tags: const ['golden']);
}
