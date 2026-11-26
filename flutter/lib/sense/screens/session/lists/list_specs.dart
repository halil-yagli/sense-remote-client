// Sense Remote: the four lists of the session bar (YH O3 Ekranlar, O4 Görüntü,
// O5 Klavye ve fare, O6 Eylemler) built from the session backend. Which items appear
// follows [SenseRules] (TK9 §3); items the person may not use are kept but locked
// (plan §2.1). Each entry names its RustDesk menu item in `rustdesk`.
import '../../../strings/session.dart';
import '../../../tokens/sense_tokens.dart';
import '../data/grants.dart';
import '../data/session_state.dart';
import 'backend.dart';
import 'list_model.dart';
import 'rules.dart';

typedef _S = SenseSessionStrings;

SenseListSpec senseBuildList(SenseBarMenu menu, SenseSessionBackend b) {
  switch (menu) {
    case SenseBarMenu.screens:
      return senseScreensList(b);
    case SenseBarMenu.display:
      return senseDisplayList(b);
    case SenseBarMenu.keyboard:
      return senseKeyboardList(b);
    case SenseBarMenu.actions:
      return senseActionsList(b);
  }
}

List<SenseListSection> _nonEmpty(List<SenseListSection> sections) =>
    [for (final s in sections) if (s.entries.isNotEmpty) s];

// ---------------------------------------------------------------------------
// O3 Ekranlar
// ---------------------------------------------------------------------------

SenseListSpec senseScreensList(SenseSessionBackend b) {
  final f = b.facts;
  final current = b.currentDisplay;
  final tiles = <SenseTile>[
    for (final d in b.displays) SenseTile(d.index, '${d.index + 1}', d.primary ? _S.primary : null),
    if (SenseRules.allTile(f)) const SenseTile(SenseRd.allDisplays, _S.all, _S.allSub),
  ];
  final frequent = <SenseListEntry>[
    if (SenseRules.displayTiles(f) && tiles.isNotEmpty)
      SenseTilesEntry(
        id: 'screens.tiles',
        label: _S.screens,
        rustdesk: 'Monitor buttons · All monitors',
        tiles: tiles,
        value: current,
        onPick: b.openDisplay,
      ),
    if (SenseRules.individualWindows(f))
      SenseToggleEntry(
        id: 'screens.individual',
        label: _S.individualWindows,
        rustdesk: 'Show displays as individual windows',
        value: b.individualWindows,
        onChanged: b.setIndividualWindows,
      ),
  ];

  final res = <SenseListEntry>[];
  if (SenseRules.resolution(f)) {
    final cur = b.currentResolution;
    final options = <SenseChoice>[
      if (b.originalResolution != null && b.originalResolution != cur)
        SenseChoice('orig', '${_S.resolutionOriginal} · ${b.originalResolution!.label}'),
      if (b.fitLocalResolution != null && b.fitLocalResolution != cur)
        SenseChoice('fit', '${_S.resolutionFitLocal} · ${b.fitLocalResolution!.label}'),
      for (final r in b.resolutions) SenseChoice(r.key, r.label),
    ];
    res.add(SenseChoiceEntry(
      id: 'screens.resolution',
      label: _S.resolution,
      rustdesk: 'Resolution',
      style: SenseChoiceStyle.radio,
      options: options,
      value: cur?.key,
      noRights: !b.grants.allows(SenseGrant.control),
      onChanged: (v) {
        if (v == 'orig') {
          b.setResolution(b.originalResolution!);
        } else if (v == 'fit') {
          b.setResolution(b.fitLocalResolution!);
        } else {
          for (final r in b.resolutions) {
            if (r.key == v) b.setResolution(r);
          }
        }
      },
    ));
    // R5: width × height, only on a virtual display resolution (RustDesk rule).
    if (SenseRules.customResolution(f)) {
      final start = b.customResolutionStart;
      res.add(SenseSizeInputEntry(
        id: 'screens.customResolution',
        label: _S.customResolution,
        hint: _S.customResolutionHint,
        rustdesk: 'Custom resolution (resolution_custom_tip)',
        width: start?.width,
        height: start?.height,
        noRights: !b.grants.allows(SenseGrant.control),
        onApply: (w, h) => b.setResolution(SenseResolution(w, h)),
      ));
    }
  }

  final virtualEntries = <SenseListEntry>[
    if (SenseRules.virtualDisplay(f)) ...[
      SenseActionEntry(
        id: 'screens.virtual.add',
        label: _S.virtualAdd,
        rustdesk: 'Virtual display',
        noRights: !b.grants.allows(SenseGrant.control),
        onTap: b.canAddVirtualDisplay && !f.privacyOn ? b.addVirtualDisplay : null,
      ),
      SenseActionEntry(
        id: 'screens.virtual.removeAll',
        label: _S.virtualRemoveAll,
        rustdesk: 'Plug out all',
        noRights: !b.grants.allows(SenseGrant.control),
        onTap: b.virtualDisplayCount > 0 && !f.privacyOn ? b.removeAllVirtualDisplays : null,
      ),
    ],
  ];

  return SenseListSpec(
    title: _S.screens,
    chip: current == SenseRd.allDisplays ? _S.allScreens : _S.screenN(current + 1),
    frequent: frequent,
    sections: _nonEmpty([
      SenseListSection(
        id: 'resolution',
        title: _S.resolution,
        summary: b.currentResolution?.label,
        entries: res,
      ),
      SenseListSection(
        id: 'multi',
        title: _S.multiMonitor,
        summary: b.useAllMyDisplays ? _S.allMine : _S.singleScreen,
        entries: [
          if (SenseRules.useAllMyDisplays(f))
            SenseToggleEntry(
              id: 'screens.allMine',
              label: _S.useAllMyDisplays,
              rustdesk: 'Use all my displays for the remote session',
              value: b.useAllMyDisplays,
              onChanged: b.setUseAllMyDisplays,
            ),
        ],
      ),
      SenseListSection(
        id: 'virtual',
        title: _S.virtualDisplay,
        summary: b.virtualDisplayCount > 0 ? _S.virtualCount(b.virtualDisplayCount) : _S.none,
        entries: virtualEntries,
      ),
    ]),
  );
}

