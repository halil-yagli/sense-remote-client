// Sense Remote: window frame, step list and the shared pieces of the setup wizard (YH K1;
// prototype `.awin.setup`, `.srail-brand`, `.sstep`, `.sfoot`, `.ov`, `.kv`, `.fld`, `.chip2`).
// Pieces the component library does not have yet live here (reported in the B1 PR):
// the role card, the choice chip (`.chip2`), the text field (`.afield`), the summary tiles
// (`.kv`), the plain box (`.ov` without a title) and the progress line (`.aupd`).

part of 'sense_install_wizard.dart';

/// Prototype sizes of the setup window (px; `.awin.setup`, `.srail`, `.amain`, `.sfoot`).
abstract final class _L {
  static const double titleBar = 36;
  static const double titlePadH = 12;
  static const double titleGap = 9;
  static const double macTrafficLights = 64;
  static const double closeWidth = 40;
  static const double rail = 220;
  static const double railPadV = 18;
  static const double railPadH = 14;
  static const double stepGap = 4;
  static const double stepCircle = 20;
  static const double mainPadTop = 18;
  static const double mainPadH = 22;
  static const double mainPadBottom = 20;
  static const double gap = 10;
  static const double boxRadius = 10;
  static const double fieldRadius = 9;
  static const double fieldHeight = 32;
  static const double chipRadius = 16;
  static const double cardRadius = 12;
  static const double tileMin = 150;
  static const double tileGap = 8;
  static const double leadHeight = 1.55;
}

extension _SenseInstallLayout on _SenseInstallWizardState {
  // ---- Frame ----

