import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:printdeck_product_platform/printdeck_product_platform.dart';

class DeckhandProductModule implements ProductModule {
  DeckhandProductModule({
    required DoctorService doctorService,
    required FlashService flashService,
  }) : _doctorService = doctorService,
       _flashService = flashService;

  final DoctorService _doctorService;
  final FlashService _flashService;

  @override
  Future<ProductModuleDescriptor> describe() async {
    return const ProductModuleDescriptor(
      id: 'deckhand',
      displayName: 'Deckhand',
      version: '1.0.0',
      runtimeModes: <ProductRuntimeMode>{
        ProductRuntimeMode.local,
        ProductRuntimeMode.standalone,
      },
      capabilities: <AgenticCapabilityDescriptor>[
        deckhandHostDiagnoseCapability,
        deckhandImageApplyCapability,
      ],
    );
  }

  @override
  Future<ProductContextSnapshot> contextSnapshot(
    ProductInvocationContext context,
  ) async {
    return ProductContextSnapshot(
      moduleId: 'deckhand',
      runtimeMode: context.runtimeMode,
      values: const <String, Object?>{'surface': 'setup'},
    );
  }

  @override
  Future<ProductResource> readResource(ProductResourceRequest request) async {
    final report = await _doctorService.run();
    return ProductResource(
      uri: request.uri,
      mediaType: 'text/plain',
      bytes: report.report.codeUnits,
      metadata: <String, Object?>{'passed': report.passed},
    );
  }

  @override
  Future<ProductActionResult> invokeAction(
    ProductActionInvocation invocation,
  ) async {
    return switch (invocation.capabilityId) {
      'deckhand.host.diagnose' => _runDoctor(),
      'deckhand.image.apply' => _writeImage(invocation.input),
      _ => Future<ProductActionResult>.value(
        ProductActionResult(
          status: ProductActionStatus.failed,
          message:
              'Unsupported Deckhand capability: ${invocation.capabilityId}',
        ),
      ),
    };
  }

  Future<ProductActionResult> _runDoctor() async {
    final report = await _doctorService.run();
    return ProductActionResult(
      status: report.passed
          ? ProductActionStatus.success
          : ProductActionStatus.failed,
      output: <String, Object?>{
        'passed': report.passed,
        'report': report.report,
        'results': <Map<String, Object?>>[
          for (final result in report.results)
            <String, Object?>{
              'name': result.name,
              'status': result.status.name,
              'detail': result.detail,
            },
        ],
      },
      warnings: <String>[
        for (final warning in report.warnings)
          '${warning.name}: ${warning.detail}',
      ],
    );
  }

  Future<ProductActionResult> _writeImage(Map<String, Object?> input) async {
    final imagePath = input['image_path'] as String?;
    final diskId = input['disk_id'] as String?;
    final confirmationToken = input['confirmation_token'] as String?;
    if (imagePath == null || diskId == null || confirmationToken == null) {
      return const ProductActionResult(
        status: ProductActionStatus.failed,
        message: 'image_path, disk_id, and confirmation_token are required',
      );
    }

    final safety = await _flashService.safetyCheck(diskId: diskId);
    if (!safety.allowed) {
      return ProductActionResult(
        status: ProductActionStatus.denied,
        warnings: safety.blockingReasons,
        message: 'Deckhand safety check blocked image write',
      );
    }

    FlashProgress? lastProgress;
    await for (final progress in _flashService.writeImage(
      imagePath: imagePath,
      diskId: diskId,
      confirmationToken: confirmationToken,
    )) {
      lastProgress = progress;
    }

    return ProductActionResult(
      status: lastProgress?.phase == FlashPhase.failed
          ? ProductActionStatus.failed
          : ProductActionStatus.success,
      output: <String, Object?>{
        'disk_id': diskId,
        'image_path': imagePath,
        'phase': lastProgress?.phase.name,
        'bytes_done': lastProgress?.bytesDone,
        'bytes_total': lastProgress?.bytesTotal,
      },
      warnings: safety.warnings,
    );
  }

  @override
  Future<ProductActionResult> taskStatus(
    String taskId,
    ProductInvocationContext context,
  ) async {
    return ProductActionResult(
      status: ProductActionStatus.failed,
      message:
          'Deckhand task status is streamed by the flash operation: $taskId',
    );
  }

  @override
  Future<ProductActionResult> taskCancel(
    String taskId,
    ProductInvocationContext context,
  ) async {
    return ProductActionResult(
      status: ProductActionStatus.failed,
      message:
          'Deckhand task cancellation must target the underlying flash job: $taskId',
    );
  }

  @override
  Stream<ProductModuleEvent> events(ProductInvocationContext context) {
    return const Stream<ProductModuleEvent>.empty();
  }

  @override
  Future<ProductModuleHealth> healthCheck() async {
    final report = await _doctorService.run();
    return ProductModuleHealth(
      moduleId: 'deckhand',
      status: report.passed
          ? ProductModuleHealthStatus.healthy
          : ProductModuleHealthStatus.degraded,
      message: report.passed
          ? null
          : report.failures.map((f) => f.name).join(', '),
    );
  }
}

const deckhandHostDiagnoseCapability = AgenticCapabilityDescriptor(
  id: 'deckhand.host.diagnose',
  owner: 'deckhand',
  object: 'diagnostic',
  verb: 'diagnose',
  title: 'Run host doctor',
  description: 'Run Deckhand host diagnostics and return normalized findings.',
  inputSchema: <String, Object?>{'type': 'object'},
  outputSchema: <String, Object?>{'type': 'object'},
  permissions: <String>{'setup.host.read', 'diagnostics.read'},
  dangerLevel: AgenticDangerLevel.safe,
  approval: AgenticApprovalRequirement.none,
  auditEvent: 'agent.tool.invoke',
  taskBehavior: ProductTaskBehavior.longRunning,
  exposure: AgenticProjection(
    shell: true,
    cortex: false,
    mcp: true,
    nexus: true,
  ),
  transport: AgenticTransport(
    kind: AgenticTransportKind.localRuntime,
    target: 'deckhand.module/action.invoke',
  ),
  command: AgenticCommandMetadata(category: 'Host', surface: 'doctor'),
  nexus: AgenticNexusMetadata(nodeType: 'action'),
);

const deckhandImageApplyCapability = AgenticCapabilityDescriptor(
  id: 'deckhand.image.apply',
  owner: 'deckhand',
  object: 'image',
  verb: 'apply',
  title: 'Write setup image',
  description:
      'Write a validated setup image through the guarded provisioning path.',
  inputSchema: <String, Object?>{
    'type': 'object',
    'required': <String>['image_path', 'disk_id', 'confirmation_token'],
  },
  outputSchema: <String, Object?>{'type': 'object'},
  permissions: <String>{'setup.image.write'},
  dangerLevel: AgenticDangerLevel.critical,
  approval: AgenticApprovalRequirement.freshRequired,
  auditEvent: 'agent.approval.resolve',
  taskBehavior: ProductTaskBehavior.longRunning,
  exposure: AgenticProjection(
    shell: true,
    cortex: false,
    mcp: true,
    nexus: true,
  ),
  transport: AgenticTransport(
    kind: AgenticTransportKind.localRuntime,
    target: 'deckhand.module/action.invoke',
  ),
  command: AgenticCommandMetadata(category: 'Image', surface: 'images'),
  nexus: AgenticNexusMetadata(nodeType: 'action'),
);