// ---------------------------------------------------------------------------
// O4 Görüntü
// ---------------------------------------------------------------------------

String _qualityLabel(String q) => switch (q) {
      SenseRd.qualityBest => _S.qualityBest,
      SenseRd.qualityBalanced => _S.qualityBalanced,
      SenseRd.qualityLow => _S.qualityLow,
      SenseRd.qualityCustom => _S.customQuality,
      _ => _S.qualityBalanced,
    };

String _codecLabel(String c) => switch (c) {
      'auto' => _S.codecAuto,
      'vp8' => 'VP8',
      'vp9' => 'VP9',
      'av1' => 'AV1',
      'h264' => 'H.264',
      'h265' => 'H.265',
      _ => c.toUpperCase(),
    };

SenseListSpec senseDisplayList(SenseSessionBackend b) {
  final f = b.facts;
  final view = b.viewStyle;
  final custom = b.imageQuality == SenseRd.qualityCustom;
  final frequent = <SenseListEntry>[
    SenseChoiceEntry(
      id: 'display.size',
      label: _S.size,
      rustdesk: 'Scale adaptive · Scale original',
      options: const [SenseChoice(SenseRd.viewAdaptive, _S.fit), SenseChoice(SenseRd.viewOriginal, _S.original)],
      value: view == SenseRd.viewCustom ? null : view,
      onChanged: b.setViewStyle,
    ),
    SenseChoiceEntry(
      id: 'display.quality',
      label: _S.quality,
      rustdesk: 'Good image quality · Balanced · Optimize reaction time',
      options: const [
        SenseChoice(SenseRd.qualityBest, _S.qualityBest),
        SenseChoice(SenseRd.qualityBalanced, _S.qualityBalanced),
        SenseChoice(SenseRd.qualityLow, _S.qualityLow),
      ],
      value: custom ? null : b.imageQuality,
      onChanged: b.setImageQuality,
    ),
    SenseActionEntry(
      id: 'display.refresh',
      label: _S.refresh,
      rustdesk: 'Refresh',
      onTap: b.refreshVideo,
      toast: _S.refresh,
    ),
  ];

  final pct = b.viewScalePercent;
  final remote = b.currentResolution;
  final scale = <SenseListEntry>[
    // O1 "%N ölçekte": how large the remote image is drawn now.
    if (pct != null)
      SenseInfoEntry(
        id: 'display.scaleNote',
        label: _S.remoteImage,
        rustdesk: 'Scale (canvas, read only)',
        detail: remote == null ? _S.scaleNoteShort(pct) : _S.scaleNote(remote.width, remote.height, pct),
      ),
    SenseSliderEntry(
      id: 'display.customScale',
      label: _S.customScale,
      rustdesk: 'Scale custom',
      min: SenseRd.customScaleMin.toDouble(),
      max: SenseRd.customScaleMax.toDouble(),
      value: b.customScalePercent
          .clamp(SenseRd.customScaleMin, SenseRd.customScaleMax)
          .toDouble(),
      format: (v) => '%${v.round()}',
      onChanged: (v) => b.setCustomScalePercent(v.round()),
    ),
    if (SenseRules.scroll(view))
      SenseChoiceEntry(
        id: 'display.scroll',
        label: _S.scroll,
        rustdesk: 'ScrollAuto · Scrollbar · ScrollEdge',
        options: const [
          SenseChoice(SenseRd.scrollAuto, _S.scrollAuto),
          SenseChoice(SenseRd.scrollBar, _S.scrollBar),
          SenseChoice(SenseRd.scrollEdge, _S.scrollEdge),
        ],
        value: b.scrollStyle,
        onChanged: b.setScrollStyle,
      ),
    SenseActionEntry(
      id: 'display.resetView',
      label: _S.resetView,
      rustdesk: 'Reset canvas',
      onTap: b.resetView,
      toast: _S.resetView,
    ),
    if (b.canAdjustWindow)
      SenseActionEntry(
        id: 'display.adjustWindow',
        label: _S.adjustWindow,
        rustdesk: 'Adjust Window',
        onTap: b.adjustWindow,
      ),
  ];

  final quality = <SenseListEntry>[
    SenseToggleEntry(
      id: 'display.customQuality',
      label: _S.customQuality,
      rustdesk: 'Custom (image quality)',
      value: custom,
      onChanged: (on) => b.setImageQuality(on ? SenseRd.qualityCustom : SenseRd.qualityBalanced),
    ),
    SenseSliderEntry(
      id: 'display.qualityPct',
      label: _S.qualityPct,
      rustdesk: 'Custom image quality',
      min: SenseRd.qualityMin.toDouble(),
      max: SenseRd.qualityMax.toDouble(),
      value: b.customQuality.clamp(SenseRd.qualityMin, SenseRd.qualityMax).toDouble(),
      format: (v) => '%${v.round()}',
      onChanged: custom ? (v) => b.setCustomQuality(v.round()) : null,
    ),
    if (b.showCustomFps)
      SenseSliderEntry(
        id: 'display.fps',
        label: _S.frameRate,
        rustdesk: 'Custom FPS',
        min: SenseRd.fpsMin.toDouble(),
        max: SenseRd.fpsMax.toDouble(),
        value: b.customFps.clamp(SenseRd.fpsMin, SenseRd.fpsMax).toDouble(),
        format: (v) => '${v.round()} fps',
        onChanged: custom ? (v) => b.setCustomFps(v.round()) : null,
      ),
    if (SenseRules.trueColor(f))
      SenseToggleEntry(
        id: 'display.trueColor',
        label: _S.trueColor,
        rustdesk: 'True color (4:4:4)',
        value: b.trueColor,
        onChanged: b.setTrueColor,
      ),
  ];

  final codecs = b.codecs;
  final codecEntries = <SenseListEntry>[
    if (codecs.length > 1)
      SenseChoiceEntry(
        id: 'display.codec',
        label: _S.codec,
        rustdesk: 'Codec (Auto · VP8 · VP9 · AV1 · H264 · H265)',
        style: SenseChoiceStyle.radio,
        options: [
          for (final c in codecs)
            SenseChoice(
              c,
              c == 'auto' && b.activeCodec != null ? '${_S.codecAuto} (${b.activeCodec})' : _codecLabel(c),
            ),
        ],
        value: b.codec,
        onChanged: b.setCodec,
      ),
  ];

  final viewSummary = switch (view) {
    SenseRd.viewOriginal => _S.originalSize,
    SenseRd.viewCustom => '${_S.customScale} %${b.customScalePercent}',
    _ => pct == null ? _S.fitWindow : '${_S.fitWindow} · ${_S.scalePct(pct)}',
  };

  // R4: drawing settings of this computer (RustDesk settings page), for a black or
  // flickering image on some graphics cards; they apply to the next connection.
  final render = <SenseListEntry>[
    if (SenseRules.textureRender(f))
      SenseToggleEntry(
        id: 'display.textureRender',
        label: _S.textureRender,
        hint: _S.nextConnection,
        rustdesk: 'Use texture rendering',
        value: b.textureRender,
        onChanged: b.setTextureRender,
      ),
    if (SenseRules.d3dRender(f))
      SenseToggleEntry(
        id: 'display.d3dRender',
        label: _S.d3dRender,
        hint: _S.d3dHint,
        rustdesk: 'Use D3D rendering',
        value: b.d3dRender,
        onChanged: b.setD3dRender,
      ),
  ];
  final renderOn = [
    if (SenseRules.textureRender(f) && b.textureRender) _S.renderTexture,
    if (SenseRules.d3dRender(f) && b.d3dRender) _S.renderD3d,
  ];

  return SenseListSpec(
    title: _S.display,
    chip: _qualityLabel(b.imageQuality),
    frequent: frequent,
    sections: _nonEmpty([
      SenseListSection(id: 'scale', title: _S.scaleScroll, summary: viewSummary, entries: scale),
      SenseListSection(
        id: 'quality',
        title: _S.customQuality,
        summary: custom
            ? (b.showCustomFps ? '%${b.customQuality} · ${b.customFps} fps' : '%${b.customQuality}')
            : _S.off,
        entries: quality,
      ),
      SenseListSection(id: 'codec', title: _S.codec, summary: _codecLabel(b.codec), entries: codecEntries),
      SenseListSection(
        id: 'audio',
        title: _S.audio,
        summary: b.muted ? _S.off : _S.on,
        entries: [
          if (SenseRules.mute(f))
            SenseToggleEntry(
              id: 'display.mute',
              label: _S.mute,
              rustdesk: 'Mute',
              value: b.muted,
              onChanged: b.setMuted,
            ),
        ],
      ),
      SenseListSection(
        id: 'render',
        title: _S.renderSection,
        summary: renderOn.isEmpty ? _S.renderDefault : renderOn.join(' · '),
        entries: render,
      ),
    ]),
  );
}

