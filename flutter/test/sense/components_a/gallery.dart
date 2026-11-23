// Sense Remote: every A2a component in its states, for the golden images and the
// small-screen checks (YH T7, T9). Texts are the prototype's.
import 'package:flutter/material.dart';
import 'package:flutter_hbb/sense/components/button.dart';
import 'package:flutter_hbb/sense/components/card.dart';
import 'package:flutter_hbb/sense/components/chip.dart';
import 'package:flutter_hbb/sense/components/header_row.dart';
import 'package:flutter_hbb/sense/components/inline_edit.dart';
import 'package:flutter_hbb/sense/components/led.dart';
import 'package:flutter_hbb/sense/components/segment.dart';
import 'package:flutter_hbb/sense/components/spinner.dart';
import 'package:flutter_hbb/sense/components/stat_tile.dart';
import 'package:flutter_hbb/sense/components/toggle.dart';
import 'package:flutter_hbb/sense/tokens/sense_tokens.dart';

void _noop() {}

Widget galleryButtons() => Wrap(spacing: 8, runSpacing: 8, children: const [
      SenseButton(label: 'Ekran', onPressed: _noop),
      SenseButton(label: 'Bağlan', kind: SenseButtonKind.primary, onPressed: _noop),
      SenseButton(label: 'Devam', kind: SenseButtonKind.primary, onPressed: null),
      SenseButton(label: 'Kayıt', kind: SenseButtonKind.on, onPressed: _noop),
      SenseButton(label: 'Bitir', kind: SenseButtonKind.danger, onPressed: _noop),
      SenseButton(label: 'Yine de dene', size: SenseButtonSize.small, onPressed: _noop),
      SenseButton(label: 'Meşgul', size: SenseButtonSize.small, onPressed: null),
    ]);

Widget galleryToggles() => SizedBox(
      width: 420,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Row(children: [
          SenseToggle(value: true, onChanged: _bool),
          SizedBox(width: 12),
          SenseToggle(value: false, onChanged: _bool),
          SizedBox(width: 12),
          SenseToggle(value: true, onChanged: _bool, locked: true),
          SizedBox(width: 12),
          SenseToggle(value: false, onChanged: _bool, compact: true),
          SizedBox(width: 12),
          SenseToggle(value: true, onChanged: _bool, compact: true),
        ]),
        const SenseToggleRow(
            label: 'Sekmeler arasında pano eşitle', description: 'Kopyalanan metin bütün oturumlarda',
            value: true, onChanged: _bool),
        const SenseToggleRow(label: 'Hareketsiz kes', value: true, onChanged: _bool, locked: true),
        SenseSettingRow(
          label: 'Görüntü kalitesi',
          last: true,
          control: SenseSegment<int>(
            expand: false,
            options: const [
              SenseSegmentOption(value: 0, label: 'Kalite'),
              SenseSegmentOption(value: 1, label: 'Dengeli'),
              SenseSegmentOption(value: 2, label: 'Hız'),
            ],
            value: 1,
            onChanged: (_) {},
          ),
        ),
      ]),
    );

void _bool(bool _) {}

Widget gallerySegments() => SizedBox(
      width: 420,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SenseSegment<String>(
          options: const [
            SenseSegmentOption(value: 'a', label: 'Uyar'),
            SenseSegmentOption(value: 'b', label: 'Kırp'),
            SenseSegmentOption(value: 'c', label: 'Ölçekle'),
          ],
          value: 'b',
          onChanged: (_) {},
        ),
        const SizedBox(height: 8),
        SenseSegment<String>(
          locked: true,
          options: const [
            SenseSegmentOption(value: 'a', label: 'Açık'),
            SenseSegmentOption(value: 'b', label: 'Kapalı'),
          ],
          value: 'a',
          onChanged: (_) {},
        ),
      ]),
    );

Widget galleryChipsAndLeds() => const Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SenseChip(label: 'Yalnız izle'),
      SenseChip(label: 'Verildi', level: SenseLevel.ok),
      SenseChip(label: 'Disk %88', level: SenseLevel.warn),
      SenseChip(label: 'Kesildi', level: SenseLevel.hot),
      SenseChip(label: 'Bellek', level: SenseLevel.hot, onTap: _noop),
      SensePill(label: 'Bugün', selected: true, onTap: _noop),
      SensePill(label: 'Dün', onTap: _noop),
      SenseLed(level: SenseLevel.ok),
      SenseLed(level: SenseLevel.warn),
      SenseLed(level: SenseLevel.hot),
      SenseLed(level: SenseLevel.unknown),
      SenseSpinner(),
      SenseSpinner(size: 11),
    ]);

Widget galleryTiles() => const SizedBox(
      width: 480,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SenseStatGrid(children: [
          SenseStatTile(label: 'İşlemci', value: '%42', level: SenseLevel.ok),
          SenseStatTile(label: 'Bellek', value: '%88', level: SenseLevel.warn),
          SenseStatTile(label: 'Disk', value: '%97', level: SenseLevel.hot),
          SenseStatTile(label: 'GPU sıcaklığı', value: null),
          SenseStatTile(label: 'Ekran', value: '2'),
        ]),
        SizedBox(height: 8),
        SizedBox(
          width: 300,
          child: SenseStatGrid(minTileWidth: 80, children: [
            SenseStatTile(label: 'gecikme', value: '182 ms', level: SenseLevel.warn, large: true),
            SenseStatTile(label: 'kayıp', value: '%6', level: SenseLevel.hot, large: true),
            SenseStatTile(label: 'kare', value: '24 fps', level: SenseLevel.ok, large: true),
          ]),
        ),
      ]),
    );

Widget galleryCards() => SizedBox(
      width: 400,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SenseCard(
          title: 'Disk C: · NVMe 512 GB',
          level: SenseLevel.warn,
          copyText: 'C: 476 GB',
          child: const Column(children: [
            SenseCardRow(label: 'Doluluk', value: '%88 · 419 / 476 GB', level: SenseLevel.warn),
            SenseCardRow(label: 'Sıcaklık', value: null),
            SenseCardRow(label: 'Sağlık', value: 'İyi', last: true),
          ]),
        ),
        const SizedBox(height: 8),
        const SenseCard(
          title: 'Ethernet',
          copyText: '192.0.2.10',
          child: SenseCardRow(label: 'Hız', value: '1 Gbit/s', last: true),
        ),
      ]),
    );

Widget galleryHeader() => SizedBox(
      width: 900,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SenseHeaderRow(
          title: 'Bilgisayarlar',
          status: '12/40 çevrimiçi',
          trailing: [SenseButton(label: 'Kimlikle bağlan', size: SenseButtonSize.small, onPressed: _noop)],
        ),
        const SenseHeaderRow(title: 'Bakım', titleThin: ' yapılıyor', large: true),
        const SenseLiveStatus(text: 'Canlı · 8 sn önce'),
        const SizedBox(height: 8),
        SenseInlineEdit(value: 'Galeri kioskı', onSubmitted: (_) {}),
      ]),
    );

/// Everything at once (small-screen check).
Widget galleryAll() => SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Wrap(spacing: 24, runSpacing: 24, children: [
        galleryHeader(),
        galleryButtons(),
        galleryToggles(),
        gallerySegments(),
        galleryChipsAndLeds(),
        galleryTiles(),
        galleryCards(),
      ]),
    );
