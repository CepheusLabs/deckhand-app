import 'package:deckhand_core/deckhand_core.dart';

import 'disk_operation_errors.dart';

String userFacingError(Object? error) {
  if (error == null) return 'Unknown error.';
  if (error is HostNotApprovedException) {
    final host = error.host.trim();
    final target = host.isEmpty ? 'this host' : host;
    return 'Network access to $target was not approved. Retry and choose Allow, or approve it from Settings.';
  }
  if (error is ProfileFormatException) {
    return 'The printer profile is invalid: ${error.message}';
  }
  if (error is DeckhandException) {
    return error.userMessage;
  }
  if (error is ResumeFailedException) {
    return 'The saved session could not be reopened. ${userFacingError(error.cause)}';
  }
  if (error is StepExecutionException) {
    return userFacingDiskOperationError(error.message);
  }
  if (error is WizardCancelledException) {
    return error.reason.trim().isEmpty ? 'Operation cancelled.' : error.reason;
  }
  return userFacingDiskOperationError(error);
}
