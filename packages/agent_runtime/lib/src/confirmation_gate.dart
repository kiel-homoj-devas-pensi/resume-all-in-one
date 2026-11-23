import 'package:agent_protocol/agent_protocol.dart';
import 'package:resume_domain/resume_domain.dart';

final class ConfirmationGate {
  ConfirmationGate({
    required ResumeRepository repository,
    required DateTime Function() now,
    required String Function(String namespace) nextId,
  }) : _repository = repository,
       _now = now,
       _nextId = nextId;

  final ResumeRepository _repository;
  final DateTime Function() _now;
  final String Function(String namespace) _nextId;
  final Map<String, _PendingConfirmation> _pending = {};

  void clearHistory() {
    _pending.clear();
  }

  String propose({
    required ResumeVersion baseVersion,
    required ResumePatch patch,
  }) {
    final confirmationId = _nextId('confirmation');
    if (_pending.containsKey(confirmationId)) {
      throw StateError('确认 ID 重复');
    }
    _pending[confirmationId] = _PendingConfirmation(
      confirmationId: confirmationId,
      documentId: baseVersion.documentId,
      baseVersionId: baseVersion.id,
      patch: patch,
    );
    return confirmationId;
  }

  Future<ConfirmationResult> resolve(ConfirmationCommand command) async {
    final pendingConfirmation = _pending[command.confirmationId];
    if (pendingConfirmation == null) {
      return ConfirmationResult(
        confirmationId: command.confirmationId,
        status: ConfirmationStatus.notFound,
        replayed: false,
        error: const ToolError(
          code: 'confirmation_not_found',
          message: '确认票据不存在',
        ),
      );
    }

    final activeResolution = pendingConfirmation.active;
    if (activeResolution != null) {
      // 共享进行中的 Future，把同一票据的并发确认串行化为一次写入。
      await activeResolution;
      return resolve(command);
    }

    final resolvedConfirmation = pendingConfirmation.resolved;
    if (resolvedConfirmation != null) {
      if (resolvedConfirmation.decision == command.decision) {
        return ConfirmationResult(
          confirmationId: resolvedConfirmation.result.confirmationId,
          status: resolvedConfirmation.result.status,
          newVersionId: resolvedConfirmation.result.newVersionId,
          replayed: true,
          error: resolvedConfirmation.result.error,
        );
      }
      return ConfirmationResult(
        confirmationId: command.confirmationId,
        status: ConfirmationStatus.alreadyResolved,
        replayed: false,
        error: const ToolError(
          code: 'confirmation_already_resolved',
          message: '确认票据已经完成，不能更改决定',
        ),
      );
    }

    final resolutionFuture = _resolveFresh(pendingConfirmation, command);
    pendingConfirmation.active = resolutionFuture;
    try {
      return await resolutionFuture;
    } finally {
      if (identical(pendingConfirmation.active, resolutionFuture)) {
        pendingConfirmation.active = null;
      }
    }
  }

  Future<ConfirmationResult> _resolveFresh(
    _PendingConfirmation pending,
    ConfirmationCommand command,
  ) async {
    switch (command.decision) {
      case ConfirmationDecision.reject:
        final rejectionResult = ConfirmationResult(
          confirmationId: command.confirmationId,
          status: ConfirmationStatus.rejected,
          replayed: false,
        );
        pending.resolved = _ResolvedConfirmation(
          command.decision,
          rejectionResult,
        );
        return rejectionResult;
      case ConfirmationDecision.cancel:
        final cancellationResult = ConfirmationResult(
          confirmationId: command.confirmationId,
          status: ConfirmationStatus.cancelled,
          replayed: false,
        );
        pending.resolved = _ResolvedConfirmation(
          command.decision,
          cancellationResult,
        );
        return cancellationResult;
      case ConfirmationDecision.accept:
        return _accept(pending, command);
    }
  }

