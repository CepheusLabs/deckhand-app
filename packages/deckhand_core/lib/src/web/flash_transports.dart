import 'dart:async';
import 'dart:typed_data';

import 'transport_capabilities.dart';

enum DeckhandTransportPhase {
  preparing,
  connecting,
  flashing,
  verifying,
  downloadReady,
  done,
  failed,
}

class DeckhandTransportEvent {
  const DeckhandTransportEvent({
    required this.phase,
    this.percent,
    this.message,
    this.bytesDone,
    this.bytesTotal,
    this.result = const <String, Object?>{},
  });

  final DeckhandTransportPhase phase;
  final double? percent;
  final String? message;
  final int? bytesDone;
  final int? bytesTotal;
  final Map<String, Object?> result;
}

class DeckhandTransportOperation {
  const DeckhandTransportOperation({
    required this.requirement,
    required this.step,
    this.firmwareBytes,
    this.firmwareUrl,
    this.fileName,
    this.metadata = const <String, Object?>{},
  });

  final String requirement;
  final Map<String, dynamic> step;
  final Uint8List? firmwareBytes;
  final Uri? firmwareUrl;
  final String? fileName;
  final Map<String, Object?> metadata;

  String get normalizedRequirement => requirement.trim().toLowerCase();
}

abstract class DeckhandFlashTransport {
  String get id;

  bool canHandle(DeckhandTransportOperation operation);

  Stream<DeckhandTransportEvent> execute(DeckhandTransportOperation operation);
}

typedef DeckhandManualDownloadHandler =
    FutureOr<void> Function(DeckhandTransportOperation operation);

class ManualDownloadTransport implements DeckhandFlashTransport {
  const ManualDownloadTransport({this.onDownload});

  final DeckhandManualDownloadHandler? onDownload;

  @override
  String get id => 'manual-download';

  @override
  bool canHandle(DeckhandTransportOperation operation) {
    final req = operation.normalizedRequirement;
    return req == 'manual.uf2' || req == 'manual-download';
  }

  @override
  Stream<DeckhandTransportEvent> execute(
    DeckhandTransportOperation operation,
  ) async* {
    if (!canHandle(operation)) {
      throw DeckhandTransportException(
        'manual download cannot handle ${operation.requirement}',
      );
    }
    yield DeckhandTransportEvent(
      phase: DeckhandTransportPhase.downloadReady,
      percent: 0,
      message: 'download ready',
      result: {
        if (operation.fileName != null) 'file_name': operation.fileName,
        if (operation.firmwareUrl != null)
          'firmware_url': operation.firmwareUrl.toString(),
        if (operation.firmwareBytes != null)
          'size_bytes': operation.firmwareBytes!.length,
      },
    );
    await onDownload?.call(operation);
    yield const DeckhandTransportEvent(
      phase: DeckhandTransportPhase.done,
      percent: 1,
      message: 'manual handoff ready',
    );
  }
}

abstract class BrowserFlashDelegate {
  bool canHandle(String requirement);

  Stream<DeckhandTransportEvent> execute(DeckhandTransportOperation operation);
}

class DelegatedBrowserFlashTransport implements DeckhandFlashTransport {
  const DelegatedBrowserFlashTransport({
    required this.id,
    required this.prefix,
    required this.delegate,
  });

  @override
  final String id;
  final String prefix;
  final BrowserFlashDelegate delegate;

  @override
  bool canHandle(DeckhandTransportOperation operation) {
    final req = operation.normalizedRequirement;
    return req.startsWith('$prefix.') && delegate.canHandle(req);
  }

  @override
  Stream<DeckhandTransportEvent> execute(DeckhandTransportOperation operation) {
    if (!canHandle(operation)) {
      throw DeckhandTransportException(
        '$id cannot handle ${operation.requirement}',
      );
    }
    return delegate.execute(operation);
  }
}

abstract class LocalAgentClient {
  Stream<Map<String, Object?>> callStreaming(
    String method,
    Map<String, Object?> params,
  );
}

class LocalAgentFlashTransport implements DeckhandFlashTransport {
  const LocalAgentFlashTransport({required this.client});

  final LocalAgentClient client;

  @override
  String get id => 'local-agent';

  @override
  bool canHandle(DeckhandTransportOperation operation) {
    final req = operation.normalizedRequirement;
    return req == 'local-agent' ||
        req == 'raw_disk_write' ||
        req == 'raw-disk-write' ||
        req == 'ssh.lan' ||
        req == 'moonraker.lan' ||
        req.startsWith('local-agent.');
  }

