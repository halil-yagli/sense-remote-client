import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/desktop/pages/file_manager_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:get/get.dart';

import '../../common/shared_state.dart';
import '../../models/platform_model.dart';
import '../../sense/screens/shared/aux_window/aux_label.dart';
import '../../sense/screens/shared/aux_window/aux_tab_window.dart';
import '../../sense/screens/shared/aux_window/aux_window_frame.dart';
import '../../sense/sense.dart' show SenseLevel;
import '../../sense/strings/files.dart';

/// File Transfer for multi tabs
class FileManagerTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const FileManagerTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<FileManagerTabPage> createState() => _FileManagerTabPageState(params);
}

class _FileManagerTabPageState extends State<FileManagerTabPage> {
  DesktopTabController get tabController => Get.find<DesktopTabController>();

  static const IconData selectedIcon = Icons.file_copy_sharp;
  static const IconData unselectedIcon = Icons.file_copy_outlined;

  _FileManagerTabPageState(Map<String, dynamic> params) {
    Get.put(DesktopTabController(tabType: DesktopTabType.fileTransfer));
    tabController.onSelected = (id) {
      WindowController.fromWindowId(windowId()).setTitle(senseAuxFrameOn()
          // Sense Remote (ST 16): Turkish title with the computer's name, no ID.
          ? senseAuxWindowTitle(SenseFilesStrings.title, id)
          : getWindowNameWithId(id));
    };
    tabController.onRemoved = (_, id) => onRemoveId(id);
    // Sense Remote: direct / relay for the live line of the Sense frame.
    ConnectionTypeState.init(params['id']);
    tabController.add(TabInfo(
        key: params['id'],
        label: params['id'],
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        onTabCloseButton: () async {
          if (await desktopTryShowTabAuditDialogCloseCancelled(
            id: params['id'],
            tabController: tabController,
          )) {
            return;
          }
          tabController.closeBy(params['id']);
        },
        page: FileManagerPage(
          key: ValueKey(params['id']),
          id: params['id'],
          password: params['password'],
          loginMethod: params['loginMethod'] ?? '',
          isSharedPassword: params['isSharedPassword'],
          tabController: tabController,
          forceRelay: params['forceRelay'],
          connToken: params['connToken'],
        )));
  }

  @override
  void initState() {
    super.initState();

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      debugPrint(
          "[FileTransfer] call ${call.method} with args ${call.arguments} from window $fromWindowId to ${windowId()}");
      // for simplify, just replace connectionId
      if (call.method == kWindowEventNewFileTransfer) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        windowOnTop(windowId());
        ConnectionTypeState.init(id); // Sense Remote: live line of the frame
        tabController.add(TabInfo(
            key: id,
            label: id,
            selectedIcon: selectedIcon,
            unselectedIcon: unselectedIcon,
            onTabCloseButton: () async {
              if (await desktopTryShowTabAuditDialogCloseCancelled(
                id: id,
                tabController: tabController,
              )) {
                return;
              }
              tabController.closeBy(id);
            },
            page: FileManagerPage(
              key: ValueKey(id),
              id: id,
              password: args['password'],
              loginMethod: args['loginMethod'] ?? '',
              isSharedPassword: args['isSharedPassword'],
              tabController: tabController,
              forceRelay: args['forceRelay'],
              connToken: args['connToken'],
            )));
      } else if (call.method == "onDestroy") {
        tabController.clear();
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      }
    });
    Future.delayed(Duration.zero, () {
      restoreWindowPosition(WindowType.FileTransfer, windowId: windowId());
    });
  }

  /// Sense Remote (#155, ST 15): live line of the Sense frame for a tab.
  SenseAuxLive _live(String id) {
    String direct = kInvalidValueStr;
    try {
      direct = ConnectionTypeState.find(id).direct.value;
    } catch (_) {}
    if (direct == kInvalidValueStr) {
      return const SenseAuxLive(SenseAuxStrings.connecting, SenseLevel.unknown);
    }
    final way = direct == ConnectionType.strDirect
        ? SenseAuxStrings.direct
        : SenseAuxStrings.relay;
    return SenseAuxLive(
        '$way · ${SenseAuxStrings.screenNotOpened}', SenseLevel.ok);
  }

  @override
  Widget build(BuildContext context) {
    // Sense Remote (#155, ST 15): the Sense frame instead of the stock blue tab bar.
    // The stock frame below stays as the fallback without a Sense role.
    final Widget child = senseAuxFrameOn()
        ? SenseAuxTabWindow(
            controller: tabController,
            title: SenseFilesStrings.title,
            onWindowClose: handleWindowCloseButton,
            liveFor: _live,
          )
        : Scaffold(
        backgroundColor: Theme.of(context).cardColor,
        body: DesktopTab(
          controller: tabController,
          onWindowCloseButton: handleWindowCloseButton,
          tail: const AddButton(),
          selectedBorderColor: MyTheme.accent,
          labelGetter: DesktopTab.tablabelGetter,
        ));
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(context, child)
        : workaroundWindowBorder(
            context,
            Container(
              decoration: BoxDecoration(
                  border: Border.all(color: MyTheme.color(context).border!)),
              child: child,
            ));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : SubWindowDragToResizeArea(
            child: tabWidget,
            resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
            enableResizeEdges: subWindowManagerEnableResizeEdges,
            windowId: stateGlobal.windowId,
          );
  }

  void onRemoveId(String id) {
    ConnectionTypeState.delete(id); // Sense Remote
    if (tabController.state.value.tabs.isEmpty) {
      WindowController.fromWindowId(windowId()).close();
    }
  }

  int windowId() {
    return widget.params["windowId"];
  }

  Future<bool> handleWindowCloseButton() async {
    final connLength = tabController.state.value.tabs.length;
    if (connLength == 1) {
      if (await desktopTryShowTabAuditDialogCloseCancelled(
        id: tabController.state.value.tabs[0].key,
        tabController: tabController,
      )) {
        return false;
      }
    }
    if (connLength <= 1) {
      tabController.clear();
      return true;
    } else {
      final bool res;
      if (!option2bool(kOptionEnableConfirmClosingTabs,
          bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs))) {
        res = true;
      } else {
        // Sense Remote (Sürüm 12, ST 14): the Sense confirm; the stock box stays the fallback.
        res = kSenseDialogs
            ? await senseCloseTabsConfirm(connLength)
            : await closeConfirmDialog();
      }
      if (res) {
        tabController.clear();
      }
      return res;
    }
  }
}
