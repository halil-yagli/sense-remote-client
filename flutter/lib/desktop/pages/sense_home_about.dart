// Sense Remote: About (prototype Calisma/prototip/uygulama.html, screen 7).
// Sense Remote, version number, role, panel status and a small "Açık kaynak
// lisansları" link (decision 2026-11-16: the app should read as ours; the
// AGPL notice stays behind that link: license text + public source code).

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../common.dart' show gFFI;
import '../../models/platform_model.dart';
import 'sense_cm_style.dart';
import 'sense_cm_widgets.dart';
import 'sense_home_strings.dart';

typedef _T = SenseCmTokens;

/// Built-in option the build may carry with the Sense version number.
const kSenseVersionOption = 'sense-version';

/// Pure: panel line of the About page.
String senseAboutPanelText(
    {required SenseHomeRole role, required String account}) {
  if (account.trim().isNotEmpty) {
    return senseHomeText('panel_signed_in', {'name': account.trim()});
  }
  // A Host keeps no panel sign-in (wave 3 plan K-KAYIT-b); the panel reaches
  // it through the service.
  if (role == SenseHomeRole.host || role == SenseHomeRole.both) {
    return senseHomeText('panel_managed');
  }
  return senseHomeText('panel_signed_out');
}

/// Binds the About page to the app.
class SenseAboutPage extends StatelessWidget {
  const SenseAboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final role = senseHomeRoleFrom(
        incomingOnly: bind.isIncomingOnly(),
        outgoingOnly: bind.isOutgoingOnly(),
        settingsDisabled: bind.isDisableSettings());
    final builtin = bind.mainGetBuildinOption(key: kSenseVersionOption);
    final version =
        senseVersionFrom(builtin) ?? senseVersionFrom(kSenseVersionDefine);
    return FutureBuilder<String>(
      future: bind.mainGetVersion(),
      builder: (context, snap) => Obx(() => SenseAboutView(
            version: version,
            role: role,
            account: gFFI.userModel.displayNameOrUserName,
            baseVersion: snap.data ?? '',
            onOpenUrl: (url) => launchUrlString(url),
          )),
    );
  }
}

/// Pure view (data + callbacks), covered by widget tests.
class SenseAboutView extends StatelessWidget {
  const SenseAboutView({
    super.key,
    required this.version,
    required this.role,
    required this.account,
    required this.onOpenUrl,
    this.baseVersion = '',
    this.year,
  });

  final int? version;
  final SenseHomeRole role;
  final String account;
  final String baseVersion;
  final void Function(String url) onOpenUrl;
  final int? year;

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<String, String>>[
      MapEntry(senseHomeText('role'), senseRoleLabel(role)),
      MapEntry(senseHomeText('panel'),
          senseAboutPanelText(role: role, account: account)),
    ];
    return Container(
      color: _T.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _T.black,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF2A2A33)),
                  boxShadow: const [
                    BoxShadow(color: Color(0x73640164), blurRadius: 60)
                  ],
                ),
                child: const SenseCmMark(size: 44),
              ),
              const SizedBox(height: 22),
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: senseHomeText('brand_bold'),
                      style: _T.text(size: 26, weight: FontWeight.w700)),
                  TextSpan(
                      text: senseHomeText('brand_light'),
                      style: _T.text(size: 26, weight: FontWeight.w200)),
                ]),
              ),
              if (version != null)
                Text(senseHomeText('version', {'n': '$version'}),
                    key: const Key('sense-about-version'),
                    style: _T.text(size: 13, color: _T.muted)),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_T.radiusCard),
                  border: Border.all(color: _T.line),
                ),
                child: Column(
                  children: [
                    for (final r in rows)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                                width: 130,
                                child: Text(r.key,
                                    style: _T.text(size: 12, color: _T.muted))),
                            Expanded(
                                child: Text(r.value,
                                    style: _T.text(size: 12))),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                      '${senseHomeText('copyright', {
                            'year': '${year ?? DateTime.now().year}'
                          })} · ',
                      style: _T.text(size: 10, color: _T.idle)),
                  InkWell(
                    key: const Key('sense-about-licenses'),
                    onTap: () => showDialog(
                        context: context,
                        builder: (_) => SenseLicensesDialog(
                            baseVersion: baseVersion, onOpenUrl: onOpenUrl)),
                    child: Text(senseHomeText('licenses'),
                        style: _T
                            .text(size: 10, color: const Color(0xFF77777F))
                            .copyWith(decoration: TextDecoration.underline)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Behind the small link: license (AGPL-3.0) and the public source code.
class SenseLicensesDialog extends StatelessWidget {
  const SenseLicensesDialog(
      {super.key, required this.onOpenUrl, this.baseVersion = ''});
  final void Function(String url) onOpenUrl;
  final String baseVersion;

  Widget _link(String label, String url, Key key) => InkWell(
        key: key,
        onTap: () => onOpenUrl(url),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('$label: $url',
              style: _T
                  .text(size: 11, color: _T.soft)
                  .copyWith(decoration: TextDecoration.underline)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _T.black,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_T.radiusCard),
          side: const BorderSide(color: _T.border)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(senseHomeText('licenses_title'),
                  style: _T.text(size: 14, weight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(senseHomeText('licenses_body'),
                  style: _T.text(size: 12, color: _T.soft)),
              const SizedBox(height: 10),
              _link(senseHomeText('licenses_source'), kSenseSourceUrl,
                  const Key('sense-licenses-source')),
              _link(senseHomeText('licenses_text'), kSenseLicenseUrl,
                  const Key('sense-licenses-text')),
              if (baseVersion.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                      senseHomeText('licenses_base', {'v': baseVersion.trim()}),
                      style: _T.text(size: 10, color: _T.muted)),
                ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: SenseCmTextButton(
                    key: const Key('sense-licenses-close'),
                    label: senseHomeText('close'),
                    strong: true,
                    onTap: () => Navigator.of(context).pop()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