  Future<ConfirmationResult> _accept(
    _PendingConfirmation pending,
    ConfirmationCommand command,
  ) async {
    try {
      final resumeDocument = await _repository.findDocument(pending.documentId);
      final currentResumeVersion = await _repository.findCurrentVersion(
        pending.documentId,
      );
      if (resumeDocument == null || currentResumeVersion == null) {
        return _failedConfirmation(
          command,
          ConfirmationStatus.notFound,
          'resume_not_found',
          '目标简历或当前版本不存在',
        );
      }
      if (resumeDocument.currentVersionId != pending.baseVersionId ||
          currentResumeVersion.id != pending.baseVersionId) {
        return _failedConfirmation(
          command,
          ConfirmationStatus.conflict,
          'base_version_conflict',
          '当前版本已变化，请重新构建 Patch',
        );
      }

      final patchedResumeContent = pending.patch.apply(
        currentResumeVersion.content,
      );
      final confirmationTime = _clampTimestampToDocumentHistory(
        _now().toUtc(),
        resumeDocument.updatedAt.toUtc(),
      );
      final confirmedVersionId = _nextId('version');
      final confirmedResumeVersion = ResumeVersion(
        id: confirmedVersionId,
        documentId: resumeDocument.id,
        parentVersionId: currentResumeVersion.id,
        schemaVersion: patchedResumeContent.schemaVersion,
        content: patchedResumeContent,
        source: ResumeVersionSource.aiConfirmed,
        createdAt: confirmationTime,
      );
      final updatedResumeDocument = ResumeDocument(
        id: resumeDocument.id,
        title: resumeDocument.title,
        currentVersionId: confirmedResumeVersion.id,
        createdAt: resumeDocument.createdAt,
        updatedAt: confirmationTime,
        metadata: resumeDocument.metadata,
        extensions: resumeDocument.extensions,
      );

      await _repository.saveVersion(
        document: updatedResumeDocument,
        version: confirmedResumeVersion,
        expectedCurrentVersionId: currentResumeVersion.id,
      );

      final acceptedResult = ConfirmationResult(
        confirmationId: command.confirmationId,
        status: ConfirmationStatus.accepted,
        newVersionId: confirmedResumeVersion.id,
        replayed: false,
      );
      pending.resolved = _ResolvedConfirmation(
        command.decision,
        acceptedResult,
      );
      return acceptedResult;
    } on ResumeWriteConflict {
      return _failedConfirmation(
        command,
        ConfirmationStatus.conflict,
        'base_version_conflict',
        '当前版本已变化，请重新构建 Patch',
      );
    } on ResumeNotFound {
      return _failedConfirmation(
        command,
        ConfirmationStatus.notFound,
        'resume_not_found',
        '目标简历不存在',
      );
    } on PatchApplyException {
      return _failedConfirmation(
        command,
        ConfirmationStatus.invalid,
        'patch_invalid',
        'Patch 已失效，未写入任何内容',
      );
    } on ResumeValidationException {
      return _failedConfirmation(
        command,
        ConfirmationStatus.invalid,
        'validation_failed',
        'Patch 未通过验证，未写入任何内容',
      );
    } on Object {
      return _failedConfirmation(
        command,
        ConfirmationStatus.failed,
        'confirmation_failed',
        '确认写入失败，未提交结果',
      );
    }
  }

  ConfirmationResult _failedConfirmation(
    ConfirmationCommand command,
    ConfirmationStatus status,
    String code,
    String message,
  ) {
    return ConfirmationResult(
      confirmationId: command.confirmationId,
      status: status,
      replayed: false,
      error: ToolError(code: code, message: message),
    );
  }
}

final class _PendingConfirmation {
  _PendingConfirmation({
    required this.confirmationId,
    required this.documentId,
    required this.baseVersionId,
    required this.patch,
  });

  final String confirmationId;
  final String documentId;
  final String baseVersionId;
  final ResumePatch patch;
  Future<ConfirmationResult>? active;
  _ResolvedConfirmation? resolved;
}

final class _ResolvedConfirmation {
  const _ResolvedConfirmation(this.decision, this.result);

  final ConfirmationDecision decision;
  final ConfirmationResult result;
}

DateTime _clampTimestampToDocumentHistory(
  DateTime requestedTimestamp,
  DateTime latestDocumentTimestamp,
) {
  // 测试时钟或设备校时可能倒退，版本时间不能因此早于文档已有历史。
  return requestedTimestamp.isBefore(latestDocumentTimestamp)
      ? latestDocumentTimestamp
      : requestedTimestamp;
}
