import '../models/printer_profile.dart';
import 'printer_state_probe.dart';
import 'wizard_flow.dart';
import 'wizard_state.dart';

/// Thrown by step executors when a step fails after starting (write
/// errors, sudo refused, command exited non-zero). Distinct from
/// pre-flight exceptions so the wizard can surface a step-id and
/// captured stderr to the user.
class StepExecutionException implements Exception {
  StepExecutionException(this.message, {this.stderr});
  final String message;
  final String? stderr;
  @override
  String toString() =>
      'StepExecutionException: $message${stderr != null && stderr!.isNotEmpty ? "\n$stderr" : ""}';
}

/// Thrown by [WizardController.startExecution] when
/// [WizardController.cancelExecution] has been called. Distinct
/// from [StepExecutionException] so callers can tell user-driven
/// abort apart from a step that genuinely errored.
class WizardCancelledException implements Exception {
  const WizardCancelledException(this.reason);
  final String reason;
  @override
  String toString() => 'WizardCancelledException: $reason';
}

/// Thrown when execution reached a real-world handoff that cannot be
/// completed inside the automated runner.
///
/// This is not a failed step. Fresh flashing, for example, has to pause
/// after the eMMC write so the user can reinstall the module and connect
/// to the newly booted printer before SSH-only steps can continue.
class WizardHandoffRequiredException implements Exception {
  const WizardHandoffRequiredException({
    required this.step,
    required this.route,
    required this.message,
  });

  final String step;
  final String route;
  final String message;

  @override
  String toString() => message;
}

/// Thrown by [WizardController.restore] when the saved profile id
/// can't be reloaded — most often because the user is offline, the
/// profiles repo moved, or the host hasn't been allow-listed yet.
/// Carries the original snapshot so the caller can keep it around
/// for a retry instead of silently falling back to
/// [WizardState.initial] (which threw away the user's session).
class ResumeFailedException implements Exception {
  const ResumeFailedException({
    required this.snapshot,
    required this.cause,
    required this.stackTrace,
  });
  final WizardState snapshot;
  final Object cause;
  final StackTrace stackTrace;
  @override
  String toString() =>
      'ResumeFailedException(profile="${snapshot.profileId}", '
      'step="${snapshot.currentStep}"): $cause';
}

/// Closed hierarchy of every event the wizard controller emits. Sealed
/// so a downstream `switch` on this type is exhaustive — adding a new
/// event without handling every consumer is a compile error, not a
/// silent runtime no-op.
sealed class WizardEvent {
  const WizardEvent();
}

class ProfileLoaded extends WizardEvent {
  const ProfileLoaded(this.profile);
  final PrinterProfile profile;
}

class SshConnected extends WizardEvent {
  const SshConnected({required this.host, required this.user});
  final String host;
  final String user;
}

class DecisionRecorded extends WizardEvent {
  const DecisionRecorded({required this.path, required this.value});
  final String path;
  final Object value;
}

class FlowChanged extends WizardEvent {
  const FlowChanged(this.flow);
  final WizardFlow flow;
}

class StepStarted extends WizardEvent {
  const StepStarted(this.stepId);
  final String stepId;
}

class StepProgress extends WizardEvent {
  const StepProgress({
    required this.stepId,
    required this.percent,
    this.message,
  });
  final String stepId;
  final double? percent;
  final String? message;
}

class StepLog extends WizardEvent {
  const StepLog({required this.stepId, required this.line});
  final String stepId;
  final String line;
}

class StepCompleted extends WizardEvent {
  const StepCompleted(this.stepId);
  final String stepId;
}

class StepFailed extends WizardEvent {
  const StepFailed({required this.stepId, required this.error});
  final String stepId;
  final String error;
}

class StepWarning extends WizardEvent {
  const StepWarning({required this.stepId, required this.message});
  final String stepId;
  final String message;
}

class UserInputRequired extends WizardEvent {
  const UserInputRequired({required this.stepId, required this.step});
  final String stepId;
  final Map<String, dynamic> step;
}

class ExecutionCompleted extends WizardEvent {
  const ExecutionCompleted();
}

/// Emitted once the state probe lands fresh data. Screens watching
/// `wizardStateProvider` rebuild on this (via the generic stream)
/// and re-render with machine-specific state applied.
class PrinterStateRefreshed extends WizardEvent {
  const PrinterStateRefreshed(this.state);
  final PrinterState state;
}
