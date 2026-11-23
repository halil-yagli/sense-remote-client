// Sense Remote: Ayarlar › Güvenlik "Kalıcı şifre" row (T7). It opens IN PLACE under the row
// (the same body as the Host category: Kilidi aç → QR + pairing code → new password), never
// in a window; closing it while verifying or unlocked gives the grant back (the controller's
// dispose).
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../../../../common.dart';
import '../../../sense.dart';
import '../../../strings/host.dart';
import '../data/password.dart';
import '../sense_password_model.dart';
import 'password_category.dart';

class SensePasswordAboutRow extends StatefulWidget {
  const SensePasswordAboutRow({
    super.key,
    this.backend = const SensePasswordBridge(),
    this.deviceId,
    this.interval = const Duration(seconds: 1),
    this.initiallyOpen = false,
  });

  final SensePasswordBackend backend;

  /// For the "Kimliği içermiyor" rule; null = this computer's own ID.
  final String? deviceId;
  final Duration interval;
  final bool initiallyOpen;

  @override
  State<SensePasswordAboutRow> createState() => _SensePasswordAboutRowState();
}

class _SensePasswordAboutRowState extends State<SensePasswordAboutRow> {
  SensePasswordStatus _status = SensePasswordStatus.none;
  SensePasswordController? _c;

  @override
  void initState() {
    super.initState();
    _loadStatus();
    if (widget.initiallyOpen) _openBody();
  }

  Future<void> _loadStatus() async {
    final s = SensePasswordStatus.parse(await widget.backend.status());
    if (mounted) setState(() => _status = s);
  }

  void _openBody() {
    final c = SensePasswordController(widget.backend, interval: widget.interval);
    _c = c;
    c.load();
  }

  void _toggle() {
    final c = _c;
    if (c == null) {
      setState(_openBody);
    } else {
      setState(() => _c = null);
      c.dispose();
      _loadStatus();
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  String get _id => widget.deviceId ?? gFFI.serverModel.serverId.text;

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      SenseSettingRow(
        key: const Key('sense-pw-about-row'),
        label: SenseHostStrings.password,
        description: senseHostPasswordSummary(_status),
        last: c == null,
        control: SenseButton(
          key: const Key('sense-pw-open'),
          label: c == null ? SenseHostStrings.openRow : SenseHostStrings.closeRow,
          size: SenseButtonSize.small,
          onPressed: _toggle,
        ),
      ),
      if (c != null)
        Padding(
          key: const Key('sense-pw-inline'),
          padding: const EdgeInsets.only(bottom: SenseUi.rowPadV),
          child: SensePasswordCategoryBody(controller: c, deviceId: _id),
        ),
    ]);
  }
}
