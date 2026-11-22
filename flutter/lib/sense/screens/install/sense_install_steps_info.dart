// Sense Remote: steps 2 and 3 (role, computer info) of the Sense setup wizard (part of sense_install_wizard.dart,
// code review K3-6; behaviour unchanged).

part of 'sense_install_wizard.dart';

extension _SenseInstallInfoSteps on _SenseInstallWizardState {
  // ---- Step 2: role ----

  Widget _rolePage() {
    final any = _host || _controller;
    final summary = !any
        ? _t('no-role')
        : senseRoleLabel(_host, _controller) +
            (_host && _controller ? _t('both-desc') : '.');
    return _page([
      _heading(_t('role-title-a'), _t('role-title-b')),
      _lead(_t('role-lead')),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _roleCard(
              key: const Key('sense-role-host'),
              title: 'Host',
              description: _t('host-desc'),
              icon: Icons.desktop_windows_outlined,
              selected: _host,
              onTap: () => _update(() => _host = !_host),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _roleCard(
              key: const Key('sense-role-controller'),
              title: 'Controller',
              description: _t('controller-desc'),
              icon: Icons.mouse_outlined,
              selected: _controller,
              onTap: () => _update(() => _controller = !_controller),
            ),
          ),
        ],
      ),
      Container(
        key: const Key('sense-role-summary'),
        margin: const EdgeInsets.only(top: 14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(SenseTokens.radius),
          border: Border.all(color: const Color(0xFF2F2F38)),
        ),
        child: Text(summary,
            style: const TextStyle(fontSize: 12, color: SenseTokens.soft)),
      ),
    ], [
      _secondaryButton(_t('back'), () => _go(SenseInstallStep.account),
          key: const Key('sense-back')),
      const Spacer(),
      _primaryButton(
          _t('next'), any ? () => _go(SenseInstallStep.info) : null,
          key: const Key('sense-next')),
    ]);
  }

  Widget _roleCard({
    required Key key,
    required String title,
    required String description,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Semantics(
      key: key,
      button: true,
      selected: selected,
      label: title,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SenseTokens.radiusCard),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SenseTokens.radiusCard),
            border: Border.all(
                color: selected ? SenseTokens.white : SenseTokens.border),
            color: selected ? null : SenseTokens.field,
            gradient: selected
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      SenseTokens.accent1.withAlpha(115),
                      SenseTokens.accent2.withAlpha(64),
                    ],
                  )
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 30, color: SenseTokens.white),
                  const Spacer(),
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: selected ? SenseTokens.white : null,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                          color: selected
                              ? SenseTokens.white
                              : SenseTokens.border),
                    ),
                    child: selected
                        ? const Icon(Icons.check,
                            size: 13, color: SenseTokens.black)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(description,
                  style:
                      const TextStyle(fontSize: 12, color: SenseTokens.text3)),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Step 3: computer info ----

  InputDecoration _inputDecoration(String hint, {Widget? suffix}) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(SenseTokens.radius),
        borderSide: BorderSide(color: color));
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: SenseTokens.dim, fontSize: 13),
      isDense: true,
      filled: true,
      fillColor: SenseTokens.field,
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
      enabledBorder: border(SenseTokens.border),
      focusedBorder: border(SenseTokens.white),
      border: border(SenseTokens.border),
      suffixIcon: suffix,
    );
  }

  Widget _field(String label, Widget input, {String? extra}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(children: [
              TextSpan(text: label),
              if (extra != null)
                TextSpan(
                    text: ' $extra',
                    style: const TextStyle(color: SenseTokens.dim)),
            ]),
            style: const TextStyle(fontSize: 12, color: SenseTokens.muted),
          ),
          const SizedBox(height: 6),
          input,
        ],
      ),
    );
  }

  Widget _textInput(TextEditingController controller, String hint, int max,
      {Key? key,
      FocusNode? focusNode,
      ValueChanged<String>? onSubmitted,
      Widget? suffix}) {
    return TextField(
      key: key,
      controller: controller,
      focusNode: focusNode,
      onSubmitted: onSubmitted,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w300),
      inputFormatters: [LengthLimitingTextInputFormatter(max)],
      decoration: _inputDecoration(hint, suffix: suffix),
    );
  }

  Widget _infoPage() {
    final canContinue = _name.text.trim().isNotEmpty;
    return _page([
      _heading(_t('info-title-a'), _t('info-title-b')),
      _lead(_t('info-lead')),
      // Sense Remote: name on its own line like the prototype, so long names fit (T3-16).
      _field(
          _t('name'),
          _textInput(_name, _t('name-hint'), kSenseMaxName,
              key: const Key('sense-name'))),
      _projectsField(),
      _field(
          _t('location'),
          _textInput(_location, _t('location-hint'), kSenseMaxLocation,
              key: const Key('sense-location'))),
      _field(
          _t('note'),
          _textInput(_note, _t('note-hint'), kSenseMaxNote,
              key: const Key('sense-note'))),
    ], [
      // After installing the role is fixed: no way back to the role step.
      if (!_installed)
        _secondaryButton(_t('back'), () => _go(SenseInstallStep.role)),
      const Spacer(),
      _primaryButton(
          _t('next'),
          canContinue
              ? () {
                  // A project typed but not confirmed with Enter still counts.
                  _addNewProject();
                  _go(SenseInstallStep.summary);
                }
              : null,
          key: const Key('sense-next')),
    ]);
  }

  Widget _projectsField() {
    final available = _available ?? const <SenseProject>[];
    final chips = <Widget>[
      for (final p in available)
        _projectChip(
          key: Key('sense-project-${p.id}'),
          label: p.name,
          selected: _selectedIds.contains(p.id),
          onTap: () => _toggleProject(p),
        ),
      for (final name in _newProjects)
        _projectChip(
          key: Key('sense-new-project-$name'),
          label: name,
          selected: true,
          isNew: true,
          onRemove: () => _update(() => _newProjects.remove(name)),
        ),
    ];
    Widget? status;
    if (_projectsLoading) {
      status = _statusLine(Icons.hourglass_empty, _t('projects-loading'));
    } else if (_projectsError.isNotEmpty) {
      status = Row(
        children: [
          Expanded(
            child: _errorRow(
                kSenseInstallTr['projects-error-$_projectsError'] ??
                    _t('projects-error'),
                key: const Key('sense-projects-error')),
          ),
          _textButton(_t('retry'), _loadProjects,
              key: const Key('sense-projects-retry')),
        ],
      );
    } else if (chips.isEmpty) {
      status = _statusLine(Icons.info_outline, _t('projects-empty'));
    }
    final full = _projectCount >= kSenseMaxProjects;
    return _field(
      _t('projects'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chips.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          if (status != null) ...[
            if (chips.isNotEmpty) const SizedBox(height: 10),
            status,
          ],
          const SizedBox(height: 10),
          _textInput(_newProject, _t('project-hint'), kSenseMaxProject,
              key: const Key('sense-project'),
              focusNode: _newProjectFocus,
              onSubmitted: (_) => _addNewProject(),
              suffix: IconButton(
                key: const Key('sense-project-add'),
                tooltip: _t('add-project'),
                icon: const Icon(Icons.add, size: 18),
                color: SenseTokens.muted,
                onPressed: _addNewProject,
              )),
          if (full)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_t('projects-max'),
                  style:
                      const TextStyle(fontSize: 11, color: SenseTokens.dim)),
            ),
        ],
      ),
      extra: _t('projects-multi'),
    );
  }

  Widget _projectChip({
    required Key key,
    required String label,
    required bool selected,
    bool isNew = false,
    VoidCallback? onTap,
    VoidCallback? onRemove,
  }) {
    return Semantics(
      key: key,
      button: onTap != null,
      selected: selected,
      label: isNew ? '$label (${_t('new-tag')})' : label,
      excludeSemantics: onRemove == null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.fromLTRB(12, 6, onRemove != null ? 4 : 12, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? SenseTokens.white : SenseTokens.border),
            color: selected ? null : SenseTokens.field,
            gradient: selected
                ? LinearGradient(colors: [
                    SenseTokens.accent1.withAlpha(115),
                    SenseTokens.accent2.withAlpha(64),
                  ])
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected && !isNew) ...[
                const Icon(Icons.check, size: 13, color: SenseTokens.white),
                const SizedBox(width: 5),
              ],
              Text(label, style: const TextStyle(fontSize: 12)),
              if (isNew) ...[
                const SizedBox(width: 6),
                Text(_t('new-tag'),
                    style: const TextStyle(
                        fontSize: 10, color: SenseTokens.soft)),
              ],
              if (onRemove != null) ...[
                const SizedBox(width: 2),
                Tooltip(
                  message: _t('remove-project'),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onRemove,
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.close,
                          size: 13, color: SenseTokens.muted),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
