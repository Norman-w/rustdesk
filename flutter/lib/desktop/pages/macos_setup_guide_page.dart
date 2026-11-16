import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class MacosSetupGuidePage extends StatefulWidget {
  const MacosSetupGuidePage({Key? key}) : super(key: key);

  @override
  State<MacosSetupGuidePage> createState() => _MacosSetupGuidePageState();
}

class _MacosSetupGuidePageState extends State<MacosSetupGuidePage>
    with WidgetsBindingObserver {
  Map<String, dynamic> _tcc = const {};
  bool _virtualMicReady = false;
  bool _componentsReady = false;
  bool _busy = false;
  String _lastAction = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  void _refresh() {
    if (!isMacOS || !mounted) return;
    try {
      final raw = bind.mainGetTccStatusJson();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _tcc = decoded;
      }
      _virtualMicReady = bind.mainIsNormanVirtualMicInstalled();
      _componentsReady = bind.mainIsNormanCmHelperInstalled();
    } catch (e) {
      _lastAction = e.toString();
    }
    if (mounted) setState(() {});
  }

  bool _tccValue(String key) => _tcc[key] == true;

  bool get _tccReady => _tccValue('ready');

  String _nextPermissionTitle() {
    if (!_tccValue('screenRecording')) {
      return translate('macos_setup_guide_screen');
    }
    if (!_tccValue('accessibility')) {
      return translate('macos_setup_guide_accessibility');
    }
    if (!_tccValue('inputMonitoring')) {
      return translate('macos_setup_guide_input');
    }
    return '';
  }

  Widget _permissionFlowStep({
    required String number,
    required String title,
    required bool ready,
    required bool current,
  }) {
    final colors = Theme.of(context).colorScheme;
    final color = ready
        ? colors.primary
        : current
            ? colors.tertiary
            : colors.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: color,
            child: ready
                ? Icon(Icons.check, size: 16, color: colors.onPrimary)
                : Text(number,
                    style: TextStyle(color: colors.onTertiaryContainer)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                const SizedBox(height: 2),
                Text(
                  ready
                      ? translate('macos_setup_guide_ready')
                      : current
                          ? translate('macos_setup_guide_flow_next')
                          : translate('macos_setup_guide_missing'),
                  style: TextStyle(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<bool> _showPermissionFlow() async {
    final next = _nextPermissionTitle();
    if (next.isEmpty) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(translate('macos_setup_guide_flow_title')),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(translate('macos_setup_guide_flow_intro')),
                const SizedBox(height: 14),
                _permissionFlowStep(
                  number: '1',
                  title: translate('macos_setup_guide_screen'),
                  ready: _tccValue('screenRecording'),
                  current: next == translate('macos_setup_guide_screen'),
                ),
                _permissionFlowStep(
                  number: '2',
                  title: translate('macos_setup_guide_accessibility'),
                  ready: _tccValue('accessibility'),
                  current: next ==
                      translate('macos_setup_guide_accessibility'),
                ),
                _permissionFlowStep(
                  number: '3',
                  title: translate('macos_setup_guide_input'),
                  ready: _tccValue('inputMonitoring'),
                  current:
                      next == translate('macos_setup_guide_input'),
                ),
                const SizedBox(height: 8),
                Text(
                  '${translate('macos_setup_guide_flow_next')}: $next',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(translate('macos_setup_guide_flow_cancel')),
            ),
            ElevatedButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.open_in_new),
              label: Text(translate('macos_setup_guide_flow_continue')),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<void> _repairTcc() async {
    if (_busy) return;
    _refresh();
    if (_tccReady) {
      setState(() {
        _lastAction = translate('macos_setup_guide_ready');
      });
      return;
    }
    if (!await _showPermissionFlow() || !mounted) return;
    setState(() {
      _busy = true;
      _lastAction = translate('macos_setup_guide_repairing');
    });
    try {
      final raw = bind.mainRepairTccJson();
      final result = jsonDecode(raw);
      final requested = result is Map<String, dynamic>
          ? result['requested']?.toString() ?? 'none'
          : 'unknown';
      _lastAction = requested == 'none'
          ? translate('macos_setup_guide_ready')
          : '${translate('macos_setup_guide_requested')}: $requested';
    } catch (e) {
      _lastAction = e.toString();
    }
    if (mounted) _busy = false;
    _refresh();
  }

  void _installComponents() {
    if (_busy) return;
    final opened = bind.mainOpenNormanCmHelperInstaller();
    setState(() {
      _lastAction = opened
          ? translate('macos_setup_guide_installer_opened')
          : translate('macos_setup_guide_installer_missing');
    });
  }

  Widget _statusRow({
    required IconData icon,
    required String title,
    required String detail,
    required bool ready,
  }) {
    final color = ready
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: Icon(icon, color: color),
      title: Text(title),
      subtitle: Text(detail),
      trailing: Icon(
        ready ? Icons.check_circle : Icons.error_outline,
        color: color,
      ),
    );
  }

  Widget _section({required String title, required List<Widget> children}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!isMacOS) return const SizedBox.shrink();

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      children: [
        Text(
          translate('macos_setup_guide_title'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(translate('macos_setup_guide_summary')),
        const SizedBox(height: 18),
        _section(
          title: translate('macos_setup_guide_permissions'),
          children: [
            _statusRow(
              icon: Icons.screen_lock_portrait_outlined,
              title: translate('macos_setup_guide_screen'),
              detail: _tccValue('screenRecording')
                  ? translate('macos_setup_guide_ready')
                  : translate('macos_setup_guide_missing'),
              ready: _tccValue('screenRecording'),
            ),
            _statusRow(
              icon: Icons.accessibility_new_outlined,
              title: translate('macos_setup_guide_accessibility'),
              detail: _tccValue('accessibility')
                  ? translate('macos_setup_guide_ready')
                  : translate('macos_setup_guide_missing'),
              ready: _tccValue('accessibility'),
            ),
            _statusRow(
              icon: Icons.keyboard_alt_outlined,
              title: translate('macos_setup_guide_input'),
              detail: _tccValue('inputMonitoring')
                  ? translate('macos_setup_guide_ready')
                  : translate('macos_setup_guide_missing'),
              ready: _tccValue('inputMonitoring'),
            ),
            const SizedBox(height: 8),
            Text(translate('macos_setup_guide_permission_note')),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _busy ? null : _repairTcc,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: Text(translate('macos_setup_guide_repair')),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(translate('macos_setup_guide_refresh')),
                ),
              ],
            ),
          ],
        ),
        _section(
          title: translate('macos_setup_guide_hal'),
          children: [
            _statusRow(
              icon: Icons.mic_external_on_outlined,
              title: translate('macos_setup_guide_virtual_mic'),
              detail: _virtualMicReady
                  ? translate('macos_setup_guide_ready')
                  : translate('macos_setup_guide_missing'),
              ready: _virtualMicReady,
            ),
            Text(translate('macos_setup_guide_hal_tip')),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _virtualMicReady ? null : _installComponents,
                  icon: const Icon(Icons.install_desktop_outlined),
                  label: Text(translate('macos_setup_guide_install_hal')),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(translate('macos_setup_guide_refresh')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _componentsReady
                  ? translate('macos_setup_guide_components_ready')
                  : translate('macos_setup_guide_components_missing'),
              style: TextStyle(
                color: _componentsReady
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ),
        _section(
          title: translate('macos_setup_guide_finish'),
          children: [
            Text(translate('macos_setup_guide_finish_tip')),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _tccReady && _componentsReady
                      ? () => bind.mainRelaunchApp()
                      : null,
                  icon: const Icon(Icons.restart_alt),
                  label: Text(translate('macos_setup_guide_restart')),
                ),
                if (_lastAction.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  Expanded(child: Text(_lastAction)),
                ],
              ],
            ),
          ],
        ),
        Text(
          translate('macos_setup_guide_public_api'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
