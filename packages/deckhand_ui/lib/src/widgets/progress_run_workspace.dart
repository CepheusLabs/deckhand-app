import 'package:flutter/material.dart';
import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import 'deckhand_loading.dart';
import 'deckhand_panel.dart';
import 'network_panel.dart';
import 'wizard_log_view.dart';

class RunStep {
  const RunStep({required this.id, required this.kind});
  final String id;
  final String kind;
}

enum RunStepStatus { queued, active, done, warning, failed }

enum RunBannerSeverity { success, warning, error }

class RunBanner extends StatelessWidget {
  const RunBanner({
    super.key,
    required this.title,
    required this.message,
    required this.severity,
  });

  final String title;
  final String message;
  final RunBannerSeverity severity;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final color = switch (severity) {
      RunBannerSeverity.success => tokens.ok,
      RunBannerSeverity.warning => tokens.warn,
      RunBannerSeverity.error => tokens.bad,
    };
    final bg = color.withValues(alpha: 0.08);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            switch (severity) {
              RunBannerSeverity.success => Icons.check_circle_outline,
              RunBannerSeverity.warning => Icons.warning_amber_outlined,
              RunBannerSeverity.error => Icons.error_outline,
            },
            color: color,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    fontWeight: FontWeight.w700,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  message,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text2,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ProgressRunWorkspace extends StatelessWidget {
  const ProgressRunWorkspace({
    super.key,
    required this.steps,
    required this.statusFor,
    required this.log,
    required this.networkEvents,
  });

  final List<RunStep> steps;
  final RunStepStatus Function(RunStep step) statusFor;
  final List<String> log;
  final List<EgressEvent> networkEvents;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stepRail = _StepRail(steps: steps, statusFor: statusFor);
        final logPane = _LogNetworkPane(log: log, networkEvents: networkEvents);
        if (constraints.maxWidth < 840) {
          return Column(
            children: [
              SizedBox(height: 170, child: stepRail),
              const SizedBox(height: 12),
              Expanded(child: logPane),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 320, child: stepRail),
            const SizedBox(width: 16),
            Expanded(child: logPane),
          ],
        );
      },
    );
  }
}

class _StepRail extends StatefulWidget {
  const _StepRail({required this.steps, required this.statusFor});

  final List<RunStep> steps;
  final RunStepStatus Function(RunStep step) statusFor;

  @override
  State<_StepRail> createState() => _StepRailState();
}

class _StepRailState extends State<_StepRail> {
  final _controller = ScrollController();
  final _rowKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showActiveStep());
  }

  @override
  void didUpdateWidget(covariant _StepRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showActiveStep());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showActiveStep() {
    if (!_controller.hasClients) return;
    final activeIndex = widget.steps.indexWhere(
      (step) => widget.statusFor(step) == RunStepStatus.active,
    );
    if (activeIndex < 0) return;
    final activeStep = widget.steps[activeIndex];
    final activeContext = _rowKeys[activeStep.id]?.currentContext;
    if (activeContext != null) {
      Scrollable.ensureVisible(
        activeContext,
        alignment: 0.5,
        duration: Duration.zero,
      );
      return;
    }
    const rowExtent = 58.0;
    final target = (activeIndex * rowExtent).clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    if ((target - _controller.offset).abs() < 1) return;
    _controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final stepIds = widget.steps.map((step) => step.id).toSet();
    _rowKeys.removeWhere((id, _) => !stepIds.contains(id));
    final done = widget.steps
        .where((s) => widget.statusFor(s) == RunStepStatus.done)
        .length;
    final active = widget.steps
        .where((s) => widget.statusFor(s) == RunStepStatus.active)
        .length;
    final failed = widget.steps
        .where((s) => widget.statusFor(s) == RunStepStatus.failed)
        .length;
    final summary = failed > 0
        ? '$done done · $failed failed'
        : '$done done · $active active · ${widget.steps.length - done - active} queued';
    return DeckhandPanel.flush(
      head: DeckhandPanelHead(
        label: 'Steps',
        trailing: Text(summary, style: _panelMetaStyle(context)),
      ),
      child: widget.steps.isEmpty
          ? const _StepRailEmpty()
          : ListView.separated(
              controller: _controller,
              padding: EdgeInsets.zero,
              itemCount: widget.steps.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final step = widget.steps[i];
                return KeyedSubtree(
                  key: _rowKeys.putIfAbsent(step.id, GlobalKey.new),
                  child: _StepRow(
                    step: step,
                    index: i + 1,
                    status: widget.statusFor(step),
                  ),
                );
              },
            ),
    );
  }
}

