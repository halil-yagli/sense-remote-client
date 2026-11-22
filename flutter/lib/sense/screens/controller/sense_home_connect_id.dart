// Sense Remote: "Kimlikle bağlan" window of the Controller home. Connecting
// by ID existed only as a shortcut that showed up after typing an ID into the
// search box; the first user test (2026-11-21) could not find it. This small
// window is opened by an always visible header button.
//
// Only the ID is asked here. The password is asked by the connection window;
// it is never asked, kept or logged on this screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../host_live/sense_cm_style.dart';
import '../host_live/sense_cm_widgets.dart';
import 'sense_home_controller.dart' show senseIdFromQuery;
import 'sense_home_strings.dart';

typedef _T = SenseCmTokens;

Future<void> showSenseConnectByIdDialog(
        BuildContext context, void Function(String id) onConnect) =>
    showDialog<void>(
      context: context,
      builder: (_) => SenseConnectByIdDialog(onConnect: onConnect),
    );

class SenseConnectByIdDialog extends StatefulWidget {
  const SenseConnectByIdDialog({super.key, required this.onConnect});

  /// Gets the ID without spaces, after the window has closed.
  final void Function(String id) onConnect;

  @override
  State<SenseConnectByIdDialog> createState() => _SenseConnectByIdDialogState();
}

class _SenseConnectByIdDialogState extends State<SenseConnectByIdDialog> {
  final _id = TextEditingController();

  @override
  void initState() {
    super.initState();
    _id.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  void _submit() {
    final id = senseIdFromQuery(_id.text);
    if (id == null) return;
    Navigator.of(context).pop();
    widget.onConnect(id);
  }

  @override
  Widget build(BuildContext context) {
    final valid = senseIdFromQuery(_id.text) != null;
    // Esc closes the window also while the ID field has the focus.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Dialog(
        key: const Key('sense-connect-id-dialog'),
        backgroundColor: _T.black,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_T.radiusCard),
            side: const BorderSide(color: _T.border)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(senseHomeText('connect_id'),
                    style: _T.text(size: 14, weight: FontWeight.w600)),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('sense-connect-id-field'),
                  controller: _id,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  // Digits and spaces only ("123 456 789" is how IDs are read
                  // out); the length is checked by senseIdFromQuery.
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                    LengthLimitingTextInputFormatter(20),
                  ],
                  // Enter connects; with an invalid ID the focus stays.
                  onEditingComplete: _submit,
                  cursorColor: _T.white,
                  style: _T.text(size: 14, weight: FontWeight.w400),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: senseHomeText('connect_id_hint'),
                    hintStyle: _T.text(size: 12, color: _T.muted),
                    filled: true,
                    fillColor: _T.field,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(_T.radius),
                        borderSide: const BorderSide(color: _T.border)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(_T.radius),
                        borderSide: const BorderSide(color: _T.white)),
                  ),
                ),
                const SizedBox(height: 10),
                Text(senseHomeText('connect_id_note'),
                    style: _T.text(size: 11, color: _T.muted)),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: SenseCmButton(
                          key: const Key('sense-connect-id-cancel'),
                          label: senseHomeText('cancel'),
                          onTap: () => Navigator.of(context).pop()),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      // Inactive until the ID is valid (_submit checks again).
                      child: Semantics(
                        button: true,
                        enabled: valid,
                        child: IgnorePointer(
                          ignoring: !valid,
                          child: ExcludeFocus(
                            excluding: !valid,
                            child: Opacity(
                              opacity: valid ? 1 : 0.35,
                              child: SenseCmButton(
                                  key: const Key('sense-connect-id-go'),
                                  label: senseHomeText('connect'),
                                  primary: true,
                                  onTap: _submit),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
