// Sense Remote (Sürüm 12): the glue in the stock files — screenshot name and folder (#159),
// Turkish window titles without the id (#162-8), the theme of fallback boxes (ST 0).
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show getWindowName, getWindowNameWithId, kSenseDialogs;
import 'package:flutter_hbb/common/sense_theme.dart';
import 'package:flutter_hbb/models/model.dart'
    show senseScreenshotFileName, senseScreenshotTarget, senseScreenshotReason;
import 'package:flutter_hbb/sense/sense.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart' show WindowType;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('#159 screenshot file', () {
    final t = DateTime(2026, 11, 28, 14, 5, 33);

    test('{bilgisayar}_{tarih-saat}.png', () {
      expect(senseScreenshotFileName('Galeri kioskı 2', t), 'Galeri-kioskı-2_2026-11-28_14-05-33.png');
    });

    test('characters a file name cannot hold are dropped; no name → "bilgisayar"', () {
      expect(senseScreenshotFileName('Sergi/Salon: A*?', t), 'SergiSalon-A_2026-11-28_14-05-33.png');
      expect(senseScreenshotFileName('  ', t), 'bilgisayar_2026-11-28_14-05-33.png');
    });

    test('Downloads folder, Windows and Mac separators; an existing file is not overwritten', () {
      final taken = {r'C:\Users\a\Downloads\x_1.png', r'C:\Users\a\Downloads\x_1-2.png'};
      expect(senseScreenshotTarget(r'C:\Users\a\Downloads', 'x_1.png', taken.contains),
          r'C:\Users\a\Downloads\x_1-3.png');
      expect(senseScreenshotTarget('/Users/a/Downloads/', 'x_1.png', (_) => false), '/Users/a/Downloads/x_1.png');
    });

    test('the core error text becomes a Turkish reason', () {
      expect(senseScreenshotReason('No cached screenshot'), 'görüntü alınamadı');
      expect(senseScreenshotReason('Access is denied. (os error 5)'), 'dosya yazılamadı');
    });
  });

  group('#162-8 window titles', () {
    test('Turkish, "· Sense Remote"', () {
      expect(getWindowName(overrideType: WindowType.FileTransfer), 'Uzak dosyalar · Sense Remote');
      expect(getWindowName(overrideType: WindowType.PortForward), 'TCP tünel · Sense Remote');
      expect(getWindowName(overrideType: WindowType.ViewCamera), 'Kamera · Sense Remote');
      expect(getWindowName(overrideType: WindowType.RemoteDesktop), 'Uzak masaüstü · Sense Remote');
      expect(getWindowName(overrideType: WindowType.Terminal), 'Terminal · Sense Remote');
      expect(getWindowName(overrideType: WindowType.Main), 'Sense Remote');
    });

    test('no computer id in the title', () {
      expect(kSenseDialogs, isTrue);
      final title = getWindowNameWithId('123456789', overrideType: WindowType.FileTransfer);
      expect(title, isNot(contains('123456789')));
      expect(title, 'Uzak dosyalar · Sense Remote');
    });
  });

  group('ST 0 theme of fallback boxes', () {
    final theme = senseDarkTheme(ThemeData.dark());

    test('dialog frame from the tokens', () {
      expect(theme.dialogTheme.backgroundColor, SenseColors.surface);
      final shape = theme.dialogTheme.shape as RoundedRectangleBorder;
      expect(shape.side.color, SenseColors.line);
      expect(theme.dialogTheme.titleTextStyle?.fontSize, SenseFontSize.popupTitle);
    });

    test('fields, text buttons, check boxes: no stock blue', () {
      expect(theme.inputDecorationTheme.fillColor, SenseColors.bg);
      expect(theme.textButtonTheme.style?.foregroundColor?.resolve({}), SenseColors.text);
      expect(theme.checkboxTheme.fillColor?.resolve({MaterialState.selected}), SenseColors.text);
      expect(theme.progressIndicatorTheme.color, SenseColors.text);
    });
  });
}
