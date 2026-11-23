import 'json_support.dart';

const currentAgentProtocolVersion = '0.1.0';

enum ToolAccess { read, proposeWrite }

enum ToolPermission { resumeRead, resumePatchProposal }

enum ToolResultStatus {
  success,
  requiresConfirmation,
  invalidCall,
  notFound,
  conflict,
  cancelled,
  timeout,
  failed,
}

enum ProtocolValidationSeverity { info, warning, error }

final class ToolDescriptor {
  ToolDescriptor({
    required this.name,
    required this.version,
    required JsonObject inputSchema,
    required JsonObject outputSchema,
    required this.permission,
    required this.access,
    required this.usesNetwork,
    required this.retryable,
    required this.timeoutMs,
    required List<String> auditFields,
  }) : inputSchema = freezeProtocolObject(inputSchema),
       outputSchema = freezeProtocolObject(outputSchema),
       auditFields = List<String>.unmodifiable(auditFields) {
    _requireText(name, 'name');
    _requireText(version, 'version');
    if (timeoutMs <= 0) {
      throw ArgumentError.value(timeoutMs, 'timeoutMs', '必须大于 0');
    }
    if (this.auditFields.any((field) => field.trim().isEmpty)) {
      throw ArgumentError.value(auditFields, 'auditFields', '审计字段不能为空');
    }
  }

  final String name;
  final String version;
  final JsonObject inputSchema;
  final JsonObject outputSchema;
  final ToolPermission permission;
  final ToolAccess access;
  final bool usesNetwork;
  final bool retryable;
  final int timeoutMs;
  final List<String> auditFields;

  factory ToolDescriptor.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {
        'name',
        'version',
        'inputSchema',
        'outputSchema',
        'permission',
        'access',
        'usesNetwork',
        'retryable',
        'timeoutMs',
        'auditFields',
      },
    );
    return ToolDescriptor(
      name: readProtocolString(json['name'], '$path/name'),
      version: readProtocolString(json['version'], '$path/version'),
      inputSchema: readProtocolObject(json['inputSchema'], '$path/inputSchema'),
      outputSchema: readProtocolObject(
        json['outputSchema'],
        '$path/outputSchema',
      ),
      permission: readProtocolEnum(
        json['permission'],
        '$path/permission',
        ToolPermission.values,
      ),
      access: readProtocolEnum(
        json['access'],
        '$path/access',
        ToolAccess.values,
      ),
      usesNetwork: readProtocolBool(json['usesNetwork'], '$path/usesNetwork'),
      retryable: readProtocolBool(json['retryable'], '$path/retryable'),
      timeoutMs: readProtocolInt(json['timeoutMs'], '$path/timeoutMs'),
      auditFields: readProtocolStringList(
        json['auditFields'],
        '$path/auditFields',
      ),
    );
  }

  JsonObject toJson() => {
    'name': name,
    'version': version,
    'inputSchema': deepCopyProtocolJson(inputSchema),
    'outputSchema': deepCopyProtocolJson(outputSchema),
    'permission': permission.name,
    'access': access.name,
    'usesNetwork': usesNetwork,
    'retryable': retryable,
    'timeoutMs': timeoutMs,
    'auditFields': auditFields.toList(),
  };
}

final class ToolCall {
  ToolCall({
    required this.callId,
    required this.toolName,
    required JsonObject arguments,
    required this.requestedBy,
    required this.idempotencyKey,
  }) : arguments = freezeProtocolObject(arguments) {
    _requireText(callId, 'callId');
    _requireText(toolName, 'toolName');
    _requireText(requestedBy, 'requestedBy');
    _requireText(idempotencyKey, 'idempotencyKey');
  }

  final String callId;
  final String toolName;
  final JsonObject arguments;
  final String requestedBy;
  final String idempotencyKey;

  factory ToolCall.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {
        'callId',
        'toolName',
        'arguments',
        'requestedBy',
        'idempotencyKey',
      },
    );
    return ToolCall(
      callId: readProtocolString(json['callId'], '$path/callId'),
      toolName: readProtocolString(json['toolName'], '$path/toolName'),
      arguments: readProtocolObject(json['arguments'], '$path/arguments'),
      requestedBy: readProtocolString(json['requestedBy'], '$path/requestedBy'),
      idempotencyKey: readProtocolString(
        json['idempotencyKey'],
        '$path/idempotencyKey',
      ),
    );
  }

  JsonObject toJson() => {
    'callId': callId,
    'toolName': toolName,
    'arguments': deepCopyProtocolJson(arguments),
    'requestedBy': requestedBy,
    'idempotencyKey': idempotencyKey,
  };
}

final class ProtocolValidationIssue {
  const ProtocolValidationIssue({
    required this.path,
    required this.severity,
    required this.ruleId,
    required this.message,
    required this.blocksAction,
  });

  final String path;
  final ProtocolValidationSeverity severity;
  final String ruleId;
  final String message;
  final bool blocksAction;