// ---------------------------------------------------------------------------
// O5 Klavye ve fare
// ---------------------------------------------------------------------------

String _modeLabel(String m) => switch (m) {
      SenseRd.modeMap => _S.modeMap,
      SenseRd.modeTranslate => _S.modeTranslate,
      _ => _S.modeLegacy,
    };

SenseListSpec senseKeyboardList(SenseSessionBackend b) {
  final f = b.facts;
  final control = b.grants.allows(SenseGrant.control);
  final modes = b.keyboardModes;
  final mode = b.keyboardMode;
  final editable = !f.viewOnly;

  final frequent = <SenseListEntry>[
    if (f.keyboard && (modes.contains(SenseRd.modeMap) || modes.contains(SenseRd.modeTranslate)))
      SenseChoiceEntry(
        id: 'keyboard.mode',
        label: _S.keyboardMode,
        rustdesk: 'Map mode · Translate mode',
        options: [
          SenseChoice(SenseRd.modeMap, _S.modeMap, enabled: modes.contains(SenseRd.modeMap)),
          SenseChoice(SenseRd.modeTranslate, _S.modeTranslate, enabled: modes.contains(SenseRd.modeTranslate)),
        ],
        value: mode == SenseRd.modeLegacy ? null : mode,
        noRights: !control,
        onChanged: editable ? b.setKeyboardMode : null,
      ),
    if (f.keyboard)
      SenseToggleEntry(
        id: 'keyboard.viewOnly',
        label: _S.viewOnly,
        hint: _S.viewOnlyHint,
        rustdesk: 'View Mode',
        value: b.viewOnly,
        onLevel: SenseLevel.warn,
        onChanged: SenseRules.viewOnlyEnabled(f) ? b.setViewOnly : null,
      ),
    if (SenseRules.swapCtrlCmd(f))
      SenseToggleEntry(
        id: 'keyboard.swapCtrlCmd',
        label: _S.swapCtrlCmd,
        hint: _S.swapCtrlCmdHint,
        rustdesk: 'Swap control-command key',
        value: b.swapCtrlCmd,
        noRights: !control,
        onChanged: editable ? b.setSwapCtrlCmd : null,
      ),
  ];

  final keyboard = <SenseListEntry>[
    if (f.keyboard && modes.contains(SenseRd.modeLegacy))
      SenseToggleEntry(
        id: 'keyboard.legacy',
        label: _S.modeLegacy,
        rustdesk: 'Legacy mode',
        value: mode == SenseRd.modeLegacy,
        noRights: !control,
        onChanged: editable
            ? (on) => b.setKeyboardMode(on
                ? SenseRd.modeLegacy
                : (modes.contains(SenseRd.modeMap) ? SenseRd.modeMap : SenseRd.modeTranslate))
            : null,
      ),
    if (SenseRules.localKbLayout(f))
      SenseChoiceEntry(
        id: 'keyboard.localLayout',
        label: _S.localKeyboard,
        rustdesk: 'Local keyboard type',
        options: const [SenseChoice(SenseRd.kbIso, _S.kbIso), SenseChoice(SenseRd.kbNotIso, _S.kbNotIso)],
        value: b.localKbLayout.isEmpty ? null : b.localKbLayout,
        onChanged: editable ? b.setLocalKbLayout : null,
      ),
  ];

  final shortcuts = <SenseListEntry>[
    for (final s in b.shortcuts)
      SenseInfoEntry(
        id: 'shortcut.${s.actionId}',
        label: s.label,
        rustdesk: 'Keyboard shortcut: ${s.actionId}',
        detail: s.keys ?? _S.shortcutUnbound,
      ),
  ];

  final mouseOk = SenseRules.mouseOptions(f);
  final mouse = <SenseListEntry>[
    if (SenseRules.showRemoteCursor(f))
      SenseToggleEntry(
        id: 'mouse.showRemote',
        label: _S.showRemoteCursor,
        rustdesk: 'Show remote cursor',
        value: b.showRemoteCursor,
        onChanged: !f.viewOnly && !b.showRemoteCursorLocked ? b.setShowRemoteCursor : null,
      ),
    if (SenseRules.showMyCursor(f))
      SenseToggleEntry(
        id: 'mouse.showMine',
        label: _S.showMyCursor,
        rustdesk: 'Show my cursor',
        value: b.showMyCursor,
        onChanged: b.setShowMyCursor,
      ),
    if (SenseRules.followRemote(f)) ...[
      SenseToggleEntry(
        id: 'mouse.followCursor',
        label: _S.followRemoteCursor,
        rustdesk: 'Follow remote cursor',
        value: b.followRemoteCursor,
        onChanged: b.setFollowRemoteCursor,
      ),
      SenseToggleEntry(
        id: 'mouse.followWindow',
        label: _S.followRemoteWindow,
        rustdesk: 'Follow remote window focus',
        value: b.followRemoteWindow,
        onChanged: b.setFollowRemoteWindow,
      ),
    ],
    if (SenseRules.zoomCursor(f, b.viewStyle))
      SenseToggleEntry(
        id: 'mouse.zoom',
        label: _S.zoomCursor,
        rustdesk: 'Zoom cursor',
        value: b.zoomCursor,
        onChanged: b.setZoomCursor,
      ),
    if (SenseRules.relativeMouse(f))
      SenseToggleEntry(
        id: 'mouse.relative',
        label: _S.relativeMouse,
        hint: _S.relativeMouseHint,
        rustdesk: 'Relative mouse mode',
        value: b.relativeMouse,
        noRights: !control,
        onChanged: b.setRelativeMouse,
      ),
    if (mouseOk) ...[
      SenseToggleEntry(
        id: 'mouse.reverseWheel',
        label: _S.reverseWheel,
        rustdesk: 'Reverse mouse wheel',
        value: b.reverseWheel,
        noRights: !control,
        onChanged: editable ? b.setReverseWheel : null,
      ),
      SenseToggleEntry(
        id: 'mouse.swapButtons',
        label: _S.swapMouse,
        rustdesk: 'swap-left-right-mouse',
        value: b.swapMouseButtons,
        noRights: !control,
        onChanged: editable ? b.setSwapMouseButtons : null,
      ),
      SenseSliderEntry(
        id: 'mouse.trackpad',
        label: _S.trackpadSpeed,
        rustdesk: 'Trackpad speed',
        min: SenseRd.trackpadMin.toDouble(),
        max: SenseRd.trackpadListMax.toDouble(),
        value: b.trackpadSpeed.clamp(SenseRd.trackpadMin, SenseRd.trackpadListMax).toDouble(),
        format: (v) => '%${v.round()}',
        noRights: !control,
        onChanged: editable ? (v) => b.setTrackpadSpeed(v.round()) : null,
      ),
    ],
  ];

  final layout = SenseRules.localKbLayout(f) && b.localKbLayout.isNotEmpty
      ? ' · ${b.localKbLayout == SenseRd.kbIso ? _S.kbIso : _S.kbNotIso}'
      : '';

  return SenseListSpec(
    title: _S.keyboard,
    chip: b.viewOnly ? _S.tagViewOnly : _modeLabel(mode),
    chipLevel: b.viewOnly ? SenseLevel.warn : null,
    frequent: frequent,
    sections: _nonEmpty([
      SenseListSection(id: 'keyboard', title: _S.keyboardSection, summary: '${_modeLabel(mode)}$layout', entries: keyboard),
      SenseListSection(
        id: 'shortcuts',
        title: _S.shortcuts,
        summary: b.shortcutsEnabled ? _S.shortcutsSummary(shortcuts.length) : _S.shortcutsOff,
        entries: shortcuts,
      ),
      SenseListSection(id: 'mouse', title: _S.mouse, summary: _S.mouseSummary, entries: mouse),
    ]),
  );
}