  @override
  Stream<DeckhandTransportEvent> execute(
    DeckhandTransportOperation operation,
  ) async* {
    if (!canHandle(operation)) {
      throw DeckhandTransportException(
        'local agent cannot handle ${operation.requirement}',
      );
    }
    final method =
        operation.step['local_agent_method']?.toString().trim().isNotEmpty ==
            true
        ? operation.step['local_agent_method'].toString().trim()
        : _defaultLocalAgentMethod(operation.normalizedRequirement);
    final params = <String, Object?>{
      ..._agentParamsFromStep(operation.step),
      'requirement': operation.requirement,
      'step': operation.step,
      if (operation.firmwareUrl != null)
        'firmware_url': operation.firmwareUrl.toString(),
      if (operation.fileName != null) 'file_name': operation.fileName,
      ...operation.metadata,
    };
    await for (final raw in client.callStreaming(method, params)) {
      yield _eventFromAgentMap(raw);
    }
  }

  static String _defaultLocalAgentMethod(String requirement) {
    if (requirement == 'raw_disk_write' || requirement == 'raw-disk-write') {
      return 'disks.write_image';
    }
    if (requirement == 'ssh.lan') return 'ssh.exec';
    if (requirement == 'moonraker.lan') return 'moonraker.call';
    return 'deckhand.transport.execute';
  }
}

Map<String, Object?> _agentParamsFromStep(Map<String, dynamic> step) {
  return {
    for (final entry in step.entries)
      if (_allowedAgentParam(entry.key, entry.value)) entry.key: entry.value,
  };
}

bool _allowedAgentParam(String key, Object? value) {
  if (key == 'step' || key == 'requirement') {
    return false;
  }
  return value == null ||
      value is String ||
      value is num ||
      value is bool ||
      value is List ||
      value is Map;
}

class DeckhandTransportExecutor {
  const DeckhandTransportExecutor({
    required this.availability,
    required this.transports,
  });

  final DeckhandTransportAvailability availability;
  final List<DeckhandFlashTransport> transports;

  Stream<DeckhandTransportEvent> executeStep(
    Map<String, dynamic> step, {
    Uint8List? firmwareBytes,
    Uri? firmwareUrl,
    String? fileName,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async* {
    final gate = gateDeckhandStepTransport(
      step: step,
      availability: availability,
    );
    if (!gate.isAvailable) {
      throw DeckhandTransportException(
        'missing transport requirements: '
        '${gate.missingRequirements.join(', ')}',
      );
    }
    final requirements = gate.requirements.isEmpty
        ? const ['manual-download']
        : gate.requirements;
    for (final requirement in requirements) {
      final operation = DeckhandTransportOperation(
        requirement: requirement,
        step: step,
        firmwareBytes: firmwareBytes,
        firmwareUrl: firmwareUrl,
        fileName: fileName,
        metadata: metadata,
      );
      DeckhandFlashTransport? transport;
      for (final candidate in transports) {
        if (candidate.canHandle(operation)) {
          transport = candidate;
          break;
        }
      }
      if (transport == null) {
        throw DeckhandTransportException(
          'no transport registered for $requirement',
        );
      }
      yield DeckhandTransportEvent(
        phase: DeckhandTransportPhase.preparing,
        percent: 0,
        message: 'starting ${transport.id}',
      );
      await for (final event in transport.execute(operation)) {
        yield event;
      }
    }
  }
}

class DeckhandTransportException implements Exception {
  const DeckhandTransportException(this.message);

  final String message;

  @override
  String toString() => message;
}

DeckhandTransportEvent _eventFromAgentMap(Map<String, Object?> raw) {
  final phase = _phaseFromString(raw['phase']?.toString());
  final percent = raw['percent'];
  final bytesDone = _intValue(raw['bytes_done']);
  final bytesTotal = _intValue(raw['bytes_total']);
  final derivedPercent =
      bytesDone != null && bytesTotal != null && bytesTotal > 0
      ? bytesDone / bytesTotal
      : null;
  return DeckhandTransportEvent(
    phase: phase,
    percent: percent is num ? percent.toDouble() : derivedPercent,
    message: raw['message']?.toString(),
    bytesDone: bytesDone,
    bytesTotal: bytesTotal,
    result: raw,
  );
}

DeckhandTransportPhase _phaseFromString(String? phase) {
  switch (phase) {
    case 'connecting':
      return DeckhandTransportPhase.connecting;
    case 'flashing':
    case 'writing':
    case 'reading':
    case 'downloading':
    case 'extracting':
      return DeckhandTransportPhase.flashing;
    case 'verifying':
      return DeckhandTransportPhase.verifying;
    case 'download_ready':
      return DeckhandTransportPhase.downloadReady;
    case 'done':
      return DeckhandTransportPhase.done;
    case 'failed':
      return DeckhandTransportPhase.failed;
    default:
      return DeckhandTransportPhase.preparing;
  }
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '');
}
