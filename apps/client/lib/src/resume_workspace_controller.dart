import 'package:document_io/document_io.dart';
import 'package:entitlements/entitlements.dart';
import 'package:flutter/foundation.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_domain/resume_domain.dart';

import 'local_agent_check_service.dart';
import 'local_data_management_service.dart';
import 'local_resume_suggestion_service.dart';
import 'legal_consent_controller.dart';
import 'gateway_api_client.dart';
import 'cloud_sync_contracts.dart';
import 'remote_account_service.dart';
import 'remote_operation_journal.dart';
import 'remote_resume_ai_service.dart';
import 'remote_task_draft_store.dart';
import 'remote_review_cache.dart';
import 'resume_file_exporter.dart';
import 'resume_file_delivery.dart';
import 'resume_import_file_picker.dart';
import 'resume_word_store.dart';

enum SaveOutcome { saved, unchanged, blocked, failed }

enum DocumentLifecycleOutcome { completed, failed }

enum ResumeImportTarget { newDocument, currentDocument }

enum ImportPreparationOutcome { ready, cancelled, failed }

enum ImportCommitOutcome { completed, blocked, failed }

final class PendingResumeImport {
  const PendingResumeImport({
    required this.target,
    required this.preview,
    required this.suggestedTitle,
    this.documentId,
    this.baseVersionId,
  });

  final ResumeImportTarget target;
  final ResumeImportPreview preview;
  final String suggestedTitle;
  final String? documentId;
  final String? baseVersionId;
}

final class PreparedResumePdf {
  const PreparedResumePdf({
    required this.document,
    required this.version,
    required this.bytes,
    this.wordSourcePath,
  });

  final ResumeDocument document;
  final ResumeVersion version;
  final Uint8List bytes;
  final String? wordSourcePath;
}

/// 连接 Flutter UI 与本地仓储的 Application 边界。
///
/// 具体并发和 validation 异常在各操作中单独处理；其余基础设施异常到此为止，
/// 只转换成用户能采取行动的提示，不回显可能包含本机路径或用户内容的原始信息。
final class ResumeWorkspaceController extends ChangeNotifier {
  ResumeWorkspaceController({
    required ResumeRepository repository,
    required DriftAppSettingsRepository settingsRepository,
    required LocalAgentCheckService localAgentCheckService,
    LocalResumeSuggestionService? localResumeSuggestionService,
    required LocalDataManagementService localDataManagementService,
    required CapabilityAccessPolicy accessPolicy,
    required ResumeFileExporter fileExporter,
    required ResumeImportFilePicker importFilePicker,
    required RemoteAccountService remoteAccountService,
    required RemoteResumeAiService remoteResumeAiService,
    DateTime Function()? clock,
    DriftRemoteReviewRepository? reviewRepository,
    ResumeFileDelivery fileDelivery = const ResumeFileDelivery(),
    this.legalConsent,
  }) : _repository = repository,
       _settingsRepository = settingsRepository,
       _localAgentCheckService = localAgentCheckService,
       _localResumeSuggestionService = localResumeSuggestionService,
       _localDataManagementService = localDataManagementService,
       _accessPolicy = accessPolicy,
       _fileExporter = fileExporter,
       _importFilePicker = importFilePicker,
       _remoteAccountService = remoteAccountService,
       _remoteResumeAiService = remoteResumeAiService,
       _reviewRepository = reviewRepository,
       _fileDelivery = fileDelivery,
       _clock = clock ?? _utcNow {
    legalConsent?.addListener(_legalConsentChanged);
  }

  final ResumeRepository _repository;
  final DriftAppSettingsRepository _settingsRepository;
  final LocalAgentCheckService _localAgentCheckService;
  final LocalResumeSuggestionService? _localResumeSuggestionService;
  final LocalDataManagementService _localDataManagementService;
  final CapabilityAccessPolicy _accessPolicy;
  final ResumeFileExporter _fileExporter;
  final ResumeImportFilePicker _importFilePicker;
  final RemoteAccountService _remoteAccountService;
  final RemoteResumeAiService _remoteResumeAiService;
  final DateTime Function() _clock;
  final DriftRemoteReviewRepository? _reviewRepository;
  final ResumeFileDelivery _fileDelivery;
  final LegalConsentController? legalConsent;

  void _legalConsentChanged() {
    if (legalConsent?.canUseRemoteServices != true && networkEnabled) {
      networkEnabled = false;
      _networkGeneration++;
      _refreshCapabilityDecisions();
    }
    if (!_disposed) notifyListeners();
  }

  Future<ResumeFileDeliveryOutcome?> deliverSavedWord(
    SavedResumeWord word,
    ResumeFileDeliveryAction action,
  ) => _deliverSavedFile(word.path, action);

  Future<ResumeFileDeliveryOutcome?> deliverPreparedPdf(
    PreparedResumePdf prepared,
    ResumeFileDeliveryAction action,
  ) async {
    final path = await exportPreparedPdf(prepared);
    if (path == null) return null;
    return _deliverSavedFile(path, action);
  }

  Future<ResumeFileDeliveryOutcome?> _deliverSavedFile(
    String path,
    ResumeFileDeliveryAction action,
  ) async {
    _beginOperation();
    try {
      final result = await _fileDelivery.deliver(path, action);
      message = switch (result) {
        ResumeFileDeliveryOutcome.saved => '文件已保存到你选择的位置，应用内原件保留。',
        ResumeFileDeliveryOutcome.cancelled => '已取消另存，应用内原件保留。',
        ResumeFileDeliveryOutcome.shareOpened => '已打开系统分享选择器；是否发送由目标应用决定。',
      };
      return result;
    } on Object {
      formError = '系统文件交付未完成，应用内原件保留。若目标位置留下不完整副本，请删除后重试。';
      return null;
    } finally {
      _endOperation();
    }
  }

  String? _pendingRemoteOwner;
  DateTime? _pendingRemoteExpiresAt;
  RemoteReviewCache? get _reviewCache => _reviewRepository == null
      ? null
      : RemoteReviewCache(_reviewRepository, _clock);

  Future<void> _retainRemoteChange(PendingRemoteResumeChange change) async {
    _pendingRemoteExpiresAt = _clock().toUtc().add(const Duration(days: 7));
    _pendingRemoteOwner = _remoteAccountService.accountId;
    final owner = _pendingRemoteOwner;
    if (owner == null) return;
    try {
      final cache = _reviewCache;
      if (cache == null) return;
      await cache.save(owner, change);
      await _remoteResumeAiService.completeTaskForOperation(change.operationId);
    } on Object {
      latestRemoteWarnings = [
        ...latestRemoteWarnings,
        '候选未能保存到本机；当前可审阅，关闭应用后可能丢失。',
      ];
    }
  }

  Future<void> restoreRemoteReview() async {
    final owner = _remoteAccountService.accountId;
    if (owner == null || _reviewCache == null) return;
    try {
      final change = await _reviewCache!.restore(owner, _repository);
      if (change != null) {
        _pendingRemoteOwner = owner;
        _setPendingRemoteChange(change);
      } else {
        message = '没有可恢复的候选；已处理、过期或基础版本变化的候选不会重新应用。';
      }
    } on Object {
      formError = '保存的候选不可读取或已失效，简历与历史未改变。';
    }
  }

  List<ResumeDocument> documents = const [];
  List<ResumeVersion> versions = const [];
  List<ValidationIssue> validationIssues = const [];
  ResumeDocument? currentDocument;
  ResumeVersion? currentVersion;
  PendingResumeImport? pendingImport;
  LocalAgentCheckResult? latestLocalAgentCheck;
  PendingResumeSuggestion? pendingResumeSuggestion;
  PendingRemoteResumeChange? pendingRemoteResumeChange;
  RemoteAccountSnapshot remoteAccountSnapshot =
      RemoteAccountSnapshot.gatewayUnavailable();
  String? latestRemoteSummary;
  List<String> latestRemoteMissingInformation = const [];
  List<String> latestRemoteWarnings = const [];
  List<AccessDecision> capabilityDecisions = const [];
  bool networkEnabled = false;
  int _networkGeneration = 0;
  bool _disposed = false;
  bool remotePersonalDataWarningAcknowledged = false;
  bool isBusy = false;
  bool _isCommittingArchive = false;
  bool isReady = false;
  String? formError;
  bool accountVerificationOutcomeUnknown = false;
  String? message;
  int _idCounter = 0;
  LocalAgentCancellationToken? _activeLocalAgentCancellation;
  LocalAgentCancellationToken? _activeSuggestionCancellation;

  bool get isLocalAgentCheckRunning => _activeLocalAgentCancellation != null;

  bool get isSuggestionPreparationRunning =>
      _activeSuggestionCancellation != null;

  String? takeFeedback() {
    final pendingFeedbackMessage = formError ?? message;
    formError = null;
    message = null;
    return pendingFeedbackMessage;
  }