// ---------------------------------------------------------------------------
// O6 Eylemler
// ---------------------------------------------------------------------------

SenseListSpec senseActionsList(SenseSessionBackend b) {
  final f = b.facts;
  final g = b.grants;
  final control = g.allows(SenseGrant.control);
  final files = g.allows(SenseGrant.fileTransfer);
  final editable = !f.viewOnly;

  final frequent = <SenseListEntry>[
    if (SenseRules.ctrlAltDel(f))
      SenseActionEntry(
        id: 'actions.ctrlAltDel',
        label: _S.ctrlAltDel,
        rustdesk: 'Insert Ctrl + Alt + Del',
        noRights: !control,
        onTap: b.ctrlAltDel,
        toast: _S.ctrlAltDel,
      ),
    if (SenseRules.screenshot(f))
      SenseActionEntry(
        id: 'actions.screenshot',
        label: b.screenshotBusy ? _S.screenshotBusy : _S.screenshot,
        hint: f.onAllDisplays ? _S.screenshotAll : null,
        rustdesk: 'Take screenshot',
        onTap: b.screenshotBusy || f.onAllDisplays ? null : b.screenshot,
      ),
    if (SenseRules.lockScreen(f))
      SenseActionEntry(
        id: 'actions.lock',
        label: _S.lockScreen,
        rustdesk: 'Insert Lock',
        noRights: !control,
        onTap: b.lockScreen,
        toast: _S.lockScreen,
      ),
    if (SenseRules.restart(f))
      SenseActionEntry(
        id: 'actions.restart',
        label: _S.restart,
        rustdesk: 'Restart remote device',
        noRights: !g.allows(SenseGrant.restartRemote),
        onTap: b.restart,
        confirmQuestion: _S.restartConfirm,
        confirmLabel: _S.restartGo,
      ),
    if (SenseRules.blockInput(f))
      SenseToggleEntry(
        id: 'actions.blockInput',
        label: _S.blockInput,
        rustdesk: 'Block user input',
        value: b.inputLocked,
        onLevel: SenseLevel.warn,
        noRights: !control,
        onChanged: b.setBlockInput,
      ),
    if (SenseRules.recording(f))
      SenseToggleEntry(
        id: 'actions.record',
        label: _S.record,
        rustdesk: 'Start session recording',
        value: b.recordingOn,
        onLevel: SenseLevel.hot,
        noRights: !g.allows(SenseGrant.recordSession),
        onChanged: (_) => b.toggleRecording(),
      ),
  ];

  final clipboard = <SenseListEntry>[
    if (SenseRules.typeClipboard(f))
      SenseActionEntry(
        id: 'actions.typeClipboard',
        label: _S.typeClipboard,
        rustdesk: 'Send clipboard keystrokes',
        noRights: !control,
        onTap: b.typeClipboard,
        toast: _S.typed,
      ),
    if (SenseRules.fileCopyPaste(f))
      SenseToggleEntry(
        id: 'actions.fileCopyPaste',
        label: _S.fileCopyPaste,
        rustdesk: 'Enable file copy and paste',
        value: b.fileCopyPaste,
        noRights: !files,
        onChanged: editable ? b.setFileCopyPaste : null,
      ),
    if (SenseRules.disableClipboard(f))
      SenseToggleEntry(
        id: 'actions.disableClipboard',
        label: _S.disableClipboard,
        rustdesk: 'Disable clipboard',
        value: f.viewOnly || b.clipboardDisabled,
        onChanged: editable ? b.setClipboardDisabled : null,
      ),
    if (SenseRules.remoteFiles(f))
      SenseActionEntry(
        id: 'actions.remoteFiles',
        label: _S.remoteFiles,
        hint: _S.remoteFilesHint,
        rustdesk: 'Transfer file',
        noRights: !files,
        onTap: b.openRemoteFiles,
      ),
  ];

  final session = <SenseListEntry>[
    if (SenseRules.elevation(f))
      SenseActionEntry(
        id: 'actions.elevation',
        label: _S.elevation,
        rustdesk: 'Request Elevation',
        noRights: !control,
        onTap: b.requestElevation,
      ),
    if (SenseRules.lockAfterEnd(f))
      SenseToggleEntry(
        id: 'actions.lockAfterEnd',
        label: _S.lockAfterEnd,
        rustdesk: 'Lock after session end',
        value: b.lockAfterEnd,
        onChanged: editable ? b.setLockAfterEnd : null,
      ),
    if (SenseRules.note(f))
      SenseActionEntry(
        id: 'actions.note',
        label: _S.note,
        rustdesk: 'Note',
        onTap: b.addNote,
      ),
  ];

  final terminal = g.allows(SenseGrant.terminalTunnel);
  final camera = SenseRules.viewCamera(f);
  final advanced = <SenseListEntry>[
    if (SenseRules.advanced(f)) ...[
      SenseActionEntry(
        id: 'actions.terminal',
        label: _S.terminal,
        rustdesk: 'Terminal',
        tag: _S.technical,
        noRights: !terminal,
        onTap: b.openTerminal,
      ),
      if (SenseRules.terminalAdmin(f))
        SenseActionEntry(
          id: 'actions.terminalAdmin',
          label: _S.terminalAdmin,
          hint: _S.terminalAdminHint,
          rustdesk: 'Terminal (Run as administrator)',
          tag: _S.technical,
          noRights: !terminal,
          onTap: b.openTerminalAdmin,
        ),
      SenseActionEntry(
        id: 'actions.tunnel',
        label: _S.tunnel,
        rustdesk: 'TCP tunneling',
        tag: _S.technical,
        noRights: !terminal,
        onTap: b.openTunnel,
      ),
    ],
    // O6: the computer's camera permission (panel) decides; the computer refuses the
    // camera connection itself when it is off.
    if (camera)
      SenseActionEntry(
        id: 'actions.camera',
        label: _S.camera,
        hint: _S.cameraHint,
        rustdesk: 'View camera',
        onTap: b.openCamera,
      ),
    if (SenseRules.forceRelay(f))
      SenseToggleEntry(
        id: 'actions.forceRelay',
        label: _S.forceRelay,
        hint: b.forceRelayEverywhere ? _S.forceRelayEverywhere : _S.forceRelayHint,
        rustdesk: 'Always connect via relay',
        value: b.forceRelayEverywhere || b.forceRelay,
        onChanged: b.forceRelayEverywhere ? null : b.setForceRelay,
      ),
    SenseActionEntry(
      id: 'actions.fingerprint',
      label: _S.fingerprint,
      rustdesk: 'Copy Fingerprint',
      onTap: b.fingerprint.isEmpty ? null : b.copyFingerprint,
      toast: _S.fingerprintCopied,
    ),
  ];

  return SenseListSpec(
    title: _S.actions,
    chip: b.recordingOn ? _S.tagRecording : null,
    chipLevel: b.recordingOn ? SenseLevel.hot : null,
    frequent: frequent,
    sections: _nonEmpty([
      SenseListSection(
        id: 'clipboard',
        title: _S.clipboardFiles,
        summary: (f.viewOnly || b.clipboardDisabled) ? _S.clipboardOff : _S.clipboardOpen,
        entries: clipboard,
      ),
      SenseListSection(id: 'session', title: _S.session, entries: session),
      SenseListSection(
        id: 'advanced',
        title: _S.advanced,
        summary: camera ? _S.advancedSummaryCamera : _S.advancedSummary,
        entries: advanced,
      ),
    ]),
  );
}