  Widget _titleBar() {
    return Container(
      height: _L.titleBar,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: SenseColors.line)),
      ),
      child: Row(
        children: [
          // macOS keeps its own window buttons at the top left.
          SizedBox(width: widget.mac ? _L.macTrafficLights : _L.titlePadH),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => widget.onDragStart?.call(),
              child: Row(children: [
                const SenseMark(width: 17, height: 15),
                const SizedBox(width: _L.titleGap),
                _brand(SenseFontSize.bodySmall, SenseColors.textSecondary),
                const SizedBox(width: _L.titleGap),
                Text(_t('title-suffix'),
                    style: SenseTextStyles.of(
                        size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
              ]),
            ),
          ),
          // YH K1: Windows has only Kapat (not while installing).
          if (!widget.mac)
            SenseInteractive(
              key: const Key('sense-window-close'),
              onTap: _busy ? null : _close,
              tooltip: _t('close'),
              semanticLabel: _t('close'),
              builder: (_, s) => Container(
                width: _L.closeWidth,
                height: _L.titleBar,
                color: s.hovered ? SenseColors.hover : null,
                alignment: Alignment.center,
                child: Icon(Icons.close,
                    size: SenseFontSize.categoryTitle,
                    color: _busy ? SenseColors.textDim : SenseColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  /// "**Sense** Remote".
  Widget _brand(double size, Color color) => Text.rich(
        TextSpan(children: [
          TextSpan(text: 'Sense', style: TextStyle(fontWeight: SenseFontWeight.bold)),
          const TextSpan(text: ' Remote'),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: SenseTextStyles.of(size: size, color: color),
      );

  List<(SenseInstallStep, String)> get _steps {
    if (widget.upgrade != null) {
      return [
        (SenseInstallStep.upgrade, 'step-upgrade'),
        if (widget.mac) (SenseInstallStep.permissions, 'step-permissions'),
      ];
    }
    return [
      if (widget.mac) (SenseInstallStep.applications, 'step-apps'),
      (SenseInstallStep.account, 'step-account'),
      (SenseInstallStep.role, 'step-role'),
      (SenseInstallStep.info, 'step-info'),
      (SenseInstallStep.summary, 'step-summary'),
      if (widget.mac) (SenseInstallStep.permissions, 'step-permissions'),
      (SenseInstallStep.done, 'step-done'),
    ];
  }

  Widget _rail() {
    final steps = _steps;
    // The upgrade's own done page belongs to its step.
    final current = steps.indexWhere((s) => s.$1 == _step);
    final version = widget.version.trim();
    final os = _t(widget.mac ? 'os-mac' : 'os-windows');
    return Container(
      width: _L.rail,
      padding: const EdgeInsets.symmetric(vertical: _L.railPadV, horizontal: _L.railPadH),
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: SenseColors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
            child: Row(children: [
              const SenseMark(width: 22, height: 20),
              const SizedBox(width: _L.titleGap),
              Flexible(child: _brand(SenseFontSize.categoryTitle, SenseColors.text)),
            ]),
          ),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: _L.stepGap),
              child: _stepRow(i + 1, _t(steps[i].$2),
                  done: _upgradeDone || i < current,
                  current: i == current && !_upgradeDone,
                  key: Key('sense-step-${steps[i].$1.name}')),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              version.isEmpty ? os : '${_t('version')} $version · $os',
              key: const Key('sense-version'),
              style: SenseTextStyles.of(size: SenseFontSize.caps, color: SenseColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(int number, String label,
      {required bool done, required bool current, Key? key}) {
    final circle = BoxDecoration(
      shape: BoxShape.circle,
      color: current ? SenseColors.text : null,
      border: Border.all(
          color: current
              ? SenseColors.text
              : done
                  ? SenseColors.ok
                  : SenseColors.lineStrong),
    );
    return Semantics(
      key: key,
      selected: current,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
        child: Row(children: [
          Container(
            width: _L.stepCircle,
            height: _L.stepCircle,
            alignment: Alignment.center,
            decoration: circle,
            child: done
                ? const Icon(Icons.check, size: SenseFontSize.bodySmall, color: SenseColors.ok)
                : Text('$number',
                    style: SenseTextStyles.of(
                        size: SenseFontSize.caps,
                        weight: current ? SenseFontWeight.bold : SenseFontWeight.regular,
                        color: current ? SenseColors.bg : SenseColors.textMuted)),
          ),
          const SizedBox(width: _L.gap),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SenseTextStyles.of(
                    size: SenseFontSize.bodySmall,
                    weight: current ? SenseFontWeight.bold : SenseFontWeight.regular,
                    color: current
                        ? SenseColors.text
                        : done
                            ? SenseColors.textSecondary
                            : SenseColors.textMuted)),
          ),
        ]),
      ),
    );
  }

  Widget _main() {
    final (content, footer) = switch (_step) {
      SenseInstallStep.upgrade => _upgradePage(),
      SenseInstallStep.applications => _applicationsPage(),
      SenseInstallStep.account => _accountPage(),
      SenseInstallStep.role => _rolePage(),
      SenseInstallStep.info => _infoPage(),
      SenseInstallStep.summary => _summaryPage(),
      SenseInstallStep.permissions => _permissionsPage(),
      SenseInstallStep.done => _donePage(),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          _L.mainPadH, _L.mainPadTop, _L.mainPadH, _L.mainPadBottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: const Key('sense-install-scroll'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < content.length; i++) ...[
                    if (i > 0) const SizedBox(height: _L.gap),
                    content[i],
                  ],
                ],
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.only(top: _L.gap),
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: SenseColors.line)),
            ),
            child: Row(children: [
              for (var i = 0; i < footer.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                footer[i],
              ],
            ]),
          ),
        ],
      ),
    );
  }

  // ---- Page parts ----

  /// Page title (`.ahead.big h1`, 22): thin text with a bold part, and the lead under it.
  Widget _header(List<(String, bool)> parts, String lead) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text.rich(
              TextSpan(children: [
                for (final (text, bold) in parts)
                  TextSpan(
                      text: text,
                      style: TextStyle(
                          fontWeight: bold ? SenseFontWeight.bold : SenseFontWeight.thin)),
              ]),
              style: SenseTextStyles.of(size: SenseFontSize.setupTitle),
            ),
          ),
          if (lead.isNotEmpty) ...[
            const SizedBox(height: 4),
            _lead(lead),
          ],
        ],
      );

  Widget _lead(String text, {TextAlign? align, Key? key}) => Text(text,
      key: key,
      textAlign: align,
      style: SenseTextStyles.of(color: SenseColors.textMuted, height: _L.leadHeight));

  /// Footer note (`.sfoot .note2`); takes the free space.
  Widget _footNote(String text, {Key? key}) => Expanded(
        child: Text(text,
            key: key,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: SenseTextStyles.of(size: SenseFontSize.hint, color: SenseColors.textMuted)),
      );

  /// Small hint (`.hint2`).
  Widget _hint(String text, {Key? key}) => Text(text,
      key: key,
      style: SenseTextStyles.of(
          size: SenseFontSize.hintSmall, color: SenseColors.textMuted, height: 1.5));

  /// Small grey text inside a box (`.hmeta`).
  Widget _meta(String text, {Color color = SenseColors.textMuted, Key? key}) => Text(text,
      key: key, style: SenseTextStyles.of(size: SenseFontSize.hint, color: color, height: 1.5));

  Widget _button(String label, VoidCallback? onPressed,
          {bool primary = false, Key? key}) =>
      SenseButton(
        key: key,
        label: label,
        onPressed: onPressed,
        size: SenseButtonSize.small,
        kind: primary ? SenseButtonKind.primary : SenseButtonKind.normal,
      );

  /// A titled box in place (`.ov`, `.ov.warn`, `.ov.hot`, `.ov.ok`).
  Widget _statusBox(SenseLevel level, String title, List<Widget> children, {Key? key}) =>
      KeyedSubtree(
        key: key,
        child: SenseStatusBox(level: level, title: title, children: children),
      );

  /// Buttons under a box text.
  Widget _boxActions(List<Widget> buttons) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(spacing: 6, runSpacing: 6, children: buttons),
      );

  /// A plain box without a title (`.ov`).
  Widget _box(Widget child, {Color border = SenseColors.line, Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: SenseColors.bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(_L.boxRadius),
        ),
        child: child,
      );

  /// Work in progress (`.aupd`): spinner and a line of text.
  Widget _progress(String text, {Key? key}) => Container(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(_L.boxRadius),
        ),
        child: Row(children: [
          const SenseSpinner(size: 11),
          const SizedBox(width: SenseUi.iconGap),
          Expanded(child: Text(text, style: SenseTextStyles.bodySmall)),
        ]),
      );

  /// A labelled field (`.fld` + `.afield`).
  Widget _field(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label,
              style: SenseTextStyles.of(
                  size: SenseFontSize.hintLarge, color: SenseColors.textMuted)),
          const SizedBox(height: 5),
          child,
        ],
      );

  Widget _textInput(TextEditingController controller,
          {required String hint, required int maxLength, Key? key}) =>
      Container(
        height: _L.fieldHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(_L.fieldRadius),
        ),
        child: TextField(
          key: key,
          controller: controller,
          enabled: !_busy,
          style: SenseTextStyles.bodySmall,
          cursorColor: SenseColors.text,
          inputFormatters: [LengthLimitingTextInputFormatter(maxLength)],
          decoration: InputDecoration.collapsed(
            hintText: hint,
            hintStyle: SenseTextStyles.of(
                size: SenseFontSize.bodySmall, color: SenseColors.textMuted),
          ),
        ),
      );

  /// Choice chip (`.chip2`): white when chosen.
  Widget _chip(String label, bool selected, VoidCallback? onTap,
          {String? prefix, Key? key}) =>
      SenseInteractive(
        key: key,
        onTap: onTap,
        selected: selected,
        semanticLabel: prefix == null ? label : '$prefix $label',
        builder: (_, s) => SenseFocusRing(
          visible: s.focused,
          radius: _L.chipRadius,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 11),
            decoration: BoxDecoration(
              color: selected ? SenseColors.text : SenseColors.bg,
              border: Border.all(
                  color: selected
                      ? SenseColors.text
                      : s.hovered
                          ? SenseColors.lineStrong
                          : SenseColors.line),
              borderRadius: BorderRadius.circular(_L.chipRadius),
            ),
            child: Text.rich(
              TextSpan(children: [
                if (prefix != null)
                  TextSpan(
                      text: '$prefix  ',
                      style: TextStyle(
                          fontSize: SenseFontSize.capsSmall,
                          color: (selected ? SenseColors.bg : SenseColors.textMuted))),
                TextSpan(text: label),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SenseTextStyles.of(
                  size: SenseFontSize.hintLarge,
                  color: selected ? SenseColors.bg : SenseColors.textSecondary),
            ),
          ),
        ),
      );

  /// Summary tiles (`.kv`): columns of at least 150 px, rows as tall as their tallest tile.
  Widget _tiles(List<(String, String, SenseLevel?)> tiles,
          {double valueSize = SenseFontSize.bodySmall}) =>
      LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cols = ((width + _L.tileGap) / (_L.tileMin + _L.tileGap))
            .floor()
            .clamp(1, tiles.length)
            .toInt();
        final rows = <Widget>[];
        for (var r = 0; r < tiles.length; r += cols) {
          final cells = <Widget>[];
          for (var c = 0; c < cols; c++) {
            if (c > 0) cells.add(const SizedBox(width: _L.tileGap));
            final i = r + c;
            cells.add(Expanded(
                child: i < tiles.length
                    ? _tile(tiles[i].$1, tiles[i].$2, tiles[i].$3, valueSize)
                    : const SizedBox()));
          }
          if (r > 0) rows.add(const SizedBox(height: _L.tileGap));
          rows.add(IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells)));
        }
        return Column(mainAxisSize: MainAxisSize.min, children: rows);
      });

  Widget _tile(String label, String value, SenseLevel? level, double valueSize) => Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: SenseColors.surface,
          border: Border.all(color: SenseColors.line),
          borderRadius: BorderRadius.circular(_L.fieldRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: SenseTextStyles.of(size: SenseFontSize.caps, color: SenseColors.textMuted)),
            const SizedBox(height: 2),
            // A value without a space (the e-mail) stays on one line with an ellipsis
            // instead of breaking in the middle of a word (K5).
            Text(value,
                key: Key('sense-tile-value-$label'),
                maxLines: value.contains(RegExp(r'\s')) ? null : 1,
                // Ellipsis only on the single line: on a wrapping value it would cut the 2nd line.
                overflow: value.contains(RegExp(r'\s')) ? TextOverflow.clip : TextOverflow.ellipsis,
                style: SenseTextStyles.of(
                    size: valueSize,
                    weight: SenseFontWeight.bold,
                    color: level == SenseLevel.ok ? SenseColors.ok : SenseColors.text)),
          ],
        ),
      );

  /// Green ring with a tick (`.okring`), with a soft glow (K7).
  Widget _okRing() => Container(
        width: 60,
        height: 60,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: SenseColors.ok, width: 2),
          boxShadow: [BoxShadow(color: SenseColors.ok.withOpacity(0.25), blurRadius: 24)],
        ),
        child: const Icon(Icons.check, size: 28, color: SenseColors.ok),
      );

  /// Centered result page (Kuruldu, Güncelleme başladı).
  Widget _resultPage(String title, List<String> lines, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.only(top: 40),
        child: Column(children: [
          _okRing(),
          const SizedBox(height: 12),
          Text(title,
              style: SenseTextStyles.of(
                  size: SenseFontSize.setupTitle, weight: SenseFontWeight.bold)),
          for (final line in lines) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: _lead(line, align: TextAlign.center),
            ),
          ],
        ]),
      );
}
