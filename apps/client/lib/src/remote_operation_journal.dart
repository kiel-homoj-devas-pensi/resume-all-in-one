import 'dart:convert';
import 'dart:io';

import 'gateway_api_client.dart';

final class RemoteOperationRecord {
  const RemoteOperationRecord({
    required this.accountId,
    required this.clientRequestId,
    required this.idempotencyKey,
    required this.capability,
    required this.documentId,
    required this.baseVersionId,
    required this.status,
    this.usageOperationId,
    this.requestFingerprint,
  });
  final String accountId;
  final String clientRequestId;
  final String idempotencyKey;
  final RemoteAiCapability capability;
  final String? documentId;
  final String? baseVersionId;
  final String status;
  final String? usageOperationId;
  final String? requestFingerprint;
  bool get blocksNewRequest => !{
    'received',
    'released',
    'acknowledged',
    'expired',
    'completedWithoutCandidate',
  }.contains(status);
  RemoteOperationRecord withStatus(String value, String? usageId) =>
      RemoteOperationRecord(
        accountId: accountId,
        clientRequestId: clientRequestId,
        idempotencyKey: idempotencyKey,
        capability: capability,
        documentId: documentId,
        baseVersionId: baseVersionId,
        status: value,
        usageOperationId: usageId ?? usageOperationId,
        requestFingerprint: requestFingerprint,
      );
  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'clientRequestId': clientRequestId,
    'idempotencyKey': idempotencyKey,
    'capability': capability.name,
    'documentId': documentId,
    'baseVersionId': baseVersionId,
    'status': status,
    'usageOperationId': usageOperationId,
    if (requestFingerprint != null) 'requestFingerprint': requestFingerprint,
  };
  factory RemoteOperationRecord.fromJson(Map<String, dynamic> value) {
    if (value.keys.toSet().difference({
      'accountId',
      'clientRequestId',
      'idempotencyKey',
      'capability',
      'documentId',
      'baseVersionId',
      'status',
      'usageOperationId',
      'requestFingerprint',
    }).isNotEmpty) {
      throw const FormatException();
    }
    final record = RemoteOperationRecord(
      accountId: value['accountId'] as String,
      clientRequestId: value['clientRequestId'] as String,
      idempotencyKey: value['idempotencyKey'] as String,
      capability: RemoteAiCapability.values.byName(
        value['capability'] as String,
      ),
      documentId: value['documentId'] as String?,
      baseVersionId: value['baseVersionId'] as String?,
      status: value['status'] as String,
      usageOperationId: value['usageOperationId'] as String?,
      requestFingerprint: value['requestFingerprint'] as String?,
    );
    if ((record.requestFingerprint != null &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(record.requestFingerprint!)) ||
        record.accountId.isEmpty ||
        record.clientRequestId.isEmpty ||
        record.idempotencyKey.isEmpty ||
        !{
          'sent',
          'unknown',
          'reserved',
          'notFound',
          'pendingReconciliation',
          'committed',
          'released',
          'received',
          'completedWithoutCandidate',
          'acknowledged',
          'expired',
        }.contains(record.status)) {
      throw const FormatException();
    }
    return record;
  }
}

/// 请求之前保存恢复身份；不保存正文、密码、令牌或完整请求。
final class RemoteOperationJournal {
  RemoteOperationJournal({Future<Directory> Function()? rootDirectory})
    : _rootDirectory = rootDirectory;
  final Future<Directory> Function()? _rootDirectory;
  List<RemoteOperationRecord>? _records;
  Future<void> _writes = Future.value();
  Future<File?> _file() async {
    final root = _rootDirectory;
    if (root == null) return null;
    return File(
      '${(await root()).path}${Platform.pathSeparator}remote_operations_v1.json',
    );
  }

  Future<List<RemoteOperationRecord>> read() async {
    if (_records != null) return List.unmodifiable(_records!);
    final file = await _file();
    if (file == null || !await file.exists()) {
      _records = [];
      return const [];
    }
    if (await file.length() > 262144) throw const FormatException('操作记录过大');
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (decoded['schemaVersion'] != 1) throw const FormatException('未知操作记录版本');
    final records = (decoded['operations'] as List)
        .map(
          (value) =>
              RemoteOperationRecord.fromJson(value as Map<String, dynamic>),
        )
        .toList();
    if (records.map((record) => record.clientRequestId).toSet().length !=
        records.length) {
      throw const FormatException('重复动作身份');
    }
    _records = records;
    return List.unmodifiable(records);
  }

  Future<void> save(RemoteOperationRecord record) {
    final write = _writes.then((_) => _save(record));
    _writes = write.then((_) {}, onError: (Object error, StackTrace stack) {});
    return write;
  }

  Future<void> _save(RemoteOperationRecord record) async {
    final next =
        [...await read()]
            .where((old) => old.clientRequestId != record.clientRequestId)
            .toList()
          ..add(record);
    // 有界保存已终结记录；未解决的动作不会因数量上限被静默删除。
    while (next.length > 100 && next.any((entry) => !entry.blocksNewRequest)) {
      next.removeAt(next.indexWhere((entry) => !entry.blocksNewRequest));
    }
    if (next.length > 100) throw const FormatException('请先核对未完成操作');
    final file = await _file();
    if (file != null) {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'operations': next.map((entry) => entry.toJson()).toList(),
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    }
    _records = next;
  }

  Future<void> clear() async {
    final file = await _file();
    if (file != null && await file.exists()) await file.delete();
    _records = [];
  }
}
