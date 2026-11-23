import 'json_support.dart';
import 'tool.dart';

enum ConfirmationDecision { accept, reject, cancel }

enum ConfirmationStatus {
  accepted,
  rejected,
  cancelled,
  conflict,
  notFound,
  alreadyResolved,
  invalid,
  failed,
}

final class ConfirmationCommand {
  ConfirmationCommand({required this.confirmationId, required this.decision}) {
    if (confirmationId.trim().isEmpty) {
      throw ArgumentError.value(confirmationId, 'confirmationId', '不能为空');
    }
  }

  final String confirmationId;
  final ConfirmationDecision decision;

  factory ConfirmationCommand.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {'confirmationId', 'decision'},
    );
    return ConfirmationCommand(
      confirmationId: readProtocolString(
        json['confirmationId'],
        '$path/confirmationId',
      ),
      decision: readProtocolEnum(
        json['decision'],
        '$path/decision',
        ConfirmationDecision.values,
      ),
    );
  }

  JsonObject toJson() => {
    'confirmationId': confirmationId,
    'decision': decision.name,
  };
}

final class ConfirmationResult {
  ConfirmationResult({
    required this.confirmationId,
    required this.status,
    this.newVersionId,
    required this.replayed,
    this.error,
  }) {
    if (confirmationId.trim().isEmpty) {
      throw ArgumentError.value(confirmationId, 'confirmationId', '不能为空');
    }
  }

  final String confirmationId;
  final ConfirmationStatus status;
  final String? newVersionId;
  final bool replayed;
  final ToolError? error;

  factory ConfirmationResult.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {
        'confirmationId',
        'status',
        'newVersionId',
        'replayed',
        'error',
      },
    );
    final errorSource = json['error'];
    return ConfirmationResult(
      confirmationId: readProtocolString(
        json['confirmationId'],
        '$path/confirmationId',
      ),
      status: readProtocolEnum(
        json['status'],
        '$path/status',
        ConfirmationStatus.values,
      ),
      newVersionId: readOptionalProtocolString(
        json['newVersionId'],
        '$path/newVersionId',
      ),
      replayed: readProtocolBool(json['replayed'], '$path/replayed'),
      error: errorSource == null
          ? null
          : ToolError.fromJson(
              readProtocolObject(errorSource, '$path/error'),
              '$path/error',
            ),
    );
  }

  JsonObject toJson() => {
    'confirmationId': confirmationId,
    'status': status.name,
    'newVersionId': newVersionId,
    'replayed': replayed,
    'error': error?.toJson(),
  };
}