  factory ProtocolValidationIssue.fromJson(
    JsonObject json, [
    String path = r'$',
  ]) {
    requireProtocolFields(
      json,
      path,
      required: const {'path', 'severity', 'ruleId', 'message', 'blocksAction'},
    );
    return ProtocolValidationIssue(
      path: readProtocolString(json['path'], '$path/path', allowEmpty: true),
      severity: readProtocolEnum(
        json['severity'],
        '$path/severity',
        ProtocolValidationSeverity.values,
      ),
      ruleId: readProtocolString(json['ruleId'], '$path/ruleId'),
      message: readProtocolString(json['message'], '$path/message'),
      blocksAction: readProtocolBool(
        json['blocksAction'],
        '$path/blocksAction',
      ),
    );
  }

  JsonObject toJson() => {
    'path': path,
    'severity': severity.name,
    'ruleId': ruleId,
    'message': message,
    'blocksAction': blocksAction,
  };
}

final class ToolError {
  const ToolError({required this.code, required this.message});

  final String code;
  final String message;

  factory ToolError.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(json, path, required: const {'code', 'message'});
    return ToolError(
      code: readProtocolString(json['code'], '$path/code'),
      message: readProtocolString(json['message'], '$path/message'),
    );
  }

  JsonObject toJson() => {'code': code, 'message': message};
}

final class ToolAuditInfo {
  const ToolAuditInfo({
    required this.toolName,
    required this.toolVersion,
    required this.startedAt,
    required this.finishedAt,
    required this.offline,
    required this.idempotencyKey,
    required this.replayed,
  });

  final String toolName;
  final String toolVersion;
  final DateTime startedAt;
  final DateTime finishedAt;
  final bool offline;
  final String idempotencyKey;
  final bool replayed;

  factory ToolAuditInfo.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {
        'toolName',
        'toolVersion',
        'startedAt',
        'finishedAt',
        'offline',
        'idempotencyKey',
        'replayed',
      },
    );
    return ToolAuditInfo(
      toolName: readProtocolString(json['toolName'], '$path/toolName'),
      toolVersion: readProtocolString(json['toolVersion'], '$path/toolVersion'),
      startedAt: readProtocolTimestamp(json['startedAt'], '$path/startedAt'),
      finishedAt: readProtocolTimestamp(json['finishedAt'], '$path/finishedAt'),
      offline: readProtocolBool(json['offline'], '$path/offline'),
      idempotencyKey: readProtocolString(
        json['idempotencyKey'],
        '$path/idempotencyKey',
      ),
      replayed: readProtocolBool(json['replayed'], '$path/replayed'),
    );
  }

  JsonObject toJson() => {
    'toolName': toolName,
    'toolVersion': toolVersion,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'finishedAt': finishedAt.toUtc().toIso8601String(),
    'offline': offline,
    'idempotencyKey': idempotencyKey,
    'replayed': replayed,
  };
}

final class ToolResult {
  ToolResult({
    required this.callId,
    required this.status,
    JsonObject data = const {},
    List<ProtocolValidationIssue> validationIssues = const [],
    this.error,
    required this.auditInfo,
  }) : data = freezeProtocolObject(data),
       validationIssues = List<ProtocolValidationIssue>.unmodifiable(
         validationIssues,
       ) {
    _requireText(callId, 'callId');
  }

  final String callId;
  final ToolResultStatus status;
  final JsonObject data;
  final List<ProtocolValidationIssue> validationIssues;
  final ToolError? error;
  final ToolAuditInfo auditInfo;

  factory ToolResult.fromJson(JsonObject json, [String path = r'$']) {
    requireProtocolFields(
      json,
      path,
      required: const {
        'callId',
        'status',
        'data',
        'validationIssues',
        'error',
        'auditInfo',
      },
    );
    final issueSource = readProtocolList(
      json['validationIssues'],
      '$path/validationIssues',
    );
    final errorSource = json['error'];
    return ToolResult(
      callId: readProtocolString(json['callId'], '$path/callId'),
      status: readProtocolEnum(
        json['status'],
        '$path/status',
        ToolResultStatus.values,
      ),
      data: readProtocolObject(json['data'], '$path/data'),
      validationIssues: issueSource.indexed
          .map(
            (entry) => ProtocolValidationIssue.fromJson(
              readProtocolObject(
                entry.$2,
                '$path/validationIssues/${entry.$1}',
              ),
              '$path/validationIssues/${entry.$1}',
            ),
          )
          .toList(),
      error: errorSource == null
          ? null
          : ToolError.fromJson(
              readProtocolObject(errorSource, '$path/error'),
              '$path/error',
            ),
      auditInfo: ToolAuditInfo.fromJson(
        readProtocolObject(json['auditInfo'], '$path/auditInfo'),
        '$path/auditInfo',
      ),
    );
  }

  JsonObject toJson() => {
    'callId': callId,
    'status': status.name,
    'data': deepCopyProtocolJson(data),
    'validationIssues': validationIssues
        .map((issue) => issue.toJson())
        .toList(),
    'error': error?.toJson(),
    'auditInfo': auditInfo.toJson(),
  };
}

void _requireText(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, '不能为空');
  }
}