class _StepRailEmpty extends StatelessWidget {
  const _StepRailEmpty();

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Center(
      child: Text(
        'No queued steps',
        style: TextStyle(
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tSm,
          color: tokens.text3,
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.index,
    required this.status,
  });

  final RunStep step;
  final int index;
  final RunStepStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final color = _statusColor(tokens);
    return Container(
      color: status == RunStepStatus.active
          ? tokens.accent.withValues(alpha: 0.07)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: _StepStatusIcon(status: status, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  runStepTitle(step.id),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    fontWeight: status == RunStepStatus.active
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${index.toString().padLeft(2, '0')} · ${_kindTitle(step.kind)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(DeckhandTokens tokens) => switch (status) {
    RunStepStatus.done => tokens.ok,
    RunStepStatus.warning => tokens.warn,
    RunStepStatus.failed => tokens.bad,
    RunStepStatus.active => tokens.accent,
    RunStepStatus.queued => tokens.text4,
  };
}

class _StepStatusIcon extends StatelessWidget {
  const _StepStatusIcon({required this.status, required this.color});

  final RunStepStatus status;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (status == RunStepStatus.active) {
      return DeckhandSpinner(size: 16, strokeWidth: 2, color: color);
    }
    final icon = switch (status) {
      RunStepStatus.done => Icons.check,
      RunStepStatus.warning => Icons.priority_high,
      RunStepStatus.failed => Icons.close,
      RunStepStatus.active => Icons.more_horiz,
      RunStepStatus.queued => Icons.circle_outlined,
    };
    return Icon(icon, size: 16, color: color);
  }
}

class _LogNetworkPane extends ConsumerWidget {
  const _LogNetworkPane({required this.log, required this.networkEvents});

  final List<String> log;
  final List<EgressEvent> networkEvents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DeckhandTokens.of(context);
    final developerMode = ref.watch(deckhandSettingsProvider).developerMode;
    final logMode = developerMode
        ? WizardLogMode.developer
        : WizardLogMode.user;
    final showNetworkTab = developerMode || networkEvents.isNotEmpty;
    final tabs = [
      _PaneTab(label: 'Log', icon: Icons.terminal, countLabel: 'live'),
      if (showNetworkTab)
        _PaneTab(
          label: 'Network',
          icon: Icons.wifi,
          countLabel: '${networkEvents.length}',
        ),
    ];
    final views = [
      Semantics(
        label: t.progress.semantics_log_label,
        child: WizardLogView(lines: log, mode: logMode),
      ),
      if (showNetworkTab) NetworkPanel(events: networkEvents),
    ];
    return DefaultTabController(
      length: tabs.length,
      child: DeckhandPanel.flush(
        child: Column(
          children: [
            _PaneTabs(
              tokens: tokens,
              trailingLabel: 'session.log · ${log.length} lines',
              onCopyLog: log.isEmpty
                  ? null
                  : () => _copyLog(context, log, logMode),
              tabs: tabs,
            ),
            Expanded(child: TabBarView(children: views)),
          ],
        ),
      ),
    );
  }

  Future<void> _copyLog(
    BuildContext context,
    List<String> lines,
    WizardLogMode mode,
  ) async {
    await Clipboard.setData(
      ClipboardData(text: formatWizardLogForClipboard(lines, mode)),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Log copied')));
  }
}

class _PaneTab {
  _PaneTab({required this.label, required this.icon, required this.countLabel});
  final String label;
  final IconData icon;
  final String countLabel;
}

class _PaneTabs extends StatelessWidget {
  const _PaneTabs({
    required this.tokens,
    required this.tabs,
    required this.trailingLabel,
    required this.onCopyLog,
  });
  final DeckhandTokens tokens;
  final List<_PaneTab> tabs;
  final String trailingLabel;
  final VoidCallback? onCopyLog;

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            color: tokens.ink2,
            border: Border(bottom: BorderSide(color: tokens.line)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showTrailing = constraints.maxWidth >= 460;
              return Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < tabs.length; i++)
                            _PaneTabCell(
                              tab: tabs[i],
                              isActive: controller.index == i,
                              tokens: tokens,
                              onTap: () => controller.animateTo(i),
                            ),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy log',
                    icon: const Icon(Icons.content_copy, size: 14),
                    color: tokens.text3,
                    disabledColor: tokens.text4.withValues(alpha: 0.5),
                    onPressed: onCopyLog,
                  ),
                  if (showTrailing)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          trailingLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: DeckhandTokens.fontMono,
                            fontSize: 10,
                            color: tokens.text4,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

class _PaneTabCell extends StatelessWidget {
  const _PaneTabCell({
    required this.tab,
    required this.isActive,
    required this.tokens,
    required this.onTap,
  });
  final _PaneTab tab;
  final bool isActive;
  final DeckhandTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? tokens.ink1 : Colors.transparent,
          border: Border(
            top: BorderSide(
              color: isActive ? tokens.accent : Colors.transparent,
              width: 2,
            ),
            right: BorderSide(color: tokens.line),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab.icon,
              size: 14,
              color: isActive ? tokens.text : tokens.text3,
            ),
            const SizedBox(width: 8),
            Text(
              tab.label,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: isActive ? tokens.text : tokens.text3,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isActive ? tokens.accent : tokens.ink3,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tab.countLabel,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: 9,
                  color: isActive ? tokens.accentFg : tokens.text2,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String runStepTitle(String id) {
  final mapped = switch (id) {
    'choose_os_image' => 'Choose OS image',
    'choose_target_disk' => 'Check selected disk',
    'download_os' => 'Prepare OS image',
    'flash_disk' => 'Write OS image',
    'flash_done_prompt' => 'Confirm flash',
    'wait_for_ssh' => 'Wait for printer',
    'first_boot_setup' => 'Run first-boot setup',
    'install_firmware' => 'Install firmware',
    'install_stack' => 'Install Klipper services',
    'link_extras' => 'Install profile extras',
    'install_screen' => 'Install touchscreen UI',
    'flash_mcus' => 'Flash printer MCUs',
    'apply_services' => 'Clean up stock services',
    'apply_files' => 'Clean up stock files',
    'snapshot_paths' => 'Back up stock files',
    'write_file' => 'Write config',
    'install_marker' => 'Mark printer as managed',
    'verify' => 'Verify install',
    'script' => 'Run setup script',
    'ssh_commands' => 'Run remote commands',
    'conditional' => 'Evaluate condition',
    _ => null,
  };
  if (mapped != null) return mapped;
  final spaced = id.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  if (spaced.isEmpty) return id;
  return spaced[0].toUpperCase() + spaced.substring(1);
}

String _kindTitle(String kind) {
  if (kind.isEmpty) return 'step';
  return kind.replaceAll('_', ' ');
}

TextStyle _panelMetaStyle(BuildContext context) {
  final tokens = DeckhandTokens.of(context);
  return TextStyle(
    fontFamily: DeckhandTokens.fontMono,
    fontSize: 10,
    color: tokens.text4,
  );
}
