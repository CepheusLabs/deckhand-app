import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:deckhand_core/deckhand_web_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'web/browser_device_transport.dart';
import 'web/local_agent_client.dart';

const _apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '/api/v1',
);
const _localAgentBaseUrl = String.fromEnvironment(
  'LOCAL_AGENT_URL',
  defaultValue: 'http://127.0.0.1:48765/v1',
);
const _localAgentToken = String.fromEnvironment('LOCAL_AGENT_TOKEN');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DeckhandWebApp());
}

class DeckhandWebApp extends StatefulWidget {
  const DeckhandWebApp({super.key});

  @override
  State<DeckhandWebApp> createState() => _DeckhandWebAppState();
}

class _DeckhandWebAppState extends State<DeckhandWebApp> {
  final _dio = Dio(BaseOptions(baseUrl: _apiBaseUrl));
  final _profileIdController = TextEditingController();
  final _log = <String>[];
  late final DeckhandLocalAgentClient _localAgentClient =
      DeckhandLocalAgentClient(
        baseUrl: _localAgentBaseUrl,
        token: _localAgentToken,
        dio: _dio,
      );
  DeckhandTransportAvailability _availability = detectDeckhandWebTransports();
  PrinterProfile? _profile;
  String? _profileSource;
  String? _selectedFlowId;
  int _selectedStepIndex = 0;
  Uint8List? _firmwareBytes;
  String? _firmwareName;
  StreamSubscription<DeckhandTransportEvent>? _subscription;
  bool _running = false;
  bool _loadingProfile = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshAvailability());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _profileIdController.dispose();
    _dio.close();
    super.dispose();
  }

  Future<void> _loadBackendProfile() async {
    final profileId = _profileIdController.text.trim();
    if (profileId.isEmpty || _loadingProfile) return;
    setState(() => _loadingProfile = true);
    try {
      final response = await _dio.get<Map<String, Object?>>(
        '/deckhand/profiles/$profileId',
      );
      final profile = _profileFromBackend(response.data);
      _setProfile(profile, 'PrintDeck profile $profileId');
    } catch (error) {
      _append('Profile load failed: $error');
    } finally {
      setState(() => _loadingProfile = false);
    }
  }

  Future<void> _loadProfileFile() async {
    final input = html.FileUploadInputElement();
    input.accept = '.yaml,.yml,text/yaml,text/plain';
    input.click();
    await input.onChange.first;
    final file = input.files?.first;
    if (file == null) return;
    final reader = html.FileReader();
    reader.readAsText(file);
    await reader.onLoad.first;
    final text = reader.result?.toString() ?? '';
    try {
      _setProfile(parseDeckhandWebProfileYaml(text), file.name);
    } catch (error) {
      _append('Profile parse failed: $error');
    }
  }

  PrinterProfile _profileFromBackend(Map<String, Object?>? data) {
    final envelope = _dataObject(data);
    final yaml = envelope['profile_yaml'];
    if (yaml is String && yaml.trim().isNotEmpty) {
      return parseDeckhandWebProfileYaml(yaml);
    }
    final profile = envelope['profile'];
    if (profile is Map) {
      return PrinterProfile.fromJson(profile.cast<String, dynamic>());
    }
    throw StateError(
      'Deckhand profile response must include profile_yaml or profile.',
    );
  }

  Map<String, Object?> _dataObject(Map<String, Object?>? response) {
    final data = response?['data'];
    if (data is Map<String, Object?>) return data;
    return response ?? const <String, Object?>{};
  }

  void _setProfile(PrinterProfile profile, String source) {
    final flows = deckhandWebFlowsForProfile(profile);
    setState(() {
      _profile = profile;
      _profileSource = source;
      _selectedFlowId = flows.isEmpty ? null : flows.first.id;
      _selectedStepIndex = 0;
      _log
        ..clear()
        ..add('Loaded ${profile.displayName} (${profile.id})');
    });
  }

  Future<void> _pickFirmware() async {
    final input = html.FileUploadInputElement();
    input.accept = '.bin,.uf2,.hex,.dfu,.img,application/octet-stream';
    input.click();
    await input.onChange.first;
    final file = input.files?.first;
    if (file == null) return;
    final reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoad.first;
    final result = reader.result;
    if (result is ByteBuffer) {
      setState(() {
        _firmwareBytes = Uint8List.view(result);
        _firmwareName = file.name;
      });
    }
  }

  Future<void> _runSelectedStep() async {
    final step = _selectedStep;
    if (step == null) {
      _append('Select a runnable profile step first.');
      return;
    }
    await _runStep(step.step);
  }

  Future<void> _runAvailableFlow() async {
    final steps = _plannedSteps.where(_canRunFromWeb);
    for (final step in steps) {
      if (!mounted) return;
      await _runStep(step.step);
      if (_running) return;
    }
  }

  Future<void> _runStep(Map<String, dynamic> step) async {
    if (_running) return;
    final gate = gateDeckhandStepTransport(
      step: step,
      availability: _availability,
    );
    if (!gate.isAvailable) {
      _append('Missing transport: ${gate.missingRequirements.join(', ')}');
      return;
    }
    if (gate.surface == DeckhandExecutionSurface.desktopApp) {
      _append('Step requires the desktop app: ${gate.requirements.join(', ')}');
      return;
    }
    final firmwareUrl = firmwareUriForDeckhandStep(step);
    final fileName =
        firmwareFileNameForDeckhandStep(step) ??
        _firmwareName ??
        _fileNameFromUri(firmwareUrl);
    final completer = Completer<void>();
    setState(() => _running = true);
    _subscription = _executor()
        .executeStep(
          step,
          firmwareBytes: _firmwareBytes,
          firmwareUrl: firmwareUrl,
          fileName: fileName,
          metadata: {
            if (_profile != null) 'profile_id': _profile!.id,
            if (_selectedFlowId != null) 'flow_id': _selectedFlowId,
          },
        )
        .listen(
          (event) {
            final pct = event.percent == null
                ? ''
                : ' ${(event.percent! * 100).toStringAsFixed(0)}%';
            _append('${event.phase.name}$pct ${event.message ?? ''}'.trim());
          },
          onError: (Object error) {
            _append('Failed: $error');
            setState(() => _running = false);
            if (!completer.isCompleted) completer.complete();
          },
          onDone: () {
            setState(() => _running = false);
            if (!completer.isCompleted) completer.complete();
          },
        );
    await completer.future;
  }

  DeckhandTransportExecutor _executor() {
    final browserTransport = DeckhandBrowserDeviceTransport();
    return DeckhandTransportExecutor(
      availability: _availability,
      transports: [
        ManualDownloadTransport(onDownload: _downloadFirmware),
        DelegatedBrowserFlashTransport(
          id: 'webusb',
          prefix: 'webusb',
          delegate: WebUsbDfuDelegate(
            transport: browserTransport,
            firmwareFetcher: _fetchFirmware,
          ),
        ),
        DelegatedBrowserFlashTransport(
          id: 'webserial',
          prefix: 'webserial',
          delegate: WebSerialBootloaderDelegate(
            transport: browserTransport,
            firmwareFetcher: _fetchFirmware,
          ),
        ),
        DelegatedBrowserFlashTransport(
          id: 'webhid',
          prefix: 'webhid',
          delegate: WebHidReportDelegate(
            transport: browserTransport,
            firmwareFetcher: _fetchFirmware,
          ),
        ),
        if (_availability.localAgent)
          LocalAgentFlashTransport(client: _localAgentClient),
      ],
    );
  }

  Future<Uint8List> _fetchFirmware(Uri uri) async {
    final response = await _dio.get<List<int>>(
      uri.toString(),
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(response.data ?? const <int>[]);
  }

  Future<void> _downloadFirmware(DeckhandTransportOperation operation) async {
    final bytes = operation.firmwareBytes ?? _firmwareBytes;
    final href = operation.firmwareUrl?.toString();
    final String url;
    if (bytes != null) {
      final blob = html.Blob([bytes]);
      url = html.Url.createObjectUrlFromBlob(blob);
    } else if (href != null && href.isNotEmpty) {
      url = href;
    } else {
      _append('No firmware bytes or URL are available for download.');
      return;
    }
    final anchor = html.AnchorElement(href: url)
      ..download = operation.fileName ?? _firmwareName ?? 'firmware.bin'
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    if (bytes != null) html.Url.revokeObjectUrl(url);
  }

  void _append(String message) {
    setState(() => _log.add(message));
  }

  Future<void> _refreshAvailability() async {
    final browserAvailability = detectDeckhandWebTransports();
    setState(() => _availability = browserAvailability);
    final localAgent = await _localAgentClient.ping();
    if (!mounted) return;
    setState(() {
      _availability = browserAvailability.copyWith(localAgent: localAgent);
    });
    if (localAgent) {
      _append('Local agent connected.');
    }
  }

  List<DeckhandWebStepPlan> get _plannedSteps {
    final profile = _profile;
    final flowId = _selectedFlowId;
    if (profile == null || flowId == null) return const [];
    return planDeckhandWebFlow(
      profile: profile,
      flowId: flowId,
      availability: _availability,
    );
  }

  DeckhandWebStepPlan? get _selectedStep {
    final steps = _plannedSteps;
    if (_selectedStepIndex < 0 || _selectedStepIndex >= steps.length) {
      return null;
    }
    return steps[_selectedStepIndex];
  }

  bool _canRunFromWeb(DeckhandWebStepPlan step) {
    return step.runnableInBrowser ||
        step.gate.surface == DeckhandExecutionSurface.localAgent;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Deckhand',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff4f7cff),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Deckhand'),
          actions: [
            IconButton(
              tooltip: 'Refresh transports',
              onPressed: () => unawaited(_refreshAvailability()),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1100;
            final profilePanel = _ProfilePanel(
              profile: _profile,
              source: _profileSource,
              loading: _loadingProfile,
              profileIdController: _profileIdController,
              onLoadBackend: _loadBackendProfile,
              onLoadFile: _loadProfileFile,
            );
            final flowPanel = _FlowPanel(
              profile: _profile,
              selectedFlowId: _selectedFlowId,
              selectedStepIndex: _selectedStepIndex,
              availability: _availability,
              steps: _plannedSteps,
              running: _running,
              onFlowSelected: (flowId) => setState(() {
                _selectedFlowId = flowId;
                _selectedStepIndex = 0;
              }),
              onStepSelected: (index) => setState(() {
                _selectedStepIndex = index;
              }),
              onRunStep: _runSelectedStep,
              onRunAvailableFlow: _runAvailableFlow,
            );
            final runPanel = _RunPanel(
              availability: _availability,
              firmwareName: _firmwareName,
              firmwareBytes: _firmwareBytes,
              log: _log,
              running: _running,
              onPickFirmware: _pickFirmware,
            );
            return Padding(
              padding: const EdgeInsets.all(16),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: profilePanel),
                        const SizedBox(width: 16),
                        Expanded(flex: 2, child: flowPanel),
                        const SizedBox(width: 16),
                        Expanded(child: runPanel),
                      ],
                    )
                  : ListView(
                      children: [
                        SizedBox(height: 360, child: profilePanel),
                        const SizedBox(height: 16),
                        SizedBox(height: 520, child: flowPanel),
                        const SizedBox(height: 16),
                        SizedBox(height: 360, child: runPanel),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _ProfilePanel extends StatelessWidget {
  const _ProfilePanel({
    required this.profile,
    required this.source,
    required this.loading,
    required this.profileIdController,
    required this.onLoadBackend,
    required this.onLoadFile,
  });

  final PrinterProfile? profile;
  final String? source;
  final bool loading;
  final TextEditingController profileIdController;
  final VoidCallback onLoadBackend;
  final VoidCallback onLoadFile;

  @override
  Widget build(BuildContext context) {
    final profile = this.profile;
    return _Panel(
      title: 'Profile',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: profileIdController,
                  decoration: const InputDecoration(
                    labelText: 'Profile id',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Load from PrintDeck',
                onPressed: loading ? null : onLoadBackend,
                icon: loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_download),
              ),
              IconButton(
                tooltip: 'Open profile YAML',
                onPressed: loading ? null : onLoadFile,
                icon: const Icon(Icons.folder_open),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (profile == null)
            const Text('No profile loaded.')
          else ...[
            Text(
              profile.displayName.isEmpty ? profile.id : profile.displayName,
              style: Theme.of(context).textTheme.titleLarge,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            _MetaLine(label: 'ID', value: profile.id),
            _MetaLine(label: 'Version', value: profile.version),
            _MetaLine(label: 'Status', value: profile.status.name),
            _MetaLine(label: 'Source', value: source ?? ''),
          ],
        ],
      ),
    );
  }
}

class _FlowPanel extends StatelessWidget {
  const _FlowPanel({
    required this.profile,
    required this.selectedFlowId,
    required this.selectedStepIndex,
    required this.availability,
    required this.steps,
    required this.running,
    required this.onFlowSelected,
    required this.onStepSelected,
    required this.onRunStep,
    required this.onRunAvailableFlow,
  });

  final PrinterProfile? profile;
  final String? selectedFlowId;
  final int selectedStepIndex;
  final DeckhandTransportAvailability availability;
  final List<DeckhandWebStepPlan> steps;
  final bool running;
  final ValueChanged<String> onFlowSelected;
  final ValueChanged<int> onStepSelected;
  final VoidCallback onRunStep;
  final VoidCallback onRunAvailableFlow;

  @override
  Widget build(BuildContext context) {
    final profile = this.profile;
    final flows = profile == null
        ? const <DeckhandWebProfileFlow>[]
        : deckhandWebFlowsForProfile(profile);
    return _Panel(
      title: 'Flow',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (flows.isNotEmpty)
            SegmentedButton<String>(
              segments: [
                for (final flow in flows)
                  ButtonSegment(value: flow.id, label: Text(flow.label)),
              ],
              selected: {selectedFlowId ?? flows.first.id},
              onSelectionChanged: running
                  ? null
                  : (value) => onFlowSelected(value.single),
            )
          else
            const Text('Load a profile with enabled flows.'),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              itemCount: steps.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final step = steps[index];
                return _StepCard(
                  plan: step,
                  selected: index == selectedStepIndex,
                  onPressed: running ? null : () => onStepSelected(index),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Run selected browser step',
                onPressed: running || steps.isEmpty ? null : onRunStep,
                icon: running
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
              ),
              IconButton(
                tooltip: 'Run available steps',
                onPressed:
                    running ||
                        !steps.any(
                          (s) =>
                              s.runnableInBrowser ||
                              s.gate.surface ==
                                  DeckhandExecutionSurface.localAgent,
                        )
                    ? null
                    : onRunAvailableFlow,
                icon: const Icon(Icons.playlist_play),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.plan,
    required this.selected,
    required this.onPressed,
  });

  final DeckhandWebStepPlan plan;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final gate = plan.gate;
    final color = gate.usesBrowser
        ? Colors.greenAccent
        : gate.requiresNativeFallback
        ? Colors.amberAccent
        : Colors.redAccent;
    final status = gate.usesBrowser
        ? 'browser'
        : gate.requiresNativeFallback
        ? gate.surface.name
        : 'unavailable';
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        side: BorderSide(
          color: selected ? Theme.of(context).colorScheme.primary : color,
        ),
        padding: const EdgeInsets.all(12),
      ),
      child: Row(
        children: [
          Icon(
            gate.usesBrowser
                ? Icons.check_circle
                : gate.requiresNativeFallback
                ? Icons.desktop_windows
                : Icons.block,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  '${plan.id} · ${plan.kind}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(status, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _RunPanel extends StatelessWidget {
  const _RunPanel({
    required this.availability,
    required this.firmwareName,
    required this.firmwareBytes,
    required this.log,
    required this.running,
    required this.onPickFirmware,
  });

  final DeckhandTransportAvailability availability;
  final String? firmwareName;
  final Uint8List? firmwareBytes;
  final List<String> log;
  final bool running;
  final VoidCallback onPickFirmware;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Run',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TransportRow(label: 'WebUSB', enabled: availability.webUsb),
          _TransportRow(label: 'WebHID', enabled: availability.webHid),
          _TransportRow(label: 'WebSerial', enabled: availability.webSerial),
          _TransportRow(
            label: 'Manual UF2',
            enabled: availability.manualDownload,
          ),
          _TransportRow(label: 'Local Agent', enabled: availability.localAgent),
          const Divider(),
          Row(
            children: [
              Expanded(
                child: Text(
                  firmwareName == null
                      ? 'No firmware override selected'
                      : '$firmwareName (${firmwareBytes!.length} bytes)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Choose firmware override',
                onPressed: running ? null : onPickFirmware,
                icon: const Icon(Icons.attach_file),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.all(10),
                itemCount: log.length,
                itemBuilder: (context, index) {
                  return Text(
                    log[index],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({required this.label, required this.enabled});

  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        enabled ? Icons.check_circle : Icons.block,
        color: enabled ? Colors.greenAccent : Colors.redAccent,
      ),
      title: Text(label),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium),
          ),
          Expanded(
            child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

String? _fileNameFromUri(Uri? uri) {
  if (uri == null || uri.pathSegments.isEmpty) {
    return null;
  }
  final last = uri.pathSegments.last.trim();
  return last.isEmpty ? null : last;
}
