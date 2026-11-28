import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/desktop/pages/port_forward_page.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:get/get.dart';

import '../../common/shared_state.dart';
import '../../sense/screens/shared/aux_window/aux_label.dart';
import '../../sense/screens/shared/aux_window/aux_tab_window.dart';
import '../../sense/screens/shared/aux_window/aux_window_frame.dart';
import '../../sense/sense.dart' show SenseLevel;
import '../../sense/strings/files.dart';
import '../../sense/strings/tunnel.dart';

class PortForwardTabPage extends StatefulWidget {
  final Map<String, dynamic> params;

  const PortForwardTabPage({Key? key, required this.params}) : super(key: key);

  @override
  State<PortForwardTabPage> createState() => _PortForwardTabPageState(params);
}

class _PortForwardTabPageState extends State<PortForwardTabPage> {
  late final DesktopTabController tabController;
  late final bool isRDP;

  static const IconData selectedIcon = Icons.forward_sharp;
  static const IconData unselectedIcon = Icons.forward_outlined;

  /// Sense Remote (Sürüm 12, ST 7, 15): the Sense frame (not for RDP).
  late final bool _senseOn = senseAuxFrameOn() && !isRDP;

  _PortForwardTabPageState(Map<String, dynamic> params) {
    isRDP = params['isRDP'];
    tabController =
        Get.put(DesktopTabController(tabType: DesktopTabType.portForward));
    tabController.onSelected = (id) {
      // Sense Remote (ST 16): Turkish title with the computer's name, no ID.
      WindowController.fromWindowId(windowId()).setTitle(_senseOn
          ? senseAuxWindowTitle(SenseTunnelStrings.title, id)
          : getWindowNameWithId(id));
    };
    tabController.onRemoved = (_, id) => onRemoveId(id);
    ConnectionTypeState.init(params['id']); // Sense Remote: live line
    tabController.add(TabInfo(
        key: params['id'],
        label: params['id'],
        selectedIcon: selectedIcon,
        unselectedIcon: unselectedIcon,
        page: PortForwardPage(
          key: ValueKey(params['id']),
          id: params['id'],
          password: params['password'],
          loginMethod: params['loginMethod'] ?? '',
          isSharedPassword: params['isSharedPassword'],
          tabController: tabController,
          isRDP: isRDP,
          forceRelay: params['forceRelay'],
          connToken: params['connToken'],
        )));
  }

  @override
  void initState() {
    super.initState();

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      debugPrint(
          "[Port Forward] call ${call.method} with args ${call.arguments} from window $fromWindowId");
      // for simplify, just replace connectionId
      if (call.method == kWindowEventNewPortForward) {
        final args = jsonDecode(call.arguments);
        final id = args['id'];
        final isRDP = args['isRDP'];
        windowOnTop(windowId());
        ConnectionTypeState.init(id); // Sense Remote: live line
        if (tabController.state.value.tabs.indexWhere((e) => e.key == id) >=
            0) {
          debugPrint("port forward $id exists");
          return;
        }
        tabController.add(TabInfo(
            key: id,
            label: id,
            selectedIcon: selectedIcon,
            unselectedIcon: unselectedIcon,
            page: PortForwardPage(
              key: ValueKey(args['id']),
              id: id,
              password: args['password'],
              loginMethod: args['loginMethod'] ?? '',
              isSharedPassword: args['isSharedPassword'],
              isRDP: isRDP,
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
      restoreWindowPosition(WindowType.PortForward, windowId: windowId());
    });
  }

  /// Sense Remote (Sürüm 12, ST 7): live line of the Sense frame. RustDesk connects on the
  /// first tunnel use; until then "Hazır".
  SenseAuxLive _senseLive(String id) {
    String direct = kInvalidValueStr;
    try {
      direct = ConnectionTypeState.find(id).direct.value;
    } catch (_) {}
    if (direct == kInvalidValueStr) {
      return const SenseAuxLive(
          '${SenseTunnelStrings.ready} · ${SenseAuxStrings.screenNotOpened}',
          SenseLevel.unknown);
    }
    final way = direct == ConnectionType.strDirect
        ? SenseAuxStrings.direct
        : SenseAuxStrings.relay;
    return SenseAuxLive(
        '$way · ${SenseAuxStrings.screenNotOpened}', SenseLevel.ok);
  }

  @override
  Widget build(BuildContext context) {
    // Sense Remote (Sürüm 12, ST 7, 15): the Sense frame instead of the stock blue tab bar;
    // the stock one below stays the fallback (no Sense role, RDP).
    final child = _senseOn
        ? SenseAuxTabWindow(
            controller: tabController,
            title: SenseTunnelStrings.title,
            onWindowClose: () async {
              tabController.clear();
              return true;
            },
            liveFor: _senseLive,
          )
        : Scaffold(
      backgroundColor: Theme.of(context).colorScheme.background,
      body: DesktopTab(
        controller: tabController,
        onWindowCloseButton: () async {
          tabController.clear();
          return true;
        },
        tail: AddButton(),
        selectedBorderColor: MyTheme.accent,
        labelGetter: DesktopTab.tablabelGetter,
      ),
    );
    final tabWidget = isLinux
        ? buildVirtualWindowFrame(
            context,
            Scaffold(
                backgroundColor: Theme.of(context).colorScheme.background,
                body: child),
          )
        : workaroundWindowBorder(
            context,
            Container(
              decoration: BoxDecoration(
                  border: Border.all(color: MyTheme.color(context).border!)),
              child: child,
            ));
    return isMacOS || kUseCompatibleUiMode
        ? tabWidget
        : Obx(
            () => SubWindowDragToResizeArea(
              child: tabWidget,
              resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
              enableResizeEdges: subWindowManagerEnableResizeEdges,
              windowId: stateGlobal.windowId,
            ),
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
}