  Future<void> initialize() async {
    _beginOperation();
    try {
      documents = await _repository.listDocuments();
      networkEnabled =
          await _settingsRepository.getNetworkEnabled() &&
          (legalConsent == null || legalConsent!.canUseRemoteServices);
      remotePersonalDataWarningAcknowledged = await _settingsRepository
          .getRemotePersonalDataWarningAcknowledged();
      remoteAccountSnapshot = _remoteAccountService.snapshot;
      _refreshCapabilityDecisions();
      isReady = true;
      try {
        if (await _fileDelivery.consumeInterruptedSave()) {
          message = '上次系统另存被中断，请核对目标位置是否留下不完整副本；应用内原件仍可再次交付。';
        }
      } on Object {
        message = '上次文件交付状态暂时无法核对，请检查外部副本；本地资料仍可使用。';
      }
    } on Object {
      formError = '无法读取本地数据，请重新启动应用后再试。';
    } finally {
      _endOperation();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    legalConsent?.removeListener(_legalConsentChanged);
    _remoteResumeAiService.clearTransientState();
    _remoteAccountService.close();
    super.dispose();
  }

  Future<bool> createDocument({
    required String title,
    required String fullName,
  }) async {
    if (_isCommittingArchive) return false;
    await _discardPendingSuggestion();
    _discardPendingRemoteChange();
    if (_isCommittingArchive) return false;
    _beginOperation();
    try {
      final trimmedDocumentTitle = title.trim();
      if (trimmedDocumentTitle.isEmpty) {
        formError = '简历标题不能为空。';
        return false;
      }

      final creationTime = _clock().toUtc();
      final newDocumentId = _nextId('document');
      final initialVersionId = _nextId('version');
      final initialResumeContent = ResumeData(
        profile: ResumeProfile(
          id: _nextId('profile'),
          fullName: fullName.trim(),
          headline: '',
          email: '',
          phone: '',
          location: '',
        ),
      );
      final validationResult = const ResumeValidator().validate(
        initialResumeContent,
      );
      validationIssues = validationResult.issues;
      if (!validationResult.isValid) {
        formError = '请先修正阻止保存的问题。';
        return false;
      }

      final initialResumeVersion = ResumeVersion(
        id: initialVersionId,
        documentId: newDocumentId,
        parentVersionId: null,
        schemaVersion: currentResumeSchemaVersion,
        content: initialResumeContent,
        source: ResumeVersionSource.created,
        createdAt: creationTime,
      );
      final newResumeDocument = ResumeDocument(
        id: newDocumentId,
        title: trimmedDocumentTitle,
        currentVersionId: initialVersionId,
        createdAt: creationTime,
        updatedAt: creationTime,
      );
      await _repository.createDocument(newResumeDocument, initialResumeVersion);
      _showCommittedVersion(newResumeDocument, initialResumeVersion);
      await _refreshAfterCommit('简历已创建。');
      return true;
    } on Object {
      formError = '创建失败，本地数据未写入。';
      return false;
    } finally {
      _endOperation();
    }
  }

  Future<ImportPreparationOutcome> prepareTextImport() async {
    await _discardPendingSuggestion();
    _discardPendingRemoteChange();
    final importTargetDocument = currentDocument;
    final importTargetVersion = currentVersion;
    if (importTargetDocument != null && importTargetVersion == null) {
      formError = '当前简历尚未完整载入，无法开始导入。';
      notifyListeners();
      return ImportPreparationOutcome.failed;
    }

    _beginOperation();
    pendingImport = null;
    try {
      final selectedResumeFile = await _importFilePicker.pickResumeTextFile();
      if (selectedResumeFile == null) {
        return ImportPreparationOutcome.cancelled;
      }
      final importPreview = selectedResumeFile.createPreview(
        profileId: _nextId('profile'),
      );
      pendingImport = PendingResumeImport(
        target: importTargetDocument == null
            ? ResumeImportTarget.newDocument
            : ResumeImportTarget.currentDocument,
        preview: importPreview,
        suggestedTitle:
            importTargetDocument?.title ??
            _suggestImportTitle(selectedResumeFile.fileName),
        documentId: importTargetDocument?.id,
        baseVersionId: importTargetVersion?.id,
      );
      return ImportPreparationOutcome.ready;
    } on ResumeTextImportException catch (error) {
      formError = error.message;
      return ImportPreparationOutcome.failed;
    } on Object {
      formError = '无法读取所选文件，请确认文件仍然可访问后重试。';
      return ImportPreparationOutcome.failed;
    } finally {
      _endOperation();
    }
  }

  void cancelPendingImport() {
    if (pendingImport == null) {
      return;
    }
    pendingImport = null;
    notifyListeners();
  }

  Future<ImportCommitOutcome> confirmPendingImport({
    String? newDocumentTitle,
  }) async {
    if (_isCommittingArchive) return ImportCommitOutcome.blocked;
    final importToCommit = pendingImport;
    if (importToCommit == null) {
      formError = '没有等待确认的导入内容。';
      notifyListeners();
      return ImportCommitOutcome.failed;
    }
    final validationResult = const ResumeValidator().validate(
      importToCommit.preview.resume,
    );
    validationIssues = validationResult.issues;
    if (!validationResult.isValid) {
      formError = '导入内容未通过验证，不能写入本地数据。';
      notifyListeners();
      return ImportCommitOutcome.blocked;
    }

    final importTitle = importToCommit.target == ResumeImportTarget.newDocument
        ? (newDocumentTitle ?? '').trim()
        : importToCommit.suggestedTitle;
    if (importTitle.isEmpty) {
      formError = '简历标题不能为空。';
      notifyListeners();
      return ImportCommitOutcome.blocked;
    }

    _beginOperation();
    // 预览一旦进入提交阶段就不再复用，失败重试需要重新选择文件。
    pendingImport = null;
    try {
      if (importToCommit.target == ResumeImportTarget.newDocument) {
        await _createImportedDocument(
          importTitle,
          importToCommit.preview.resume,
        );
      } else {
        await _appendImportedVersion(importToCommit);
      }
      await _refreshAfterCommit(
        importToCommit.target == ResumeImportTarget.newDocument
            ? '已导入并创建简历。'
            : '已导入并保存为新版本。',
      );
      return ImportCommitOutcome.completed;
    } on ResumeWriteConflict {
      final targetDocumentId = importToCommit.documentId;
      if (targetDocumentId != null) {
        await _reloadAfterConflict(
          targetDocumentId,
          '导入期间简历已更新，本次导入未写入，请重新选择文件。',
        );
      }
      return ImportCommitOutcome.failed;
    } on Object {
      formError = '导入保存失败，原有数据保持不变。';
      return ImportCommitOutcome.failed;
    } finally {
      _endOperation();
    }
  }

  Future<void> openDocument(String documentId) async {
    if (_isCommittingArchive) return;
    await _discardPendingSuggestion();
    _discardPendingRemoteChange();
    if (_isCommittingArchive) return;
    _beginOperation();
    try {
      final storedDocument = await _repository.findDocument(documentId);
      final storedCurrentVersion = await _repository.findCurrentVersion(
        documentId,
      );
      if (storedDocument == null || storedCurrentVersion == null) {
        formError = '找不到这份简历，列表已重新加载。';
        documents = await _repository.listDocuments();
        return;
      }
      currentDocument = storedDocument;
      currentVersion = storedCurrentVersion;
      versions = await _repository.listVersions(documentId);
      try {
        await _remoteResumeAiService.restoreConversation(
          documentId,
          storedCurrentVersion.id,
          content: storedCurrentVersion.content,
        );
      } on Object {
        _remoteResumeAiService.clearDocumentConversation(documentId);
        message = '本地对话不可恢复，简历与历史未改变。';
      }
      latestLocalAgentCheck = null;
      validationIssues = const ResumeValidator()
          .validate(storedCurrentVersion.content)
          .issues;
    } on Object {
      formError = '读取简历失败，请稍后重试。';
    } finally {
      _endOperation();
    }
  }

  Future<void> closeDocument() async {
    if (_isCommittingArchive) return;
    await _discardPendingSuggestion();
    _discardPendingRemoteChange();
    if (_isCommittingArchive) return;
    currentDocument = null;
    currentVersion = null;
    versions = const [];
    latestLocalAgentCheck = null;
    validationIssues = const [];
    formError = null;
    message = null;
    notifyListeners();
  }

  Future<SaveOutcome> saveContent({
    required String title,
    required ResumeData content,
    ResumeVersionSource source = ResumeVersionSource.edited,
  }) async {
    if (_isCommittingArchive) return SaveOutcome.blocked;
    final currentResumeDocument = currentDocument;
    final baseResumeVersion = currentVersion;
    if (currentResumeDocument == null || baseResumeVersion == null) {
      formError = '没有可保存的当前简历。';
      notifyListeners();
      return SaveOutcome.failed;
    }

    await _discardPendingSuggestion();
    _discardPendingRemoteChange();
    if (_isCommittingArchive) return SaveOutcome.blocked;
    _beginOperation();
    try {
      final trimmedDocumentTitle = title.trim();
      if (trimmedDocumentTitle.isEmpty) {
        formError = '简历标题不能为空。';
        return SaveOutcome.blocked;
      }
      final validationResult = const ResumeValidator().validate(content);
      validationIssues = validationResult.issues;
      if (!validationResult.isValid) {
        formError = '请先修正阻止保存的问题。';
        return SaveOutcome.blocked;
      }

      // 普通编辑只记录内容变化；恢复还要记录用户采取的历史动作，
      // 即使恢复目标与当前内容相同，也追加 restored 快照。
      if (source != ResumeVersionSource.restored &&
          trimmedDocumentTitle == currentResumeDocument.title &&
          jsonDeepEquals(
            content.toJson(),
            baseResumeVersion.content.toJson(),
          )) {
        message = '没有需要保存的更改。';
        return SaveOutcome.unchanged;
      }

      final saveTime = _clock().toUtc();
      final newResumeVersion = ResumeVersion(
        id: _nextId('version'),
        documentId: currentResumeDocument.id,
        parentVersionId: baseResumeVersion.id,
        schemaVersion: content.schemaVersion,
        content: content,
        source: source,
        createdAt: saveTime,
      );
      final updatedResumeDocument = ResumeDocument(
        id: currentResumeDocument.id,
        title: trimmedDocumentTitle,
        currentVersionId: newResumeVersion.id,
        createdAt: currentResumeDocument.createdAt,
        updatedAt: saveTime,
        metadata: currentResumeDocument.metadata,
        extensions: currentResumeDocument.extensions,
      );
      // Repository 在同一事务里追加版本并推进指针，旧快照始终保持不可变。
      await _repository.saveVersion(
        document: updatedResumeDocument,
        version: newResumeVersion,
        expectedCurrentVersionId: baseResumeVersion.id,
      );
      _showCommittedVersion(updatedResumeDocument, newResumeVersion);
      await _refreshAfterCommit(
        source == ResumeVersionSource.restored
            ? '已恢复历史版本，并创建新的恢复版本。'
            : '已保存为新版本。',
      );
      return SaveOutcome.saved;
    } on ResumeWriteConflict {
      await _reloadAfterConflict(
        currentResumeDocument.id,
        '检测到更新冲突，本次更改未写入，请检查最新版本后重试。',
      );
      return SaveOutcome.failed;
    } on Object {
      formError = '保存失败，原版本保持不变。';
      return SaveOutcome.failed;
    } finally {
      _endOperation();
    }
  }

  Future<DocumentLifecycleOutcome> duplicateCurrent() async {
    if (_isCommittingArchive) return DocumentLifecycleOutcome.failed;
    final sourceDocument = currentDocument;
    final sourceVersion = currentVersion;
    if (sourceDocument == null || sourceVersion == null) {
      return DocumentLifecycleOutcome.failed;
    }
    await _discardPendingSuggestion();
    _discardPendingRemoteChange();
    if (_isCommittingArchive) return DocumentLifecycleOutcome.failed;
    _beginOperation();
    try {
      final copyTime = _clock().toUtc();
      final copiedDocumentId = _nextId('document');
      final copiedVersionId = _nextId('version');
      final copiedDocument = ResumeDocument(
        id: copiedDocumentId,
        title: '${sourceDocument.title}（副本）',
        currentVersionId: copiedVersionId,
        createdAt: copyTime,
        updatedAt: copyTime,
        metadata: sourceDocument.metadata,
        extensions: sourceDocument.extensions,
      );
      final copiedVersion = ResumeVersion(
        id: copiedVersionId,
        documentId: copiedDocumentId,
        parentVersionId: null,
        schemaVersion: sourceVersion.content.schemaVersion,
        content: sourceVersion.content,
        source: ResumeVersionSource.created,
        createdAt: copyTime,
        extensions: sourceVersion.extensions,
      );
      await _repository.createDocument(copiedDocument, copiedVersion);
      _showCommittedVersion(copiedDocument, copiedVersion);
      await _refreshAfterCommit('已复制简历。');
      return DocumentLifecycleOutcome.completed;
    } on Object {
      formError = '复制失败，原文档未改变。';
      return DocumentLifecycleOutcome.failed;
    } finally {
      _endOperation();
    }
  }

  Future<DocumentLifecycleOutcome> deleteDocument(String documentId) async {
    if (_isCommittingArchive) return DocumentLifecycleOutcome.failed;
    ResumeDocument? documentToDelete;
    for (final resumeDocument in documents) {
      if (resumeDocument.id == documentId) {
        documentToDelete = resumeDocument;
        break;
      }
    }
    if (documentToDelete == null) {
      formError = '文档已不存在。';
      notifyListeners();
      return DocumentLifecycleOutcome.failed;
    }
    final deletingCurrentDocument = currentDocument?.id == documentId;
    if (deletingCurrentDocument) {
      await _discardPendingSuggestion();
      _discardPendingRemoteChange();
    }
    if (_isCommittingArchive) return DocumentLifecycleOutcome.failed;
    _beginOperation();
    try {
      final documentWasDeleted = await _repository.deleteDocument(documentId);
      if (!documentWasDeleted) {
        formError = '文档已不存在。';
        return DocumentLifecycleOutcome.failed;
      }
      // 已提交的删除立即反映到内存，后续读取失败也不能把已删项留在列表。
      documents = documents
          .where((document) => document.id != documentId)
          .toList(growable: false);
      if (deletingCurrentDocument) {
        currentDocument = null;
        currentVersion = null;
        versions = const [];
        latestLocalAgentCheck = null;
        validationIssues = const [];
      }
      _remoteResumeAiService.clearDocumentConversation(documentId);
      if (pendingRemoteResumeChange?.documentId == documentId) {
        pendingRemoteResumeChange = null;
      }
      await _refreshAfterCommit('简历已删除。');
      return DocumentLifecycleOutcome.completed;
    } on Object {
      formError = '删除失败，文档未改变。';
      return DocumentLifecycleOutcome.failed;
    } finally {
      _endOperation();
    }
  }

  Future<DocumentLifecycleOutcome> restoreVersion(String versionId) async {
    if (_isCommittingArchive) return DocumentLifecycleOutcome.failed;
    final currentResumeDocument = currentDocument;
    final currentResumeVersion = currentVersion;
    if (currentResumeDocument == null || currentResumeVersion == null) {
      return DocumentLifecycleOutcome.failed;
    }
    _beginOperation();
    try {
      final versionToRestore = await _repository.findVersion(versionId);
      if (versionToRestore == null ||
          versionToRestore.documentId != currentResumeDocument.id) {
        formError = '找不到要恢复的历史版本。';
        return DocumentLifecycleOutcome.failed;
      }
      final restoreOutcome = await saveContent(
        title: currentResumeDocument.title,
        content: versionToRestore.content,
        source: ResumeVersionSource.restored,
      );
      if (restoreOutcome != SaveOutcome.saved) {
        return DocumentLifecycleOutcome.failed;
      }
      return DocumentLifecycleOutcome.completed;
    } on Object {
      formError = '恢复失败，当前版本保持不变。';
      return DocumentLifecycleOutcome.failed;
    } finally {
      _endOperation();
    }
  }

  Future<String?> exportCurrent(ResumeExportFormat format) async {
    final documentToExport = currentDocument;
    final versionToExport = currentVersion;
    if (documentToExport == null || versionToExport == null) {
      formError = '没有可导出的当前简历。';
      notifyListeners();
      return null;
    }

    _beginOperation();
    try {
      final exportedFile = await _fileExporter.export(
        document: documentToExport,
        version: versionToExport,
        format: format,
      );
      message = '已导出到 ${exportedFile.path}';
      return exportedFile.path;
    } on ResumeValidationException catch (error) {
      validationIssues = error.result.issues;
      formError = '当前版本未通过验证，无法导出。';
      return null;
    } on Object {
      formError = '导出失败，未创建可用文件。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<ResumeFileDeliveryOutcome?> deliverCurrentText(
    ResumeExportFormat format,
  ) async {
    final path = await exportCurrent(format);
    if (path == null) return null;
    return _deliverSavedFile(path, ResumeFileDeliveryAction.saveAs);
  }

  Future<SavedResumeWord?> openCurrentWord() async {
    final version = currentVersion;
    if (version == null || isBusy) return null;
    _beginOperation();
    try {
      return await _fileExporter.wordStore.open(version);
    } on ResumeValidationException catch (error) {
      validationIssues = error.result.issues;
      formError = '已保存的简历未通过检查，不能生成 Word。';
      return null;
    } on FormatException catch (error) {
      formError = 'Word 文稿无法打开：${error.message}';
      return null;
    } on Object {
      formError = 'Word 文稿打开失败，已有文件未改变。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<SavedResumeWord?> saveWord(
    ResumeVersion source,
    ResumeWordDocument content,
  ) async {
    if (isBusy) return null;
    _beginOperation();
    try {
      return await _fileExporter.wordStore.save(source, content);
    } on FormatException catch (error) {
      formError = 'Word 未保存：${error.message} 当前修改仍保留在页面中。';
      return null;
    } on Object {
      formError = 'Word 保存失败，请重试。已有文稿和简历版本未改变。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<PreparedResumePdf?> convertWordToPdf(
    SavedResumeWord word,
    ResumeDocument document,
    ResumeVersion version,
  ) async {
    if (isBusy) return null;
    _beginOperation();
    try {
      final bytes = await _fileExporter.wordStore.convertToPdf(word);
      return PreparedResumePdf(
        document: document,
        version: version,
        bytes: bytes,
        wordSourcePath: word.path,
      );
    } on FormatException catch (error) {
      formError = 'Word 转 PDF 失败：${error.message}';
      return null;
    } on Object {
      formError = 'Word 转 PDF 失败，Word 文稿仍保留在本机。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<PreparedResumePdf?> prepareCurrentPdf() async {
    final documentToPreview = currentDocument;
    final versionToPreview = currentVersion;
    if (documentToPreview == null || versionToPreview == null) {
      formError = '没有可预览的当前简历。';
      notifyListeners();
      return null;
    }

    _beginOperation();
    try {
      final pdfBytes = await _fileExporter.buildPdfBytes(versionToPreview);
      return PreparedResumePdf(
        document: documentToPreview,
        version: versionToPreview,
        bytes: pdfBytes,
      );
    } on ResumeValidationException catch (error) {
      validationIssues = error.result.issues;
      formError = '当前已保存版本未通过验证，无法生成 PDF。';
      return null;
    } on Object {
      formError = 'PDF 生成失败，未创建文件。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<String?> exportPreparedPdf(PreparedResumePdf preparedPdf) async {
    _beginOperation();
    try {
      final exportedFile = preparedPdf.wordSourcePath != null
          ? await _fileExporter.wordStore.savePdf(
              preparedPdf.wordSourcePath!,
              preparedPdf.bytes,
            )
          : await _fileExporter.exportPdf(
              document: preparedPdf.document,
              version: preparedPdf.version,
              pdfBytes: preparedPdf.bytes,
            );
      message = '已导出到 ${exportedFile.path}';
      return exportedFile.path;
    } on Object {
      formError = 'PDF 导出失败，预览内容未改变。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<bool> setNetworkEnabled(bool enabled) async {
    if (enabled &&
        legalConsent != null &&
        !legalConsent!.canUseRemoteServices) {
      formError = legalConsent!.blockedReason;
      notifyListeners();
      return false;
    }
    if (_isCommittingArchive) return false;
    _beginOperation();
    try {
      await _settingsRepository.setNetworkEnabled(enabled);
      networkEnabled = enabled;
      _networkGeneration++;
      _refreshCapabilityDecisions();
      message = enabled ? '已记录允许联网偏好。' : '联网已关闭。';
      return true;
    } on Object {
      formError = '隐私设置保存失败，原设置保持不变。';
      return false;
    } finally {
      _endOperation();
    }
  }

  Future<bool> setRemotePersonalDataWarningAcknowledged(
    bool acknowledged,
  ) async {
    if (_isCommittingArchive) return false;
    _beginOperation();
    try {
      await _settingsRepository.setRemotePersonalDataWarningAcknowledged(
        acknowledged,
      );
      remotePersonalDataWarningAcknowledged = acknowledged;
      message = acknowledged ? '已记录联网 AI 隐私提醒。' : '已撤销联网 AI 隐私提醒确认。';
      return true;
    } on Object {
      formError = '隐私提醒状态保存失败，原设置保持不变。';
      return false;
    } finally {
      _endOperation();
    }
  }

  bool get supportsGuestAi => _remoteAccountService.supportsGuest;

  bool get supportsAccountLifecycle => _remoteAccountService.supportsLifecycle;

  Future<CloudSyncOptions?> readCloudOptions() async {
    if (!_requireNetworkEnabled()) return null;
    final generation = _networkGeneration;
    try {
      final options = await _remoteAccountService.readCloudOptions();
      if (_disposed || !networkEnabled || generation != _networkGeneration) {
        return null;
      }
      return options;
    } on GatewayApiException catch (error) {
      if (!_disposed && networkEnabled && generation == _networkGeneration) {
        // 此入口不使用登录，失败不能撤销当前账号会话。
        formError = switch (error.code) {
          'gateway_not_configured' => '服务地址未配置，无法读取云政策。',
          'cloud_api_not_supported' => '当前服务不支持云政策查询。',
          _ => '无法核验云政策，请稍后主动重新查询。',
        };
      }
      return null;
    } on Object {
      if (!_disposed && networkEnabled && generation == _networkGeneration) {
        formError = '无法读取云政策，请稍后主动重新查询。';
      }
      return null;
    }
  }

  Future<bool?> readDevelopmentSmsMode() async {
    if (!_requireNetworkEnabled()) return null;
    try {
      return await _remoteAccountService.readDevelopmentSmsMode();
    } on GatewayApiException catch (error) {
      _setGatewayFailure(error);
      return null;
    } on Object {
      formError = '无法读取账户服务配置';
      return null;
    }
  }

  Future<GatewayVerification?> requestAccountVerification(
    String phone,
    String purpose,
  ) async {
    accountVerificationOutcomeUnknown = false;
    if (!_requireNetworkEnabled()) return null;
    _beginOperation();
    try {
      return await _remoteAccountService.requestVerification(phone, purpose);
    } on RemoteAccountInputException catch (error) {
      formError = error.message;
      return null;
    } on GatewayApiException catch (error) {
      switch (error.code) {
        case 'verification_delivery_unknown':
          accountVerificationOutcomeUnknown = true;
          formError = '短信发送结果无法确认，本次验证码已作废；请勿连续重复发送。';
        case 'client_timeout' ||
            'gateway_unreachable' ||
            'storage_unavailable' ||
            'operation_outcome_unknown':
          accountVerificationOutcomeUnknown = true;
          formError = '验证码请求结果无法确认，请等待并检查网络；不会自动重发，请勿连续重复发送。';
        case 'verification_delivery_unavailable':
          formError = '验证码暂未发出，请稍后重新请求。';
        default:
          _setGatewayFailure(error);
      }
      return null;
    } on Object {
      accountVerificationOutcomeUnknown = true;
      formError = '验证码请求未完成，请勿连续重复发送';
      return null;
    } finally {
      _endOperation();
    }
  }

  bool get supportsRecoveryCodes => _remoteAccountService.supportsRecoveryCodes;

  bool get supportsRightsRequests =>
      _remoteAccountService.supportsRightsRequests;

  Future<GatewayRightsRequestReceipt?> issueRightsRequestReceipt(
    String currentPassword,
  ) async {
    if (!_requireNetworkEnabled()) return null;
    _beginOperation();
    try {
      return await _remoteAccountService.issueRightsRequestReceipt(
        currentPassword,
      );
    } on RemoteAccountInputException catch (error) {
      formError = error.message;
      return null;
    } on GatewayApiException catch (error) {
      _setGatewayFailure(error);
      return null;
    } on Object {
      formError = '账号归属核验未完成。仍可通过公开邮箱提出请求，不要发送密码、短信验证码或恢复码。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<String?> createAccountRecoveryCode(String currentPassword) async {
    if (!_requireNetworkEnabled()) return null;
    _beginOperation();
    try {
      return await _remoteAccountService.createRecoveryCode(currentPassword);
    } on RemoteAccountInputException catch (error) {
      formError = error.message;
      return null;
    } on GatewayApiException catch (error) {
      _setGatewayFailure(error);
      return null;
    } on Object {
      formError = '恢复码结果未能确认。账号仍保留；请登录后在安全页重新设置，旧码可能已失效。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<bool> registerVerifiedAccount(
    String phone,
    String password,
    String challengeId,
    String code,
  ) => _authenticateRemoteAccount(
    operation: () => _remoteAccountService.registerVerified(
      phone,
      password,
      challengeId,
      code,
    ),
    successMessage: '账号已创建并登录。',
  );

  Future<bool> manageRemoteAccount(
    GatewayAccountAction action,
    Map<String, Object?> fields,
  ) => _authenticateRemoteAccount(
    operation: () => _remoteAccountService.manageAccount(action, fields),
    successMessage: switch (action) {
      GatewayAccountAction.revoke =>
        fields['allDevices'] == true ? '已撤销全部设备会话。' : '已撤销当前会话。',
      GatewayAccountAction.changePassword ||
      GatewayAccountAction.resetPassword => '密码已更新，原会话已撤销，请重新登录。',
      GatewayAccountAction.deactivate => '账户已停用，本地简历仍保留。',
    },
  );

  Future<bool> registerRemoteAccount({
    required String phoneE164,
    required String password,
  }) {
    return _authenticateRemoteAccount(
      operation: () => _remoteAccountService.registerAndSignIn(
        phoneE164: phoneE164,
        password: password,
      ),
      successMessage: '开发账号已创建并登录。',
    );
  }

  Future<bool> startGuestAi() => _authenticateRemoteAccount(
    operation: _remoteAccountService.startGuest,
    successMessage: '已进入游客体验；每月可获得1份基础生成和1份岗位优化候选。',
  );

  Future<bool> signInRemoteAccount({
    required String phoneE164,
    required String password,
  }) {
    return _authenticateRemoteAccount(
      operation: () => _remoteAccountService.signIn(
        phoneE164: phoneE164,
        password: password,
      ),
      successMessage: '已登录账号。',
    );
  }

  Future<List<RemoteOperationRecord>> readRemoteOperations() =>
      _remoteAccountService.readOperations();

  Future<GatewayOperationStatus?> queryRemoteOperation(
    RemoteOperationRecord record,
  ) async {
    if (!_requireNetworkEnabled()) return null;
    _beginOperation();
    try {
      return await _remoteAccountService.queryOperation(record);
    } on GatewayApiException catch (error) {
      _setGatewayFailure(error);
      return null;
    } on Object {
      formError = '查询或记录状态失败；原操作仍保留，未再次调用模型。';
      return null;
    } finally {
      _endOperation();
    }
  }

  void signOutRemoteAccount() {
    _remoteAccountService.signOutLocally();
    _remoteResumeAiService.clearTransientState();
    remoteAccountSnapshot = _remoteAccountService.snapshot;
    pendingRemoteResumeChange = null;
    latestRemoteSummary = null;
    latestRemoteMissingInformation = const [];
    latestRemoteWarnings = const [];
    message = '已退出账号，本机未保存登录令牌。';
    notifyListeners();
  }

  Future<bool> refreshRemoteAccess() async {
    _remoteAccountService.invalidateAccess();
    remoteAccountSnapshot = _remoteAccountService.snapshot;
    if (!_requireNetworkEnabled()) {
      notifyListeners();
      return false;
    }
    _beginOperation();
    try {
      await _remoteAccountService.refreshAccess();
      remoteAccountSnapshot = _remoteAccountService.snapshot;
      message = '账号套餐与用量已刷新。';
      return true;
    } on GatewayApiException catch (error) {
      _setGatewayFailure(error);
      return false;
    } on Object {
      formError = '无法刷新账号状态，请稍后重试。';
      return false;
    } finally {
      remoteAccountSnapshot = _remoteAccountService.snapshot;
      _endOperation();
    }
  }

  String createAiTaskId() => _remoteResumeAiService.createTaskId();

  Future<List<RemoteTaskDraft>> readUnfinishedAiTasks() =>
      _remoteResumeAiService.unfinishedTasks();

  Future<void> discardUnfinishedAiTask(RemoteTaskDraft task) async {
    if (isBusy || task.owner != remoteAccountId) return;
    _beginOperation();
    try {
      await _remoteResumeAiService.taskDraftStore.remove(task.owner, task.id);
      message = '已移除本机任务草稿；原请求和用量记录保留。';
    } on Object {
      formError = '本机任务草稿移除失败，请重试。';
    } finally {
      _endOperation();
    }
  }

  BasicResumeComposeDraft restoreBasicTaskMaterial(RemoteTaskDraft task) =>
      _remoteResumeAiService.restoreComposeMaterial(task);

  /// Returns true only when it is safe to reopen material for a fresh submission.
  /// An unresolved request is retrieved by its original identity, never regenerated.
  Future<bool> recoverUnfinishedAiTask(RemoteTaskDraft task) async {
    if (isBusy || !_requireNetworkEnabled() || task.owner != remoteAccountId) {
      return false;
    }
    if (task.kind == 'optimize' &&
        (currentDocument?.id != task.documentId ||
            currentVersion?.id != task.baseVersionId)) {
      formError = '原任务的简历版本已变化；不会把旧任务写入当前版本。';
      notifyListeners();
      return false;
    }
    final records = await _remoteAccountService.readOperations();
    final record = records
        .where((e) => e.clientRequestId == task.clientRequestId)
        .firstOrNull;
    if (record == null ||
        {'released', 'completedWithoutCandidate'}.contains(record.status)) {
      return true;
    }
    _beginOperation();
    latestRemoteMissingInformation = const [];
    try {
      final response = await _remoteAccountService.recoverOperationResult(
        record,
      );
      if (remoteAccountId != task.owner) return false;
      if (task.kind == 'compose') {
        final material = _remoteResumeAiService.restoreComposeMaterial(
          task,
          forResultRecovery: true,
        );
        final change = await _remoteResumeAiService.prepareBasicResumeCompose(
          material,
          recoveredResponse: response,
        );
        _setPendingRemoteChange(change);
        await _retainRemoteChange(change);
      } else {
        final preparation = await _remoteResumeAiService
            .prepareTargetedOptimization(
              document: currentDocument!,
              version: currentVersion!,
              targetJobTitle: task.material['targetJobTitle'] as String,
              jobDescription: task.material['jobDescription'] as String,
              userInstruction: task.material['userInstruction'] as String,
              sharePersonalData: task.submittedPersonalDataShared,
              recoveredResponse: response,
            );
        latestRemoteSummary = preparation.summary;
        latestRemoteMissingInformation = preparation.missingInformation;
        latestRemoteWarnings = preparation.warnings;
        if (preparation.pendingChange == null) return true;
        _setPendingRemoteChange(preparation.pendingChange!);
        await _retainRemoteChange(preparation.pendingChange!);
      }
      return false;
    } on RemoteResumeAiQuestions catch (questions) {
      latestRemoteSummary = questions.summary;
      latestRemoteMissingInformation = questions.questions;
      latestRemoteWarnings = questions.warnings;
      return true;
    } on GatewayApiException catch (error) {
      _setGatewayFailure(error);
      return false;
    } on RemoteAccountInputException catch (error) {
      formError = error.message;
      return false;
    } on Object {
      formError = '原任务暂时无法恢复，已保留材料；没有重新生成。';
      return false;
    } finally {
      _endOperation();
    }
  }

  Future<PendingRemoteResumeChange?> prepareBasicRemoteResume(
    BasicResumeComposeDraft draft, {
    String? taskId,
  }) async {
    if (pendingRemoteResumeChange == null) await restoreRemoteReview();
    if (!_canUseRemoteCapability(RemoteAiCapability.basicResumeCompose)) {
      return null;
    }
    _beginOperation();
    latestRemoteMissingInformation = const [];
    try {
      final preparedChange = await _remoteResumeAiService
          .prepareBasicResumeCompose(draft, taskId: taskId);
      _setPendingRemoteChange(preparedChange);
      await _retainRemoteChange(preparedChange);
      await _refreshRemoteSnapshotWithoutDiscardingResult();
      return preparedChange;
    } on RemoteResumeAiQuestions catch (questions) {
      latestRemoteSummary = questions.summary;
      latestRemoteMissingInformation = questions.questions;
      latestRemoteWarnings = questions.warnings;
      message = '请补充并确认材料后再生成；本轮未写入简历。';
      await _refreshRemoteSnapshotWithoutDiscardingResult();
      return null;
    } on RemoteResumeAiInputException catch (error) {
      formError = error.message;
      return null;
    } on RemoteResumeAiResponseException {
      formError = '远程结果未通过本地安全校验，未进入审阅。';
      return null;
    } on GatewayApiException catch (error) {
      if (error.code == 'quota_exhausted') {
        await _refreshRemoteSnapshotWithoutDiscardingResult();
      }
      _setGatewayFailure(error);
      return null;
    } on Object {
      formError = '基础简历生成失败，本地数据未改变。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<RemoteOptimizationPreparation?> prepareTargetedRemoteOptimization({
    required String targetJobTitle,
    required String jobDescription,
    required String userInstruction,
    Set<RemotePersonalDataField> selectedPersonalFields = const {},
    bool confirmedInputSharing = false,
    bool? sharePersonalData,
    String? taskId,
  }) {
    return _prepareCurrentRemoteOptimization(
      capability: RemoteAiCapability.targetedResumeOptimization,
      operation: (document, version) =>
          _remoteResumeAiService.prepareTargetedOptimization(
            document: document,
            version: version,
            taskId: taskId,
            targetJobTitle: targetJobTitle,
            jobDescription: jobDescription,
            userInstruction: userInstruction,
            confirmedInputSharing: confirmedInputSharing,
            sharePersonalData: sharePersonalData,
            selectedPersonalFields: selectedPersonalFields,
          ),
    );
  }

  Future<RemoteOptimizationPreparation?> prepareRemoteConversationTurn({
    required String targetJobTitle,
    required String jobDescription,
    required String userMessage,
    Set<RemotePersonalDataField> selectedPersonalFields = const {},
    bool confirmedInputSharing = false,
    bool? sharePersonalData,
  }) {
    return _prepareCurrentRemoteOptimization(
      capability: RemoteAiCapability.resumeOptimizationConversation,
      operation: (document, version) =>
          _remoteResumeAiService.prepareConversationTurn(
            document: document,
            version: version,
            targetJobTitle: targetJobTitle,
            jobDescription: jobDescription,
            userMessage: userMessage,
            confirmedInputSharing: confirmedInputSharing,
            sharePersonalData: sharePersonalData,
            selectedPersonalFields: selectedPersonalFields,
          ),
    );
  }

  List<RemoteConversationRound> currentRemoteConversation() {
    final documentId = currentDocument?.id;
    if (documentId == null) {
      return const [];
    }
    return _remoteResumeAiService.conversationFor(documentId);
  }

  String? get remoteAccountId => _remoteAccountService.accountId;
  int get remoteDraftGeneration =>
      _remoteAccountService.sessionGeneration +
      _remoteResumeAiService.transientGeneration;

  RemoteWritingContext currentWritingContext() {
    final document = currentDocument;
    final version = currentVersion;
    if (document == null || version == null) return RemoteWritingContext();
    return _remoteResumeAiService.writingContextFor(document.id, version.id);
  }

  Future<bool> confirmWritingContext(RemoteWritingContext context) async {
    final document = currentDocument;
    final version = currentVersion;
    if (isBusy ||
        pendingRemoteResumeChange != null ||
        document == null ||
        version == null) {
      return false;
    }
    _beginOperation();
    try {
      final persisted = await _remoteResumeAiService.confirmWritingContext(
        document: document,
        version: version,
        context: context,
      );
      message = persisted
          ? '已确认事实与长期要求，仅用于这份简历当前版本的AI任务，本机保留最多七天。'
          : '已确认，本次应用会话可用；关闭应用后需重新确认。';
      return true;
    } on RemoteResumeAiInputException catch (error) {
      formError = error.message;
      return false;
    } on Object {
      formError = 'AI材料确认未完成，请重新查看；简历与历史未改变。';
      return false;
    } finally {
      _endOperation();
    }
  }

  Future<bool> acceptPendingRemoteChange({
    bool confirmedSemanticReview = false,
  }) async {
    if (isBusy || _isCommittingArchive) return false;
    final changeToAccept = pendingRemoteResumeChange;
    if (changeToAccept == null) {
      formError = '没有等待确认的远程建议。';
      notifyListeners();
      return false;
    }
    if (changeToAccept.requiresSemanticReview && !confirmedSemanticReview) {
      formError = '请先审阅并明确确认改写含义、事实和修改范围，候选尚未写入。';
      notifyListeners();
      return false;
    }
    if (_pendingRemoteExpiresAt != null &&
        !_pendingRemoteExpiresAt!.isAfter(_clock().toUtc())) {
      await rejectPendingRemoteChange();
      formError = '候选已超过七天保留期，未写入简历。';
      notifyListeners();
      return false;
    }
    _beginOperation();
    try {
      final owner = _pendingRemoteOwner;
      if (owner != null &&
          _reviewRepository != null &&
          await _reviewRepository.hasAccepted(
            remoteReviewId(owner, changeToAccept.operationId),
          )) {
        pendingRemoteResumeChange = null;
        message = '这份候选已确认保存，不会重复写入。';
        documents = await _repository.listDocuments();
        return true;
      }
      final reappliedContent = changeToAccept.patch.apply(
        changeToAccept.baseContent,
      );
      if (!jsonDeepEquals(
        reappliedContent.toJson(),
        changeToAccept.proposedContent.toJson(),
      )) {
        pendingRemoteResumeChange = null;
        formError = '远程建议与审阅内容不一致，已拒绝写入。';
        return false;
      }
      if (changeToAccept.target == RemoteResumeChangeTarget.newDocument) {
        await _createRemoteDocument(changeToAccept);
      } else {
        await _appendRemoteVersion(changeToAccept);
      }
      pendingRemoteResumeChange = null;
      await _refreshAfterCommit('远程建议已确认，并保存为新的 AI 确认版本。');
      return true;
    } on ResumeWriteConflict {
      pendingRemoteResumeChange = null;
      final documentId = changeToAccept.documentId;
      if (documentId != null) {
        await _reloadAfterConflict(documentId, '简历版本已变化，过期的远程建议未写入。');
      } else {
        formError = '简历版本已变化，过期的远程建议未写入。';
      }
      return false;
    } on PatchApplyException {
      pendingRemoteResumeChange = null;
      formError = '远程建议已失效，未写入任何内容。';
      return false;
    } on ResumeValidationException catch (error) {
      pendingRemoteResumeChange = null;
      validationIssues = error.result.issues;
      formError = '远程建议未通过最终校验，未写入任何内容。';
      return false;
    } on Object {
      formError = '远程建议保存失败，建议仍保留，可再次确认或拒绝。';
      return false;
    } finally {
      _endOperation();
    }
  }

  Future<bool> rejectPendingRemoteChange() async {
    if (pendingRemoteResumeChange == null) {
      return true;
    }
    try {
      final owner = _pendingRemoteOwner;
      if (owner != null) {
        await _reviewRepository?.discardReview(
          remoteReviewId(owner, pendingRemoteResumeChange!.operationId),
        );
      }
    } on Object {
      formError = '拒绝记录未能保存，候选仍保留，请重试；简历未改变。';
      notifyListeners();
      return false;
    }
    pendingRemoteResumeChange = null;
    message = '远程建议已拒绝，本地简历未改变。';
    notifyListeners();
    return true;
  }

  Future<LocalDataExportResult?> exportAllLocalData() async {
    if (isBusy) return null;
    _beginOperation();
    try {
      final exportResult = await _localDataManagementService.exportAll();
      message = '本地数据档案已生成在应用内，尚未另存到你选择的位置。';
      return exportResult;
    } on LocalDataExportLimitException catch (error) {
      formError = error.message;
      return null;
    } on LocalDataArchiveException catch (error) {
      formError = error.message;
      return null;
    } on Object {
      formError = '全部数据导出失败，未创建可用备份。';
      return null;
    } finally {
      _endOperation();
    }
  }

  LocalDataArchive? pendingLocalDataRestore;

  Future<LocalDataArchive?> prepareLocalDataRestore() async {
    if (isBusy) return null;
    _beginOperation();
    pendingLocalDataRestore = null;
    try {
      final archive = await _localDataManagementService.prepareRestore();
      if (archive == null) return null;
      if (archive.resumes.isEmpty) {
        formError = '档案中没有可恢复的简历。';
        return null;
      }
      pendingLocalDataRestore = archive;
      return archive;
    } on LocalDataArchiveException catch (error) {
      formError = error.message;
      return null;
    } on FormatException catch (error) {
      formError = error.message;
      return null;
    } on Object {
      formError = '档案读取未完成，现有资料保持不变。';
      return null;
    } finally {
      _endOperation();
    }
  }

  void cancelLocalDataRestore() => pendingLocalDataRestore = null;

  Future<bool> confirmLocalDataRestore(LocalDataArchive archive) async {
    if (isBusy || !identical(archive, pendingLocalDataRestore)) return false;
    _isCommittingArchive = true;
    _beginOperation();
    var committed = false;
    try {
      await _localDataManagementService.restoreResumes(archive);
      committed = true;
      pendingLocalDataRestore = null;
      documents = await _repository.listDocuments();
      message =
          '已恢复 ${archive.summary.documentCount} 份简历与 ${archive.summary.versionCount} 个历史版本；设置和联网同意保持不变。';
      return true;
    } on LocalDataRestoreConflict {
      formError = '档案中的文档或版本已在本机存在，整份恢复已拒绝；现有资料未改变。';
      return false;
    } on LocalDataRestoreValidationException {
      formError = '档案未通过恢复校验，现有资料未改变。';
      return false;
    } on Object {
      if (committed) {
        message = '档案已恢复，但列表刷新未完成，请重新打开应用核对；不要重复恢复。';
        return true;
      }
      formError = '档案恢复失败，现有资料保持不变，请检查存储空间后重试。';
      return false;
    } finally {
      _isCommittingArchive = false;
      _endOperation();
    }
  }

  Future<ResumeFileDeliveryOutcome?> deliverAllLocalData() async {
    final archive = await exportAllLocalData();
    if (archive == null) return null;
    return _deliverSavedFile(
      archive.file.path,
      ResumeFileDeliveryAction.saveAs,
    );
  }

  Future<LocalDataClearResult?> clearAllLocalData() async {
    if (_isCommittingArchive) return null;
    if (isLocalAgentCheckRunning || isSuggestionPreparationRunning) {
      formError = '请先等待当前本地任务结束或将其取消。';
      notifyListeners();
      return null;
    }
    if (isBusy) return null;
    _beginOperation();
    try {
      final clearResult = await _localDataManagementService.clearAll();
      var taskMaterialsCleared = true;
      try {
        await legalConsent?.clearAllLocalRecords();
        await _remoteResumeAiService.taskDraftStore.clear();
        await _remoteAccountService.guestCredentialStore.clear();
      } on Object {
        taskMaterialsCleared = false;
      }
      // 提交后才丢弃候选及票据；失败时保留可继续审阅的原状态，不先写取消审计。
      _localAgentCheckService.clearTransientState();
      _localResumeSuggestionService?.clearTransientState();
      _remoteResumeAiService.clearTransientState();
      _remoteAccountService.signOutLocally();
      documents = const [];
      versions = const [];
      validationIssues = const [];
      currentDocument = null;
      currentVersion = null;
      pendingImport = null;
      pendingLocalDataRestore = null;
      latestLocalAgentCheck = null;
      pendingResumeSuggestion = null;
      pendingRemoteResumeChange = null;
      latestRemoteSummary = null;
      latestRemoteMissingInformation = const [];
      latestRemoteWarnings = const [];
      networkEnabled = false;
      remotePersonalDataWarningAcknowledged = false;
      remoteAccountSnapshot = _remoteAccountService.snapshot;
      _refreshCapabilityDecisions();
      message =
          '已清空 ${clearResult.documentCount} 份简历、'
          '${clearResult.versionCount} 个版本和 '
          '${clearResult.agentRunCount} 条 Agent 审计；已导出的文件仍保留。';
      if (!taskMaterialsCleared) {
        formError = '简历数据已清空，但本机协议记录、AI 材料或游客标识未能全部清除，请再次执行清空。';
      }
      return clearResult;
    } on Object {
      formError = '清空失败，本地数据保持不变。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<LocalAgentCheckResult?> runLocalAgentCheck() async {
    final documentToCheck = currentDocument;
    final versionToCheck = currentVersion;
    if (documentToCheck == null || versionToCheck == null) {
      formError = '没有可检查的已保存版本。';
      notifyListeners();
      return null;
    }
    if (_activeLocalAgentCancellation != null) {
      return null;
    }

    final cancellationToken = LocalAgentCancellationToken();
    _activeLocalAgentCancellation = cancellationToken;
    _beginOperation();
    try {
      final checkResult = await _localAgentCheckService.checkSavedVersion(
        documentId: documentToCheck.id,
        resumeVersionId: versionToCheck.id,
        networkEnabled: networkEnabled,
        cancellationToken: cancellationToken,
      );
      latestLocalAgentCheck = checkResult;
      _setLocalAgentFeedback(checkResult);
      return checkResult;
    } on Object {
      formError = '本地检查失败，简历内容未改变。';
      return null;
    } finally {
      _activeLocalAgentCancellation = null;
      _endOperation();
    }
  }

  void cancelLocalAgentCheck() {
    _activeLocalAgentCancellation?.cancel();
  }

  Future<LocalSuggestionPreparationResult?> prepareLocalSuggestion() async {
    final service = _localResumeSuggestionService;
    if (service == null) return null;
    final resumeDocument = currentDocument;
    final savedResumeVersion = currentVersion;
    if (resumeDocument == null || savedResumeVersion == null) {
      formError = '没有可生成建议的已保存版本。';
      notifyListeners();
      return null;
    }
    final existingSuggestion = pendingResumeSuggestion;
    if (existingSuggestion != null) {
      return LocalSuggestionPreparationResult(
        status: LocalSuggestionPreparationStatus.ready,
        pendingSuggestion: existingSuggestion,
        summary: existingSuggestion.summary,
      );
    }
    if (_activeSuggestionCancellation != null) {
      return null;
    }

    final cancellationToken = LocalAgentCancellationToken();
    _activeSuggestionCancellation = cancellationToken;
    _beginOperation();
    try {
      final preparation = await service.prepareSuggestion(
        document: resumeDocument,
        version: savedResumeVersion,
        networkEnabled: networkEnabled,
        cancellationToken: cancellationToken,
      );
      pendingResumeSuggestion = preparation.pendingSuggestion;
      _setSuggestionPreparationFeedback(preparation);
      return preparation;
    } on Object {
      formError = '本地建议生成失败，已保存版本未改变。';
      return null;
    } finally {
      _activeSuggestionCancellation = null;
      _endOperation();
    }
  }

  void cancelSuggestionPreparation() {
    _activeSuggestionCancellation?.cancel();
  }

  Future<LocalSuggestionDecisionResult?> decidePendingSuggestion(
    LocalSuggestionDecision decision,
  ) async {
    final service = _localResumeSuggestionService;
    if (service == null) return null;
    if (_isCommittingArchive) return null;
    final suggestionToDecide = pendingResumeSuggestion;
    if (suggestionToDecide == null) {
      formError = '没有等待审阅的本地建议。';
      notifyListeners();
      return null;
    }

    _beginOperation();
    try {
      final decisionResult = await service.decide(
        suggestion: suggestionToDecide,
        decision: decision,
      );
      switch (decisionResult.status) {
        case LocalSuggestionDecisionStatus.accepted:
          pendingResumeSuggestion = null;
          // Runtime 已完成提交并消耗票据；重读失败不能重新开放确认。
          await _refreshAfterCommit(
            '建议已确认，并保存为新的 AI 建议版本。',
            reloadDocumentId: suggestionToDecide.documentId,
          );
          break;
        case LocalSuggestionDecisionStatus.rejected:
          pendingResumeSuggestion = null;
          message = '建议已拒绝，简历版本未改变。';
          break;
        case LocalSuggestionDecisionStatus.cancelled:
          pendingResumeSuggestion = null;
          message = '建议审阅已取消，简历版本未改变。';
          break;
        case LocalSuggestionDecisionStatus.conflict:
          pendingResumeSuggestion = null;
          await _reloadAfterConflict(
            suggestionToDecide.documentId,
            '当前版本已变化，过期建议未写入；请重新生成建议。',
          );
          break;
        case LocalSuggestionDecisionStatus.invalid:
          pendingResumeSuggestion = null;
          formError = '建议已失效或未通过验证，未写入任何内容。';
          break;
        case LocalSuggestionDecisionStatus.notFound:
          pendingResumeSuggestion = null;
          formError = '建议票据或目标简历已不存在，请重新生成建议。';
          break;
        case LocalSuggestionDecisionStatus.alreadyResolved:
          pendingResumeSuggestion = null;
          formError = '这项建议已经处理，不能更改决定。';
          break;
        case LocalSuggestionDecisionStatus.failed:
          // 暂时故障不销毁票据，用户可以继续审阅并重试或改为拒绝。
          formError = '确认保存暂时失败，建议仍保留，可重试或取消。';
          break;
      }
      return decisionResult;
    } on Object {
      formError = '建议处理失败，建议仍保留，可重试或取消。';
      return null;
    } finally {
      _endOperation();
    }
  }

  Future<bool> _authenticateRemoteAccount({
    required Future<void> Function() operation,
    required String successMessage,
  }) async {
    if (!_requireNetworkEnabled()) {
      return false;
    }
    _beginOperation();
    try {
      await operation();
      _remoteResumeAiService.clearTransientState();
      remoteAccountSnapshot = _remoteAccountService.snapshot;
      pendingRemoteResumeChange = null;
      await restoreRemoteReview();
      message = successMessage;
      return true;
    } on RemoteAccountInputException catch (error) {
      formError = error.message;
      return false;
    } on GatewayApiException catch (error) {
      _setGatewayFailure(error);
      return false;
    } on Object {
      formError = '账号操作失败，请检查本地 Gateway 后重试。';
      return false;
    } finally {
      _endOperation();
    }
  }

  Future<RemoteOptimizationPreparation?> _prepareCurrentRemoteOptimization({
    required RemoteAiCapability capability,
    required Future<RemoteOptimizationPreparation> Function(
      ResumeDocument document,
      ResumeVersion version,
    )
    operation,
  }) async {
    if (pendingRemoteResumeChange == null) await restoreRemoteReview();
    final document = currentDocument;
    final version = currentVersion;
    if (document == null || version == null) {
      formError = '请先打开一份已保存的简历。';
      notifyListeners();
      return null;
    }
    if (!_canUseRemoteCapability(capability)) {
      return null;
    }
    _beginOperation();
    try {
      final preparation = await operation(document, version);
      latestRemoteSummary = preparation.summary;
      latestRemoteMissingInformation = preparation.missingInformation;
      latestRemoteWarnings = preparation.warnings;
      pendingRemoteResumeChange = preparation.pendingChange;
      if (preparation.pendingChange != null) {
        await _retainRemoteChange(preparation.pendingChange!);
      }
      await _refreshRemoteSnapshotWithoutDiscardingResult();
      if (preparation.pendingChange == null) {
        message = preparation.summary;
      }
      return preparation;
    } on RemoteResumeAiInputException catch (error) {
      formError = error.message;
      return null;
    } on RemoteResumeAiResponseException {
      formError = '远程结果未通过本地安全校验，未进入审阅。';
      return null;
    } on GatewayApiException catch (error) {
      if (error.code == 'quota_exhausted') {
        await _refreshRemoteSnapshotWithoutDiscardingResult();
      }
      _setGatewayFailure(error);
      return null;
    } on Object {
      formError = '岗位优化失败，已保存版本未改变。';
      return null;
    } finally {
      _endOperation();
    }
  }

  bool _canUseRemoteCapability(RemoteAiCapability capability) {
    if (pendingRemoteResumeChange != null) {
      formError = '请先确认或拒绝已有候选。';
      notifyListeners();
      return false;
    }
    if (!_requireNetworkEnabled()) {
      return false;
    }
    if (!remotePersonalDataWarningAcknowledged) {
      formError = '请先阅读并确认联网 AI 隐私提醒。';
      notifyListeners();
      return false;
    }
    if (!remoteAccountSnapshot.isSignedIn) {
      formError = '请先在账号页登录、注册或进入游客体验。';
      notifyListeners();
      return false;
    }
    final accessSnapshot = remoteAccountSnapshot.accessByCapability[capability];
    if (accessSnapshot == null || !accessSnapshot.allowed) {
      formError = switch (accessSnapshot?.reason) {
        'subscription_required' => '此能力需要会员权益，当前账号暂不可用。',
        'quota_exhausted' => '本月该类 AI 成果额度已用完，请在账号页查看额度。',
        _ => '当前账号不能使用这项联网 AI 能力。',
      };
      notifyListeners();
      return false;
    }
    return true;
  }

  bool _requireNetworkEnabled() {
    if (legalConsent != null && !legalConsent!.canUseRemoteServices) {
      formError = legalConsent!.blockedReason;
      notifyListeners();
      return false;
    }
    if (networkEnabled) {
      return true;
    }
    formError = '联网已关闭，请先在设置中允许联网。';
    notifyListeners();
    return false;
  }

  void _setPendingRemoteChange(PendingRemoteResumeChange preparedChange) {
    _pendingRemoteExpiresAt =
        preparedChange.expiresAtUtc ??
        _clock().toUtc().add(const Duration(days: 7));
    pendingRemoteResumeChange = preparedChange;
    latestRemoteSummary = preparedChange.summary;
    latestRemoteMissingInformation = preparedChange.missingInformation;
    latestRemoteWarnings = preparedChange.warnings;
  }

  Future<void> _refreshRemoteSnapshotWithoutDiscardingResult() async {
    final trackingWarning = _remoteAccountService.operationTrackingWarning;
    if (trackingWarning != null) {
      latestRemoteWarnings = [...latestRemoteWarnings, trackingWarning];
    }
    try {
      await _remoteAccountService.refreshAccess();
      remoteAccountSnapshot = _remoteAccountService.snapshot;
    } on Object {
      // AI 结果已经完成本地校验，访问快照刷新失败不应销毁用户正在审阅的结果。
      remoteAccountSnapshot = _remoteAccountService.snapshot;
    }
  }

  void _setGatewayFailure(GatewayApiException error) {
    if (error.code == 'unauthenticated' || error.statusCode == 401) {
      _remoteAccountService.signOutLocally();
      _remoteResumeAiService.clearTransientState();
      remoteAccountSnapshot = _remoteAccountService.snapshot;
      pendingRemoteResumeChange = null;
      formError = '登录已失效，请重新登录。';
      return;
    }
    formError = switch (error.code) {
      'gateway_not_configured' => '开发 Gateway 未配置，离线功能仍可使用。',
      'gateway_unreachable' => '无法连接联网服务，请检查网络和服务地址；本地编辑与导出仍可使用。',
      'gateway_protocol_error' => '联网服务连接未完成，请检查服务配置。',
      'client_timeout' => '本次请求超时，服务端可能已收到；请先核对操作状态，不要重复生成。',
      'subscription_required' => '此能力需要有效的月订阅，当前账号不可用。',
      'quota_exhausted' => '本月该类 AI 成果额度已用完，请在账号页查看额度。',
      'trial_admission_closed' => '本轮 AI 测试已到期或达到总次数上限，请联系测试负责人。',
      'idempotency_conflict' => '这次请求与已有操作冲突，请重新发起，不会自动重试。',
      'queue_full' => '联网 AI 当前繁忙，请稍后重试。',
      'provider_timeout' => '联网 AI 响应超时，请稍后重试。',
      'provider_unavailable' => '联网 AI 暂不可用，请稍后重新发起。',
      'operation_pending_reconciliation' =>
        '本次调用结果尚不确定，未写入本地；请在账号窗口查询联网操作记录，勿重复生成。',
      'invalid_gateway_response' => '联网服务响应不符合协议，请先查询原操作状态。',
      'invalid_provider_response' => '远程结果未通过 Gateway 校验，未进入本地审阅。',
      'recovery_invalid' => '手机号或恢复码不正确，或恢复码已使用。请核对后重试。',
      'recovery_unavailable' || 'recovery_code_required' => '当前恢复方式暂不可用，请稍后重试。',
      'verification_unavailable' => '此号码暂不能用于新注册；已有账号请直接登录或使用恢复码找回。',
      'identity_rate_limited' => '尝试次数较多，请稍后重试。',
      _ => error.retryable ? '联网服务暂不可用，请稍后重试。' : '联网请求未完成，请检查账号与输入后重试。',
    };
  }

  Future<void> _createRemoteDocument(PendingRemoteResumeChange change) async {
    final creationTime = _clock().toUtc();
    final documentId = _nextId('document');
    final versionId = _nextId('version');
    final document = ResumeDocument(
      id: documentId,
      title: change.documentTitle,
      currentVersionId: versionId,
      createdAt: creationTime,
      updatedAt: creationTime,
    );
    final version = ResumeVersion(
      id: versionId,
      documentId: documentId,
      parentVersionId: null,
      schemaVersion: change.proposedContent.schemaVersion,
      content: _markedRemoteContent(change),
      source: ResumeVersionSource.aiConfirmed,
      createdAt: creationTime,
    );
    final owner = _pendingRemoteOwner;
    if (_reviewRepository != null && owner != null) {
      await _reviewRepository.commitReview(
        recordId: remoteReviewId(owner, change.operationId),
        document: document,
        version: version,
      );
    } else {
      await _repository.createDocument(document, version);
    }
    _showCommittedVersion(document, version);
  }

  Future<void> _appendRemoteVersion(PendingRemoteResumeChange change) async {
    final document = change.documentId == null
        ? null
        : await _repository.findDocument(change.documentId!);
    final version = change.documentId == null
        ? null
        : await _repository.findCurrentVersion(change.documentId!);
    if (document == null ||
        version == null ||
        document.id != change.documentId ||
        version.id != change.baseVersionId) {
      throw ResumeWriteConflict(
        documentId: change.documentId ?? '',
        expectedVersionId: change.baseVersionId,
        actualVersionId: version?.id,
      );
    }
    final saveTime = _clock().toUtc();
    final newVersion = ResumeVersion(
      id: _nextId('version'),
      documentId: document.id,
      parentVersionId: version.id,
      schemaVersion: change.proposedContent.schemaVersion,
      content: _markedRemoteContent(change),
      source: ResumeVersionSource.aiConfirmed,
      createdAt: saveTime,
    );
    final updatedDocument = ResumeDocument(
      id: document.id,
      title: document.title,
      currentVersionId: newVersion.id,
      createdAt: document.createdAt,
      updatedAt: saveTime,
      metadata: document.metadata,
      extensions: document.extensions,
    );
    final owner = _pendingRemoteOwner;
    if (_reviewRepository != null && owner != null) {
      await _reviewRepository.commitReview(
        recordId: remoteReviewId(owner, change.operationId),
        document: updatedDocument,
        version: newVersion,
        expectedVersionId: version.id,
      );
    } else {
      await _repository.saveVersion(
        document: updatedDocument,
        version: newVersion,
        expectedCurrentVersionId: version.id,
      );
    }
    _showCommittedVersion(updatedDocument, newVersion);
  }

  Future<void> _reloadCurrent(String documentId) async {
    final reloadedDocument = await _repository.findDocument(documentId);
    final reloadedVersion = await _repository.findCurrentVersion(documentId);
    final reloadedVersions = await _repository.listVersions(documentId);
    final reloadedDocuments = await _repository.listDocuments();
    final reloadedIssues = reloadedVersion == null
        ? const []
        : const ResumeValidator().validate(reloadedVersion.content).issues;
    // 全部读取成功再替换，避免旧正文搭配新文档指针的半刷新状态。
    currentDocument = reloadedDocument;
    currentVersion = reloadedVersion;
    versions = reloadedVersions;
    documents = reloadedDocuments;
    validationIssues = List<ValidationIssue>.from(reloadedIssues);
    latestLocalAgentCheck = null;
  }

  void _showCommittedVersion(ResumeDocument document, ResumeVersion version) {
    // 写库成功后先使用已知提交结果；读取列表只是刷新，不决定写入是否成功。
    versions = [
      version,
      ...versions.where(
        (previous) =>
            previous.documentId == document.id && previous.id != version.id,
      ),
    ];
    documents =
        [document, ...documents.where((previous) => previous.id != document.id)]
          ..sort((left, right) {
            final byTime = right.updatedAt.compareTo(left.updatedAt);
            return byTime != 0 ? byTime : left.id.compareTo(right.id);
          });
    currentDocument = document;
    currentVersion = version;
    validationIssues = const ResumeValidator().validate(version.content).issues;
    latestLocalAgentCheck = null;
  }

  Future<void> _refreshAfterCommit(
    String successMessage, {
    String? reloadDocumentId,
  }) async {
    message = successMessage;
    try {
      if (reloadDocumentId != null) {
        // 本地建议由 Runtime 写入，控制器需要重新读取它实际保存的版本。
        await _reloadCurrent(reloadDocumentId);
      } else {
        final documentId = currentDocument?.id;
        final refreshedVersions = documentId == null
            ? <ResumeVersion>[]
            : await _repository.listVersions(documentId);
        final refreshedDocuments = await _repository.listDocuments();
        versions = refreshedVersions;
        documents = refreshedDocuments;
      }
    } on Object {
      message =
          '$successMessage\n界面刷新失败，请重新打开简历或重启应用查看最新数据；'
          '无需重复执行刚才的操作。';
    }
  }

  Future<void> _reloadAfterConflict(String documentId, String feedback) async {
    formError = feedback;
    try {
      await _reloadCurrent(documentId);
    } on Object {
      formError = '$feedback\n界面刷新失败，请重新打开简历后再操作。';
    }
  }

  Future<void> _createImportedDocument(
    String documentTitle,
    ResumeData importedResume,
  ) async {
    final importTime = _clock().toUtc();
    final importedDocumentId = _nextId('document');
    final importedVersionId = _nextId('version');
    final importedDocument = ResumeDocument(
      id: importedDocumentId,
      title: documentTitle,
      currentVersionId: importedVersionId,
      createdAt: importTime,
      updatedAt: importTime,
    );
    final importedVersion = ResumeVersion(
      id: importedVersionId,
      documentId: importedDocumentId,
      parentVersionId: null,
      schemaVersion: importedResume.schemaVersion,
      content: importedResume,
      source: ResumeVersionSource.imported,
      createdAt: importTime,
    );
    await _repository.createDocument(importedDocument, importedVersion);
    _showCommittedVersion(importedDocument, importedVersion);
  }

  Future<void> _appendImportedVersion(PendingResumeImport pending) async {
    final targetDocument = currentDocument;
    final targetVersion = currentVersion;
    if (targetDocument == null ||
        targetVersion == null ||
        targetDocument.id != pending.documentId ||
        targetVersion.id != pending.baseVersionId) {
      throw ResumeWriteConflict(
        documentId: pending.documentId ?? '',
        expectedVersionId: pending.baseVersionId,
        actualVersionId: targetVersion?.id,
      );
    }

    final importTime = _clock().toUtc();
    final importedVersion = ResumeVersion(
      id: _nextId('version'),
      documentId: targetDocument.id,
      parentVersionId: targetVersion.id,
      schemaVersion: pending.preview.resume.schemaVersion,
      content: pending.preview.resume,
      source: ResumeVersionSource.imported,
      createdAt: importTime,
    );
    final updatedDocument = ResumeDocument(
      id: targetDocument.id,
      title: targetDocument.title,
      currentVersionId: importedVersion.id,
      createdAt: targetDocument.createdAt,
      updatedAt: importTime,
      metadata: targetDocument.metadata,
      extensions: targetDocument.extensions,
    );
    await _repository.saveVersion(
      document: updatedDocument,
      version: importedVersion,
      expectedCurrentVersionId: targetVersion.id,
    );
    _showCommittedVersion(updatedDocument, importedVersion);
  }

  ResumeData _markedRemoteContent(PendingRemoteResumeChange change) {
    if (!change.networkGenerated) return change.proposedContent;
    final content = ResumeAiProvenance(
      operationId: change.operationId,
    ).attachTo(change.proposedContent);
    // The gateway binds this label to the actual generation/propagation task.
    // A legacy response without it does not authorize inventing a provider label.
    return change.aigcMetadata?.attachTo(content) ?? content;
  }

  String _nextId(String entityPrefix) {
    _idCounter += 1;
    final timestampMicros = _clock().toUtc().microsecondsSinceEpoch;
    return '$entityPrefix-${timestampMicros.toRadixString(36)}-'
        '${_idCounter.toRadixString(36)}';
  }

  String _suggestImportTitle(String fileName) {
    final trimmedFileName = fileName.trim();
    final extensionStart = trimmedFileName.lastIndexOf('.');
    final nameWithoutExtension = extensionStart > 0
        ? trimmedFileName.substring(0, extensionStart)
        : trimmedFileName;
    return nameWithoutExtension.trim().isEmpty ? '导入的简历' : nameWithoutExtension;
  }

  Future<void> _discardPendingSuggestion() async {
    final suggestionToDiscard = pendingResumeSuggestion;
    if (suggestionToDiscard == null) {
      return;
    }
    pendingResumeSuggestion = null;
    await _localResumeSuggestionService?.decide(
      suggestion: suggestionToDiscard,
      decision: LocalSuggestionDecision.cancel,
    );
  }

  void _discardPendingRemoteChange() {
    pendingRemoteResumeChange = null;
  }

  void _setSuggestionPreparationFeedback(
    LocalSuggestionPreparationResult preparation,
  ) {
    switch (preparation.status) {
      case LocalSuggestionPreparationStatus.ready:
        return;
      case LocalSuggestionPreparationStatus.noSuggestion:
        message = preparation.summary ?? '当前已保存版本暂无可安全生成的建议。';
        return;
      case LocalSuggestionPreparationStatus.networkDisabled:
        formError = '联网已关闭，且当前没有可用的本地建议能力。';
        return;
      case LocalSuggestionPreparationStatus.capabilityUnavailable:
        formError = '当前设备没有满足要求的本地建议能力。';
        return;
      case LocalSuggestionPreparationStatus.cancelled:
        message = '本地建议生成已取消。';
        return;
      case LocalSuggestionPreparationStatus.timedOut:
        formError = '本地建议生成超时，请稍后重试。';
        return;
      case LocalSuggestionPreparationStatus.providerFailed:
        formError = '本地建议服务暂不可用，请稍后重试。';
        return;
      case LocalSuggestionPreparationStatus.invalidResponse:
        formError = '本地建议无效或不安全，已拒绝进入审阅。';
        return;
      case LocalSuggestionPreparationStatus.failed:
        formError = '本地建议生成失败，已保存版本未改变。';
        return;
    }
  }

  void _setLocalAgentFeedback(LocalAgentCheckResult checkResult) {
    switch (checkResult.status) {
      case LocalAgentCheckStatus.completed:
        message =
            '本地检查完成：发现 ${checkResult.validationIssueCount} 个验证问题、'
            '${checkResult.repeatedContentGroupCount} 组重复内容。';
        return;
      case LocalAgentCheckStatus.networkDisabled:
        formError = '联网已关闭，且当前没有可用的本地检查能力。';
        return;
      case LocalAgentCheckStatus.capabilityUnavailable:
        formError = '当前设备没有满足要求的本地检查能力。';
        return;
      case LocalAgentCheckStatus.cancelled:
        message = '本地检查已取消。';
        return;
      case LocalAgentCheckStatus.timedOut:
        formError = '本地检查超时，请稍后重试。';
        return;
      case LocalAgentCheckStatus.providerFailed:
        formError = '本地检查服务暂不可用，请稍后重试。';
        return;
      case LocalAgentCheckStatus.invalidPlan:
        formError = '本地检查返回了不安全或无效的计划，已拒绝执行。';
        return;
      case LocalAgentCheckStatus.failed:
        formError = '本地检查失败，简历内容未改变。';
        return;
    }
  }

  void _refreshCapabilityDecisions() {
    final evaluationContext = AccessEvaluationContext(
      networkEnabled: networkEnabled,
      evaluatedAtUtc: _clock().toUtc(),
    );
    capabilityDecisions = ProductCapability.values
        .map(
          (capability) => _accessPolicy.evaluate(capability, evaluationContext),
        )
        .toList(growable: false);
  }

  void _beginOperation() {
    isBusy = true;
    formError = null;
    message = null;
    notifyListeners();
  }

  void _endOperation() {
    isBusy = _isCommittingArchive;
    notifyListeners();
  }
}

DateTime _utcNow() => DateTime.now().toUtc();
