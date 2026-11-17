// Sense Remote: Host home (prototype Calisma/prototip/uygulama.html, screen 3,
// left half only). Host computers sit at the customer's site, so the window
// stays small: name, location, readiness and the lock note. No settings, no
// password on screen (decision: no large interface on the Host). The "last
// connections" list and the full status card come after the first test
// (wave 3 plan §1.2).

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../models/state_model.dart';
import 'sense_cm_style.dart';
import 'sense_cm_widgets.dart';
import 'sense_home_strings.dart';

typedef _T = SenseCmTokens;

/// Name and location entered at installation (installer writes them as the
/// built-in options `sense-name` / `sense-location`; empty when missing).
const kSenseNameOption = 'sense-name';
const kSenseLocationOption = 'sense-location';

enum SenseHostState { ready, connecting, notReady, serviceStopped }

/// Pure: readiness line of the Host home.
SenseHostState senseHostStateFrom(
    {required SvcStatus status, required bool serviceStopped}) {
  if (serviceStopped) return SenseHostState.serviceStopped;
  switch (status) {
    case SvcStatus.ready:
      return SenseHostState.ready;
    case SvcStatus.connecting:
      return SenseHostState.connecting;
    case SvcStatus.notReady:
      return SenseHostState.notReady;
  }
}

String senseHostStateText(SenseHostState state) {
  switch (state) {
    case SenseHostState.ready:
      return senseHomeText('ready');
    case SenseHostState.connecting:
      return senseHomeText('connecting');
    case SenseHostState.notReady:
      return senseHomeText('not_ready');
    case SenseHostState.serviceStopped:
      return senseHomeText('service_stopped');
  }
}

/// Binds the Host home to the app state. The status itself is refreshed by
/// the home page (it keeps the stock status widget mounted but hidden).
class SenseHostHome extends StatelessWidget {
  const SenseHostHome({super.key});

  @override
  Widget build(BuildContext context) {
    final stopped = Get.find<RxBool>(tag: 'stop-service');
    final name = bind.mainGetBuildinOption(key: kSenseNameOption);
    final location = bind.mainGetBuildinOption(key: kSenseLocationOption);
    return Obx(() => SenseHostHomeView(
          name: name,
          location: location,
          deviceId: gFFI.serverModel.serverId.text,
          state: senseHostStateFrom(
              status: stateGlobal.svcStatus.value,
              serviceStopped: stopped.value),
          onStartService: () => start_service(true),
        ));
  }
}

/// Pure view (data + callbacks), covered by widget tests. Fits the 280 px
/// wide Host window; the window height follows the content.
class SenseHostHomeView extends StatelessWidget {
  const SenseHostHomeView({
    super.key,
    required this.name,
    required this.location,
    required this.deviceId,
    required this.state,
    this.onStartService,
  });

  final String name;
  final String location;
  final String deviceId;
  final SenseHostState state;
  final VoidCallback? onStartService;

  @override
  Widget build(BuildContext context) {
    final title = name.trim().isNotEmpty
        ? name.trim()
        : senseHomeText('this_computer');
    final ready = state == SenseHostState.ready;
    return Container(
      color: _T.black,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const SenseCmMark(size: 22),
            const SizedBox(width: 10),
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: senseHomeText('brand_bold'),
                  style: _T.text(size: 15, weight: FontWeight.w700)),
              TextSpan(
                  text: senseHomeText('brand_light'),
                  style: _T.text(size: 15, weight: FontWeight.w200)),
            ])),
          ]),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _T.field,
              borderRadius: BorderRadius.circular(_T.radiusCard),
              border: Border.all(color: const Color(0xFF26262F)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${senseHomeUpper(senseHomeText('this_computer'))} · Host',
                    style: _T.text(size: 9, color: _T.muted)
                        .copyWith(letterSpacing: 1.6)),
                const SizedBox(height: 6),
                Text(title,
                    key: const Key('sense-host-name'),
                    style: _T.text(size: 20, weight: FontWeight.w600)),
                if (location.trim().isNotEmpty)
                  Text(location.trim(),
                      key: const Key('sense-host-location'),
                      style: _T.text(size: 12, color: _T.muted)),
                if (deviceId.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SelectableText(
                        '${senseHomeText('device_id')} ${deviceId.trim()}',
                        style: _T.text(size: 11, color: _T.muted)),
                  ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: ready ? _T.live : _T.idle,
                          boxShadow: ready
                              ? const [
                                  BoxShadow(color: _T.live, blurRadius: 10)
                                ]
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(senseHostStateText(state),
                          key: const Key('sense-host-state'),
                          style: _T.text(size: 12)),
                    ),
                  ],
                ),
                if (state == SenseHostState.serviceStopped &&
                    onStartService != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 8),
                    child: SenseCmTextButton(
                        key: const Key('sense-host-start-service'),
                        label: senseHomeText('start_service'),
                        strong: true,
                        onTap: onStartService!),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_outline, size: 14, color: _T.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(senseHomeText('locked_note'),
                    style: _T.text(size: 11, color: _T.soft)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
