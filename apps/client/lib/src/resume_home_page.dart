import 'dart:convert';
import 'dart:async';
import 'remote_task_draft_store.dart';

import 'package:document_io/document_io.dart';
import 'package:flutter/material.dart';
import 'package:resume_domain/resume_domain.dart';

import 'local_agent_check_service.dart';
import 'legal_consent_pages.dart';
import 'gateway_api_client.dart' show RemoteAiCapability;
import 'remote_ai_dialogs.dart';
import 'resume_profile_fields.dart';
import 'remote_resume_ai_service.dart';
import 'resume_pdf_preview_page.dart';
import 'resume_workspace_controller.dart';
import 'privacy_and_data_settings_dialog.dart';
import 'resume_collection_editor.dart';
import 'workspace_pages.dart';
import 'resume_word_page.dart';
import 'resume_photo_picker.dart';

enum _ResumeExportAction { word, markdown, json, pdfPreview }

final class ResumeHomePage extends StatefulWidget {
  const ResumeHomePage({super.key, required this.controller});

  final ResumeWorkspaceController controller;

  @override
  State<ResumeHomePage> createState() => _ResumeHomePageState();
}

final class _ResumeHomePageState extends State<ResumeHomePage> {
  ResumeWorkspaceController get controller => widget.controller;
  int _selectedDestination = 0;
  bool _aiTaskActive = false;
  BasicResumeComposeDraft? _composeDraft;
  String? _composeTaskId;
  final _optimizationTaskIds = <(int, String, String), String>{};
  List<RemoteTaskDraft> _unfinishedTasks = const [];
  String? _loadedTaskOwner;
  final _optimizationDrafts =
      <(int, String, String), TargetedOptimizationDraft>{};
  int? _draftSessionGeneration;

  final _editorKey = GlobalKey<_ResumeEditorState>();

  @override
  void initState() {
    super.initState();
    _draftSessionGeneration = controller.remoteDraftGeneration;
    controller.addListener(_discardStaleAiDrafts);
    controller.initialize().then((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showFeedback();
      });
    });
  }

  @override
  void dispose() {
    controller.removeListener(_discardStaleAiDrafts);
    super.dispose();
  }

  (int, String, String)? get _aiDraftContext {
    final document = controller.currentDocument;
    final version = controller.currentVersion;
    return document == null || version == null
        ? null
        : (controller.remoteDraftGeneration, document.id, version.id);
  }

  void _discardStaleAiDrafts() {
    if (_draftSessionGeneration != controller.remoteDraftGeneration) {
      _composeDraft = null;
      _composeTaskId = null;
      _optimizationTaskIds.clear();
      _optimizationDrafts.clear();
      _draftSessionGeneration = controller.remoteDraftGeneration;
    }
    final ids = controller.documents.map((document) => document.id).toSet();
    final current = _aiDraftContext;
    bool stale((int, String, String) key) =>
        !ids.contains(key.$2) ||
        (current != null && key.$2 == current.$2 && key.$3 != current.$3);
    _optimizationDrafts.removeWhere((key, _) => stale(key));
    _optimizationTaskIds.removeWhere((key, _) => stale(key));
    if (_loadedTaskOwner != controller.remoteAccountId) {
      _loadedTaskOwner = controller.remoteAccountId;
      unawaited(_reloadUnfinishedTasks());
    }
  }

  Future<void> _reloadUnfinishedTasks() async {
    final owner = controller.remoteAccountId;
    try {
      final tasks = await controller.readUnfinishedAiTasks();
      if (mounted && controller.remoteAccountId == owner) {
        setState(() => _unfinishedTasks = tasks);
      }
    } on Object {
      if (mounted) setState(() => _unfinishedTasks = const []);
    }
  }

  Future<void> _discardUnfinishedTask(RemoteTaskDraft task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除本机任务草稿？'),
        content: const Text(
          '将移除此任务保存在本机的材料。原请求、待核验状态和用量记录仍保留；这不会取消已发出的请求或退还费用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await controller.discardUnfinishedAiTask(task);
    if (_composeTaskId == task.id) {
      _composeTaskId = null;
      _composeDraft = null;
    }
    _optimizationTaskIds.removeWhere((key, id) {
      if (id != task.id) return false;
      _optimizationDrafts.remove(key);
      return true;
    });
    await _reloadUnfinishedTasks();
    if (mounted) _showFeedback();
  }

  Future<void> _resumeUnfinishedTask(RemoteTaskDraft task) async {
    if (task.owner != controller.remoteAccountId || controller.isBusy) return;
    await controller.restoreRemoteReview();
    if (!mounted) return;
    if (controller.pendingRemoteResumeChange case final pending?) {
      await _reviewRemoteChange(pending);
      await _reloadUnfinishedTasks();
      return;
    }
    if (task.kind == 'optimize') {
      await controller.openDocument(task.documentId!);
      if (!mounted) return;
      setState(() => _aiTaskActive = true);
    }
    final canEditMaterial = await controller.recoverUnfinishedAiTask(task);
    if (!mounted || controller.remoteAccountId != task.owner) return;
    if (controller.pendingRemoteResumeChange case final pending?) {
      await _reviewRemoteChange(pending);
    } else if (canEditMaterial) {
      if (task.kind == 'compose') {
        _composeDraft = controller.restoreBasicTaskMaterial(task);
        _composeTaskId = task.id;
        await _startBasicRemoteCompose(
          initialQuestions: controller.latestRemoteMissingInformation,
        );
      } else {
        final context = _aiDraftContext;
        if (context == null) return;
        _optimizationDrafts[context] = TargetedOptimizationDraft(
          targetJobTitle: task.material['targetJobTitle'] as String,
          jobDescription: task.material['jobDescription'] as String,
          userInstruction: task.material['userInstruction'] as String,
          selectedPersonalFields: const {},
          sharePersonalData: false,
        );
        _optimizationTaskIds[context] = task.id;
        await _prepareTargetedOptimization();
      }
    } else {
      _showFeedback();
    }
    await _reloadUnfinishedTasks();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final currentResumeDocument = controller.currentDocument;
        final editing = currentResumeDocument != null;
        final wide = MediaQuery.sizeOf(context).width >= 840;
        return PopScope(
          canPop: !editing && _selectedDestination == 0,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && editing) {
              _returnToLibrary();
            } else if (!didPop && _selectedDestination != 0) {
              setState(() => _selectedDestination = 0);
            }
          },
          child: Scaffold(
            appBar: AppBar(
              leading: currentResumeDocument == null
                  ? null
                  : IconButton(
                      key: const Key('返回简历列表'),
                      tooltip: '返回简历列表',
                      onPressed:
                          controller.isBusy ||
                              controller.pendingResumeSuggestion != null ||
                              controller.pendingRemoteResumeChange != null
                          ? null
                          : _returnToLibrary,
                      icon: const Icon(Icons.arrow_back),
                    ),
              title: Text(
                currentResumeDocument?.title ?? '简历全能帮',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  key: const Key('隐私设置'),
                  tooltip: '设置',
                  onPressed: controller.isReady && !controller.isBusy
                      ? _showPrivacySettings
                      : null,
                  icon: const Icon(Icons.settings_rounded),
                ),
              ],
              bottom: controller.isBusy
                  ? const PreferredSize(
                      preferredSize: Size.fromHeight(3),
                      child: LinearProgressIndicator(minHeight: 3),
                    )
                  : null,
            ),
            body: SafeArea(
              top: false,
              child: Row(
                children: [
                  if (!editing && wide) ...[
                    NavigationRail(
                      scrollable: true,
                      selectedIndex: _selectedDestination,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: (index) =>
                          setState(() => _selectedDestination = index),
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.description_outlined),
                          selectedIcon: Icon(Icons.description_rounded),
                          label: Text('简历'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.auto_awesome_outlined),
                          selectedIcon: Icon(Icons.auto_awesome_rounded),
                          label: Text('助手'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.settings_outlined),
                          selectedIcon: Icon(Icons.settings_rounded),
                          label: Text('设置'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                  ],
                  Expanded(child: _buildBody()),
                ],
              ),
            ),
            bottomNavigationBar: editing || wide
                ? null
                : NavigationBar(
                    selectedIndex: _selectedDestination,
                    onDestinationSelected: (index) =>
                        setState(() => _selectedDestination = index),
                    destinations: const [
                      NavigationDestination(
                        key: Key('导航_简历'),
                        icon: Icon(Icons.description_outlined),
                        selectedIcon: Icon(Icons.description_rounded),
                        label: '简历',
                      ),
                      NavigationDestination(
                        key: Key('导航_助手'),
                        icon: Icon(Icons.auto_awesome_outlined),
                        selectedIcon: Icon(Icons.auto_awesome_rounded),
                        label: '助手',
                      ),
                      NavigationDestination(
                        key: Key('导航_设置'),
                        icon: Icon(Icons.settings_outlined),
                        selectedIcon: Icon(Icons.settings_rounded),
                        label: '设置',
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    if (!controller.isReady) {
      if (controller.formError case final error?) {
        return _CenteredMessage(icon: Icons.error_outline, title: error);
      }
      return const Center(child: CircularProgressIndicator());
    }

    final currentResumeDocument = controller.currentDocument;
    final currentResumeVersion = controller.currentVersion;
    if (currentResumeDocument != null && currentResumeVersion != null) {
      if (_aiTaskActive) {
        return ResumeAiTaskPage(
          document: currentResumeDocument,
          version: currentResumeVersion,
          isBusy: controller.isBusy,
          hasPendingChange: controller.pendingRemoteResumeChange != null,
          onOptimize: _prepareTargetedOptimization,
          unfinishedTasks: _unfinishedTasks
              .where((e) => e.documentId == currentResumeDocument.id)
              .toList(),
          onResumeTask: _resumeUnfinishedTask,
          onDiscardTask: _discardUnfinishedTask,
          onReview: _restoreRemoteReview,
          onEdit: () => setState(() => _aiTaskActive = false),
          onConfirmFacts: _confirmWritingFacts,
          confirmedFactCount: controller
              .currentWritingContext()
              .confirmedFacts
              .length,
          constraintCount: controller
              .currentWritingContext()
              .constraints
              .length,
        );
      }
      return ResumeEditor(
        key: _editorKey,
        controller: controller,
        document: currentResumeDocument,
        version: currentResumeVersion,
        onFeedback: _showFeedback,
      );
    }

    if (_selectedDestination == 1) {
      return ResumeAssistantPage(
        isBusy: controller.isBusy,
        unfinishedTasks: _unfinishedTasks,
        onResumeTask: _resumeUnfinishedTask,
        onDiscardTask: _discardUnfinishedTask,
        onOpenLibrary: () => setState(() => _selectedDestination = 0),
        onCompose: _startBasicRemoteCompose,
        onChooseResume: _chooseResumeForAi,
        onReview: controller.remoteAccountSnapshot.isSignedIn
            ? _restoreRemoteReview
            : null,
      );
    }
    if (_selectedDestination == 2) {
      return WorkspaceSettingsPage(
        isBusy: controller.isBusy,
        onPrivacy: _showPrivacySettings,
        onAccount: _showRemoteAccount,
        onLegal: controller.legalConsent == null ? null : _showLegalCenter,
      );
    }
    return ResumeLibraryPage(
      documents: controller.documents,
      isBusy: controller.isBusy,
      onCreate: _createDocument,
      onImport: _importTextResume,
      onCompose: _startBasicRemoteCompose,
      onOpen: (documentId) async {
        setState(() => _aiTaskActive = false);
        await controller.openDocument(documentId);
        _showFeedback();
      },
    );
  }

  Future<void> _prepareTargetedOptimization() async {
    if (!await _ensureRemotePrivacyWarning()) {
      return;
    }
    if (!await _ensureRemoteAccount()) return;
    if (!mounted) {
      return;
    }
    final draftContext = _aiDraftContext;
    if (draftContext == null) return;
    final optimizationDraft = await showDialog<TargetedOptimizationDraft>(
      context: context,
      builder: (context) => TargetedOptimizationDialog(
        initialDraft: _optimizationDrafts[draftContext],
        documentTitle: controller.currentDocument?.title ?? '',
        initialJobTitle:
            controller.currentVersion?.content.profile.headline ?? '',
        onDraftChanged: (draft) {
          if (_aiDraftContext == draftContext) {
            _optimizationDrafts[draftContext] = draft;
          }
        },
      ),
    );
    if (optimizationDraft == null ||
        !mounted ||
        _aiDraftContext != draftContext) {
      return;
    }
    _optimizationTaskIds[draftContext] ??= controller.createAiTaskId();
    final preparation = await controller.prepareTargetedRemoteOptimization(
      targetJobTitle: optimizationDraft.targetJobTitle,
      jobDescription: optimizationDraft.jobDescription,
      userInstruction: optimizationDraft.userInstruction,
      confirmedInputSharing: optimizationDraft.confirmedInputSharing,
      sharePersonalData: optimizationDraft.sharePersonalData,
      selectedPersonalFields: optimizationDraft.selectedPersonalFields,
      taskId: _optimizationTaskIds[draftContext],
    );
    await _reloadUnfinishedTasks();
    if (!_unfinishedTasks.any(
      (e) => e.id == _optimizationTaskIds[draftContext],
    )) {
      _optimizationTaskIds.remove(draftContext);
    }
    await _showRemotePreparation(preparation);
  }

  Future<void> _confirmWritingFacts() async {
    final version = controller.currentVersion;
    final documentId = controller.currentDocument?.id;
    final owner = controller.remoteAccountId;
    if (version == null || controller.isBusy) return;
    final contextValue = await showDialog<RemoteWritingContext>(
      context: context,
      builder: (context) => RemoteWritingContextDialog(
        content: version.content,
        initial: controller.currentWritingContext(),
      ),
    );
    if (contextValue == null || !mounted) return;
    if (owner != controller.remoteAccountId ||
        documentId != controller.currentDocument?.id ||
        version.id != controller.currentVersion?.id) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('账号或简历版本已变化，请重新确认AI材料。')));
      return;
    }
    await controller.confirmWritingContext(contextValue);
    _showFeedback();
  }

  Future<void> _showRemotePreparation(
    RemoteOptimizationPreparation? preparation,
  ) async {
    if (!mounted) {
      return;
    }
    if (preparation == null) {
      _showFeedback();
      return;
    }
    final pendingChange = preparation.pendingChange;
    if (pendingChange == null) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('AI 建议'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(preparation.summary),
                for (final missing in preparation.missingInformation)
                  Text('待补充：$missing'),
                for (final warning in preparation.warnings) Text('提示：$warning'),
                const SizedBox(height: 8),
                const Text('本轮没有需要保存的修改，原简历保持不变。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    await _reviewRemoteChange(pendingChange);
  }

  Future<void> _chooseResumeForAi() async {
    if (controller.isBusy) return;
    final documentId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择要优化的简历'),
        children: [
          if (controller.documents.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('先创建或导入一份简历，也可以使用 AI 起草。'),
            ),
          for (final document in controller.documents)
            SimpleDialogOption(
              key: ValueKey('AI选择简历_${document.id}'),
              onPressed: () => Navigator.pop(context, document.id),
              child: Text(document.title),
            ),
        ],
      ),
    );
    if (documentId == null || !mounted) return;
    setState(() => _aiTaskActive = true);
    await controller.openDocument(documentId);
    _showFeedback();
  }

  Future<void> _restoreRemoteReview() async {
    await controller.restoreRemoteReview();
    if (!mounted) return;
    final pending = controller.pendingRemoteResumeChange;
    if (pending != null) {
      await _reviewRemoteChange(pending);
    } else {
      _showFeedback();
    }
  }

  Future<void> _returnToLibrary() async {
    if (controller.isBusy ||
        controller.pendingResumeSuggestion != null ||
        controller.pendingRemoteResumeChange != null) {
      return;
    }
    if (!await (_editorKey.currentState?.confirmLeaving() ??
        Future.value(true))) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _selectedDestination = _aiTaskActive ? 1 : 0;
      _aiTaskActive = false;
    });
    await controller.closeDocument();
  }

  Future<void> _createDocument() async {
    final createResumeInput = await showDialog<_CreateResumeInput>(
      context: context,
      builder: (context) => const _CreateResumeDialog(),
    );
    if (createResumeInput == null || !mounted) {
      return;
    }
    await controller.createDocument(
      title: createResumeInput.title,
      fullName: createResumeInput.fullName,
    );
    _showFeedback();
  }

  Future<void> _importTextResume() async {
    if (!await (_editorKey.currentState?.confirmLeaving() ??
        Future.value(true))) {
      return;
    }
    if (!mounted) return;
    final preparationOutcome = await controller.prepareTextImport();
    if (!mounted) {
      return;
    }
    if (preparationOutcome != ImportPreparationOutcome.ready) {
      _showFeedback();
      return;
    }

    final importPreview = controller.pendingImport;
    if (importPreview == null) {
      return;
    }
    final confirmedTitle = await showDialog<String>(
      context: context,
      builder: (context) =>
          _ResumeImportPreviewDialog(pendingImport: importPreview),
    );
    if (!mounted) {
      return;
    }
    if (confirmedTitle == null) {
      controller.cancelPendingImport();
      return;
    }

    await controller.confirmPendingImport(newDocumentTitle: confirmedTitle);
    _showFeedback();
  }

  Future<void> _showPrivacySettings() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => PrivacyAndDataSettingsDialog(
        controller: controller,
        onFeedback: _showFeedback,
        onAccount: () {
          Navigator.pop(dialogContext);
          _showRemoteAccount();
        },
        onBeforeRestore: () async =>
            await (_editorKey.currentState?.confirmLeaving() ??
                Future.value(true)),
      ),
    );
    _showFeedback();
  }

  Future<void> _showLegalCenter() async {
    final legal = controller.legalConsent;
    if (legal != null) {
      await showLegalCenter(
        context,
        legal,
        enableNetwork: () => controller.setNetworkEnabled(true),
      );
    }
  }

  Future<bool> _ensureLegalRemoteConsent() async {
    final legal = controller.legalConsent;
    if (legal == null || legal.canUseRemoteServices) return true;
    final accepted = await showLegalConsentPrompt(context, legal);
    if (!mounted || !accepted || !legal.canUseRemoteServices) return false;
    return controller.setNetworkEnabled(true);
  }

  Future<void> _showRemoteAccount() async {
    if (!await _ensureLegalRemoteConsent() || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => RemoteAccountDialog(
        controller: controller,
        onFeedback: _showFeedback,
      ),
    );
    _showFeedback();
  }

  Future<void> _startBasicRemoteCompose({
    List<String> initialQuestions = const [],
  }) async {
    if (!await _ensureRemotePrivacyWarning()) {
      return;
    }
    if (!await _ensureRemoteAccount()) return;
    if (!mounted) {
      return;
    }
    final owner = controller.remoteAccountId;
    final sessionGeneration = controller.remoteDraftGeneration;
    BasicResumeComposeDraft? previous = _composeDraft;
    List<String> questions = initialQuestions;
    while (mounted && owner == controller.remoteAccountId) {
      final composeDraft = await showDialog<BasicResumeComposeDraft>(
        context: context,
        builder: (context) => BasicResumeComposeDialog(
          initialDraft: previous,
          questions: questions,
          onDraftChanged: (draft) {
            if (sessionGeneration == controller.remoteDraftGeneration) {
              _composeDraft = draft;
            }
          },
        ),
      );
      if (composeDraft == null ||
          !mounted ||
          owner != controller.remoteAccountId ||
          sessionGeneration != controller.remoteDraftGeneration) {
        return;
      }
      _composeTaskId ??= controller.createAiTaskId();
      final pendingChange = await controller.prepareBasicRemoteResume(
        composeDraft,
        taskId: _composeTaskId,
      );
      await _reloadUnfinishedTasks();
      if (!mounted || owner != controller.remoteAccountId) return;
      if (pendingChange != null) {
        _composeTaskId = null;
        await _reviewRemoteChange(pendingChange);
        return;
      }
      if (!_unfinishedTasks.any((e) => e.id == _composeTaskId)) {
        _composeTaskId = null;
      }
      questions = controller.latestRemoteMissingInformation;
      if (questions.isEmpty) {
        final taskRetained = _unfinishedTasks.any(
          (e) => e.id == _composeTaskId,
        );
        final requestNeedsQuery = (await controller.readRemoteOperations()).any(
          (record) =>
              record.accountId == controller.remoteAccountId &&
              record.capability == RemoteAiCapability.basicResumeCompose &&
              record.blocksNewRequest,
        );
        if (!mounted || owner != controller.remoteAccountId) return;
        final mayReturnToEditing = !taskRetained && !requestNeedsQuery;
        final feedback = controller.takeFeedback() ?? '本次未生成候选，本地简历未改变。';
        final returnToEditing = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('本次未生成候选'),
            content: SingleChildScrollView(
              child: Text(
                taskRetained
                    ? '$feedback\n\n输入草稿已保留。系统会优先恢复原任务，查询不会重新生成。'
                    : requestNeedsQuery
                    ? '$feedback\n\n本次输入仍保留在当前窗口。请先查询原请求状态，查询不会重新生成。'
                    : '$feedback\n\n本次输入仍保留在编辑窗口，可返回修改后再提交。',
              ),
            ),
            actions: [
              if (taskRetained || requestNeedsQuery)
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        RemoteOperationDialog(controller: controller),
                  ),
                  child: const Text('查看请求状态'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(context, mayReturnToEditing),
                child: Text(
                  taskRetained
                      ? '保留草稿并返回'
                      : requestNeedsQuery
                      ? '返回助手'
                      : '返回编辑',
                ),
              ),
            ],
          ),
        );
        if (returnToEditing == true && mounted) {
          previous = composeDraft;
          continue;
        }
        return;
      }
      previous = composeDraft;
      // Reopening only asks for user input. Each model request needs a new explicit submit.
    }
  }

  Future<bool> _ensureRemoteAccount() async {
    if (controller.remoteAccountSnapshot.isSignedIn) return true;
    if (!mounted) return false;
    await _showRemoteAccount();
    return mounted && controller.remoteAccountSnapshot.isSignedIn;
  }

  Future<bool> _ensureRemotePrivacyWarning() async {
    if (!await _ensureLegalRemoteConsent() || !mounted) return false;
    if (controller.remotePersonalDataWarningAcknowledged) {
      return true;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('联网 AI 隐私提醒'),
        content: const Text(
          '联网 AI 会把你本次明确提交的简历片段发送至在线 AI 服务。'
          '个人基础信息默认保留本地；本次选择允许后才会一并发送。'
          '生成结果会加密暂存最多24小时，用于断线后取回原结果，到期清理。'
          '请勿粘贴密码、验证码或无关敏感资料。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不使用'),
          ),
          FilledButton(
            key: const Key('确认联网AI隐私提醒'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('已了解，继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return false;
    }
    return controller.setRemotePersonalDataWarningAcknowledged(true);
  }

  Future<void> _reviewRemoteChange(
    PendingRemoteResumeChange pendingChange,
  ) async {
    PendingRemoteResumeChange? changeToReview = pendingChange;
    while (changeToReview != null) {
      if (!mounted) return;
      final reviewedChange = changeToReview;
      final reviewAction = await showDialog<RemoteResumeReviewAction>(
        context: context,
        barrierDismissible: false,
        builder: (context) =>
            RemoteResumeReviewDialog(pendingChange: reviewedChange),
      );
      if (!mounted) return;
      if (reviewAction != RemoteResumeReviewAction.accept &&
          reviewAction != RemoteResumeReviewAction.acceptWithFactReview) {
        if (!await controller.rejectPendingRemoteChange()) {
          _showFeedback();
          changeToReview = controller.pendingRemoteResumeChange;
          continue;
        }
        _showFeedback();
        return;
      }
      final saved = await controller.acceptPendingRemoteChange(
        confirmedSemanticReview:
            reviewAction == RemoteResumeReviewAction.acceptWithFactReview,
      );
      _showFeedback();
      if (saved) return;
      // 可恢复写入失败仍保留建议；重新提供确认/拒绝，绝不自动再次写入。
      changeToReview = controller.pendingRemoteResumeChange;
    }
  }

  void _showFeedback() {
    if (!mounted) {
      return;
    }
    final text = controller.takeFeedback();
    if (text == null) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            controller.currentDocument == null ? 16 : 96,
          ),
        ),
      );
  }
}

final class _ResumeImportPreviewDialog extends StatefulWidget {
  const _ResumeImportPreviewDialog({required this.pendingImport});

  final PendingResumeImport pendingImport;

  @override
  State<_ResumeImportPreviewDialog> createState() =>
      _ResumeImportPreviewDialogState();
}

final class _ResumeImportPreviewDialogState
    extends State<_ResumeImportPreviewDialog> {
  late final TextEditingController _titleController;
  String? _titleError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.pendingImport.suggestedTitle,
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pendingImport = widget.pendingImport;
    final preview = pendingImport.preview;
    final profile = preview.resume.profile;
    final mappedFacts = [
      (label: '姓名', value: profile.fullName),
      (label: '意向职业岗位', value: profile.headline),
      (label: '邮箱', value: profile.email),
      (label: '电话', value: profile.phone),
      (label: '所在地', value: profile.location),
    ].where((fact) => fact.value.isNotEmpty).toList();
    final unmappedLines = _readUnmappedImportLines(preview.resume);
    final createsNewDocument =
        pendingImport.target == ResumeImportTarget.newDocument;

    return AlertDialog(
      title: const Text('导入预览'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                createsNewDocument
                    ? '确认后创建新简历；关闭预览不会写入任何内容。'
                    : '确认后替换编辑区内容并追加一个 imported 版本，旧版本仍会保留。',
              ),
              const SizedBox(height: 16),
              if (createsNewDocument)
                TextField(
                  key: const Key('导入标题输入框'),
                  controller: _titleController,
                  decoration: InputDecoration(
                    labelText: '简历标题',
                    helperText: '简历标题仅用于区分不同简历，不会显示在导出的简历中。',
                    helperMaxLines: 2,
                    errorText: _titleError,
                  ),
                )
              else
                Text('目标简历：${pendingImport.suggestedTitle}'),
              const SizedBox(height: 16),
              Text('确定映射的基本信息', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (mappedFacts.isEmpty)
                const Text('没有识别到可确定映射的基本信息。')
              else
                for (final fact in mappedFacts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('${fact.label}：${fact.value}'),
                  ),
              const SizedBox(height: 12),
              Text(
                '未映射内容（${preview.unmappedLineCount} 行）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (unmappedLines.isEmpty)
                const Text('没有未映射内容。')
              else
                SizedBox(
                  height: unmappedLines.length > 4
                      ? 200
                      : unmappedLines.length * 44 + 8,
                  child: ListView.builder(
                    key: const Key('未映射内容列表'),
                    itemCount: unmappedLines.length,
                    itemBuilder: (context, index) {
                      final line = unmappedLines[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('第 ${line.lineNumber} 行：${line.text}'),
                      );
                    },
                  ),
                ),
              if (preview.validation.issues.isNotEmpty) ...[
                const SizedBox(height: 12),
                _ValidationIssues(issues: preview.validation.issues),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('确认导入'),
          onPressed: preview.canCommit ? _confirm : null,
          child: Text(createsNewDocument ? '创建并导入' : '导入为新版本'),
        ),
      ],
    );
  }

  void _confirm() {
    if (widget.pendingImport.target == ResumeImportTarget.newDocument &&
        _titleController.text.trim().isEmpty) {
      setState(() => _titleError = '请输入简历标题');
      return;
    }
    Navigator.pop(context, _titleController.text.trim());
  }
}

List<({int lineNumber, String text})> _readUnmappedImportLines(
  ResumeData importedResume,
) {
  final textImport = importedResume.unmapped['textImport'];
  if (textImport is! Map) {
    return const [];
  }
  final storedLines = textImport['lines'];
  if (storedLines is! List) {
    return const [];
  }
  return [
    for (final storedLine in storedLines)
      if (storedLine is Map &&
          storedLine['lineNumber'] is int &&
          storedLine['text'] is String)
        (
          lineNumber: storedLine['lineNumber']! as int,
          text: storedLine['text']! as String,
        ),
  ];
}

final class ResumeEditor extends StatefulWidget {
  const ResumeEditor({
    super.key,
    required this.controller,
    required this.document,
    required this.version,
    required this.onFeedback,
    this.photoPicker = const SystemResumePhotoPicker(),
  });

  final ResumeWorkspaceController controller;
  final ResumeDocument document;
  final ResumeVersion version;
  final VoidCallback onFeedback;
  final ResumePhotoPicker photoPicker;

  @override
  State<ResumeEditor> createState() => _ResumeEditorState();
}

final class _ResumeEditorState extends State<ResumeEditor> {
  static const _sectionSchemaKeys = {
    '工作经历': 'workExperiences',
    '教育经历': 'educations',
    '项目经历': 'projects',
    '技能分组': 'skillGroups',
    '证书': 'certifications',
    '语言': 'languages',
    '自定义区段': 'customSections',
  };

  late TextEditingController _resumeTitleController;
  late TextEditingController _fullNameController;
  late TextEditingController _headlineController;
  late TextEditingController _emailController;
  late TextEditingController _phoneController;
  late TextEditingController _locationController;
  late TextEditingController _profileLinksJsonController;
  late Map<String, TextEditingController> _sectionJsonControllers;
  late Map<TextEditingController, String> _loadedInputTexts;
  bool _hasChanges = false;
  bool _confirmingLeave = false;
  bool _saveAttempted = false;
  bool _importingPhoto = false;
  ResumePhoto? _draftPhoto;
  final _validationKey = GlobalKey();
  final _basicInformationKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  @override
  void didUpdateWidget(covariant ResumeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 主题更新保留草稿；只有 Application 确认切换到新版本才重新载入字段。
    if (oldWidget.version.id != widget.version.id) {
      _disposeInputs();
      _loadVersion();
      _hasChanges = false;
      _saveAttempted = false;
    }
  }

  void _loadVersion() {
    final currentProfile = widget.version.content.profile;
    _draftPhoto = currentProfile.photo;
    _resumeTitleController = TextEditingController(text: widget.document.title);
    _fullNameController = TextEditingController(text: currentProfile.fullName);
    _headlineController = TextEditingController(text: currentProfile.headline);
    _emailController = TextEditingController(text: currentProfile.email);
    _phoneController = TextEditingController(text: currentProfile.phone);
    _locationController = TextEditingController(text: currentProfile.location);
    final canonicalResumeJson = widget.version.content.toJson();
    _profileLinksJsonController = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(
        canonicalResumeJson['profile'] is Map
            ? (canonicalResumeJson['profile'] as Map)['links']
            : const [],
      ),
    );
    // UI 标题和 Schema key 只维护一份映射，避免新增区段时读写顺序不一致。
    _sectionJsonControllers = {
      for (final sectionSchemaKey in _sectionSchemaKeys.entries)
        sectionSchemaKey.key: _createJsonTextController(
          canonicalResumeJson[sectionSchemaKey.value],
        ),
    };
    _loadedInputTexts = {
      for (final input in [
        _resumeTitleController,
        _fullNameController,
        _headlineController,
        _emailController,
        _phoneController,
        _locationController,
        _profileLinksJsonController,
        ..._sectionJsonControllers.values,
      ])
        input: input.text,
    };
    for (final input in _loadedInputTexts.keys) {
      input.addListener(_updateDirtyState);
    }
  }

  void _updateDirtyState() {
    var changed = true;
    try {
      changed =
          _resumeTitleController.text.trim() != widget.document.title ||
          !jsonDeepEquals(
            _buildEditedResumeContent().toJson(),
            widget.version.content.toJson(),
          );
    } on FormatException {
      // 不完整的输入也属于未保存内容，不能因暂时无法解析而放弃保护。
      changed = true;
    }
    if (mounted) setState(() => _hasChanges = changed);
  }

  bool get _editingLocked =>
      _importingPhoto ||
      widget.controller.isBusy ||
      widget.controller.pendingResumeSuggestion != null ||
      widget.controller.pendingRemoteResumeChange != null;

  Future<bool> confirmLeaving() async {
    if (_importingPhoto) return false;
    if (!_hasChanges) return true;
    if (_confirmingLeave) return false;
    _confirmingLeave = true;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.edit_note_rounded),
        title: const Text('保存这次修改？'),
        content: const Text('这份简历还有未保存的内容。保存后会创建一个新版本，之前的版本仍会保留。'),
        actions: [
          TextButton(
            key: const Key('继续编辑'),
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('继续编辑'),
          ),
          TextButton(
            key: const Key('放弃修改'),
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('放弃修改'),
          ),
          FilledButton(
            key: const Key('保存并继续'),
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('保存并继续'),
          ),
        ],
      ),
    );
    _confirmingLeave = false;
    if (!mounted) return false;
    if (choice == 'discard') {
      _draftPhoto = widget.version.content.profile.photo;
      for (final input in _loadedInputTexts.entries) {
        input.key.text = input.value;
      }
      _updateDirtyState();
      return true;
    }
    if (choice == 'save') return _save();
    return false;
  }

  @override
  void dispose() {
    _disposeInputs();
    super.dispose();
  }

  void _disposeInputs() {
    _resumeTitleController.dispose();
    _fullNameController.dispose();
    _headlineController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _locationController.dispose();
    _profileLinksJsonController.dispose();
    for (final sectionJsonController in _sectionJsonControllers.values) {
      sectionJsonController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Column(
      children: [
        if (widget.version.content.extensions.containsKey(
          ResumeAiProvenance.extensionKey,
        ))
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(ResumeAiProvenance.notice),
          ),
        Expanded(
          child: SingleChildScrollView(
            key: const Key('编辑器滚动区'),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const WorkspaceEyebrow(
                      icon: Icons.lock_outline_rounded,
                      text: '编辑保存在本机的简历',
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '把你的经历，认真写下来。',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '逐项填写即可。每次保存都有记录，随时可以回看。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    _EditorSection(
                      key: _basicInformationKey,
                      title: '基本信息',
                      child: Column(
                        children: [
                          ResumeProfileFields(
                            title: _resumeTitleController,
                            fullName: _fullNameController,
                            headline: _headlineController,
                            email: _emailController,
                            phone: _phoneController,
                            location: _locationController,
                            links: _profileLinksJsonController,
                            photo: _draftPhoto,
                            photoPicker: widget.photoPicker,
                            enabled: !_editingLocked,
                            titleError:
                                _saveAttempted &&
                                    _resumeTitleController.text.trim().isEmpty
                                ? '请填写简历标题'
                                : null,
                            emailError: _emailError,
                            onPhotoChanged: (photo) {
                              setState(() => _draftPhoto = photo);
                              _updateDirtyState();
                            },
                            onPhotoBusyChanged: (busy) =>
                                setState(() => _importingPhoto = busy),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final sectionController
                        in _sectionJsonControllers.entries) ...[
                      _buildCollectionSection(
                        sectionName: sectionController.key,
                        textController: sectionController.value,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_readUnmappedImportLines(widget.version.content)
                        case final preservedLines
                        when preservedLines.isNotEmpty)
                      Card(
                        child: ExpansionTile(
                          key: const Key('保留的导入内容'),
                          leading: const Icon(Icons.notes_rounded),
                          title: Text('保留的导入内容（${preservedLines.length} 行）'),
                          subtitle: const Text('未自动归类的原文仍完整保留，可对照补充到相应区段'),
                          childrenPadding: const EdgeInsets.all(20),
                          expandedCrossAxisAlignment:
                              CrossAxisAlignment.stretch,
                          children: [
                            for (final line in preservedLines)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: SelectableText(
                                  '第 ${line.lineNumber} 行：${line.text}',
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (controller.validationIssues.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _ValidationIssues(
                        key: _validationKey,
                        issues: controller.validationIssues,
                      ),
                    ],
                    if (controller.latestLocalAgentCheck
                        case final checkResult?) ...[
                      const SizedBox(height: 12),
                      _LocalAgentCheckCard(checkResult: checkResult),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          key: Key(
                            controller.isLocalAgentCheckRunning
                                ? '取消本地检查'
                                : '本地检查已保存版本',
                          ),
                          onPressed: controller.isLocalAgentCheckRunning
                              ? controller.cancelLocalAgentCheck
                              : controller.isBusy ||
                                    controller.pendingResumeSuggestion != null
                              ? null
                              : _runLocalAgentCheck,
                          icon: Icon(
                            controller.isLocalAgentCheckRunning
                                ? Icons.stop_circle_outlined
                                : Icons.rule_outlined,
                          ),
                          label: Text(
                            controller.isLocalAgentCheckRunning
                                ? '取消检查'
                                : '本地检查',
                          ),
                        ),
                        OutlinedButton.icon(
                          key: const Key('复制简历'),
                          onPressed:
                              controller.isBusy ||
                                  controller.pendingResumeSuggestion != null
                              ? null
                              : _duplicate,
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('复制'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('删除简历'),
                          onPressed:
                              controller.isBusy ||
                                  controller.pendingResumeSuggestion != null
                              ? null
                              : _delete,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除'),
                        ),
                        FilledButton.icon(
                          key: const Key('打开Word文稿'),
                          onPressed: _editingLocked
                              ? null
                              : () => _handleExportAction(
                                  _ResumeExportAction.word,
                                ),
                          icon: const Icon(Icons.description_outlined),
                          label: const Text('导出 Word'),
                        ),
                        PopupMenuButton<_ResumeExportAction>(
                          key: const Key('导出菜单'),
                          tooltip: '导出已保存版本',
                          enabled: !_editingLocked,
                          onSelected: _handleExportAction,
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: _ResumeExportAction.word,
                              child: Text('Word 文稿（默认）'),
                            ),
                            PopupMenuItem(
                              value: _ResumeExportAction.markdown,
                              child: Text('导出 Markdown'),
                            ),
                            PopupMenuItem(
                              value: _ResumeExportAction.json,
                              child: Text('导出 JSON'),
                            ),
                            PopupMenuItem(
                              value: _ResumeExportAction.pdfPreview,
                              child: Text('预览并导出 PDF'),
                            ),
                          ],
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 48),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.download_outlined, size: 18),
                                SizedBox(width: 8),
                                Text('导出已保存版本'),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: ExpansionTile(
                        key: const Key('版本历史'),
                        title: Text('版本历史（${controller.versions.length}）'),
                        subtitle: const Text('保存的每一步，都能在这里找回'),
                        children: [
                          for (final version in controller.versions)
                            ListTile(
                              leading: Icon(
                                version.id == controller.currentVersion?.id
                                    ? Icons.check_circle
                                    : Icons.history,
                              ),
                              title: Text(
                                _resumeVersionSourceLabel(version.source),
                              ),
                              subtitle: Text(
                                _formatLocalTime(version.createdAt),
                              ),
                              trailing:
                                  version.id == controller.currentVersion?.id
                                  ? null
                                  : TextButton(
                                      key: Key('恢复版本_${version.id}'),
                                      onPressed:
                                          controller.isBusy ||
                                              controller
                                                      .pendingResumeSuggestion !=
                                                  null
                                          ? null
                                          : () => _restore(version.id),
                                      child: const Text('恢复'),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _hasChanges ? '有未保存的修改' : '已保存到本机',
                            key: const Key('保存状态'),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        key: const Key('保存新版本'),
                        onPressed: _editingLocked ? null : _save,
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('保存'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  String? get _emailError {
    if (!_saveAttempted) return null;
    try {
      final issues = const ResumeValidator()
          .validate(_buildEditedResumeContent())
          .issues;
      for (final issue in issues) {
        if (issue.path == '/profile/email' && issue.blocksCommit) {
          return issue.message;
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<bool> _save() async {
    if (_importingPhoto) return false;
    setState(() => _saveAttempted = true);
    var saved = false;
    try {
      final editedResumeContent = _buildEditedResumeContent();
      final outcome = await widget.controller.saveContent(
        title: _resumeTitleController.text,
        content: editedResumeContent,
      );
      saved = outcome == SaveOutcome.saved || outcome == SaveOutcome.unchanged;
      if (outcome == SaveOutcome.unchanged && mounted) {
        _updateDirtyState();
      }
    } on FormatException {
      widget.controller.formError = '有内容尚未填写完整，请检查对应区段。';
    }
    widget.onFeedback();
    if (!saved && mounted) {
      final target =
          _emailError != null || _resumeTitleController.text.trim().isEmpty
          ? _basicInformationKey.currentContext
          : _validationKey.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 220),
        );
      }
    }
    return saved;
  }

  Future<void> _runLocalAgentCheck() async {
    if (!await confirmLeaving() || !mounted) return;
    await widget.controller.runLocalAgentCheck();
    widget.onFeedback();
  }

  ResumeData _buildEditedResumeContent() {
    // 从已保存内容开始，只替换表单负责的字段。
    // 从空对象重建会丢失未展示的扩展、稳定 ID 和 unmapped 原文。
    final editableCanonicalJson = widget.version.content.toJson();
    final editableProfileJson = Map<String, Object?>.from(
      editableCanonicalJson['profile']! as Map,
    );
    editableProfileJson['fullName'] = _fullNameController.text.trim();
    editableProfileJson['headline'] = _headlineController.text.trim();
    editableProfileJson['email'] = _emailController.text.trim();
    editableProfileJson['phone'] = _phoneController.text.trim();
    editableProfileJson['location'] = _locationController.text.trim();
    if (_draftPhoto == null) {
      editableProfileJson.remove('photo');
    } else {
      editableProfileJson['photo'] = _draftPhoto!.toJson();
    }
    editableProfileJson['links'] = _decodeJsonArray(
      _profileLinksJsonController.text,
      '个人链接',
    );
    editableCanonicalJson['profile'] = editableProfileJson;
    for (final sectionController in _sectionJsonControllers.entries) {
      final schemaKey = _sectionSchemaKeys[sectionController.key]!;
      editableCanonicalJson[schemaKey] = _decodeJsonArray(
        sectionController.value.text,
        sectionController.key,
      );
    }
    // fromJson 拒绝错误结构/日期；业务必填、邮箱和全局 ID 再由 saveContent 校验。
    return ResumeData.fromJson(editableCanonicalJson);
  }

  List<Object?> _decodeJsonArray(String jsonText, String sectionName) {
    final decodedJson = jsonDecode(jsonText);
    if (decodedJson is! List) {
      throw FormatException('$sectionName 必须是 JSON 数组');
    }
    return decodedJson;
  }

  TextEditingController _createJsonTextController(Object? jsonValue) =>
      TextEditingController(
        text: const JsonEncoder.withIndent('  ').convert(jsonValue ?? const []),
      );

  Widget _buildCollectionSection({
    required String sectionName,
    required TextEditingController textController,
  }) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: textController,
      builder: (context, value, _) {
        int? entryCount;
        try {
          final entries = jsonDecode(value.text);
          if (entries is List) entryCount = entries.length;
        } on FormatException {
          // 解析失败仍展示原组件的恢复提示，不把原始内容替换成空集合。
        }
        return Card(
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: Key('展开区段_$sectionName'),
            initiallyExpanded: entryCount != 0,
            maintainState: true,
            leading: Icon(
              _sectionIcon(sectionName),
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(sectionName),
            subtitle: Text(
              entryCount == null
                  ? '原始内容需要检查'
                  : entryCount == 0
                  ? '按需添加'
                  : '$entryCount 条内容',
            ),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 8,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              ResumeCollectionEditor(
                key: Key('$sectionName结构化输入'),
                controller: textController,
                sectionKey: sectionName == '个人链接'
                    ? 'links'
                    : _sectionSchemaKeys[sectionName]!,
                enabled: !_editingLocked,
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _duplicate() async {
    if (!await confirmLeaving()) return;
    await widget.controller.duplicateCurrent();
    widget.onFeedback();
  }

  Future<void> _delete() async {
    final deleteConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除简历？'),
        content: const Text('删除后文档及其历史版本不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (deleteConfirmed == true) {
      await widget.controller.deleteDocument(widget.document.id);
      widget.onFeedback();
    }
  }

  Future<void> _restore(String versionId) async {
    if (!await confirmLeaving() || !mounted) return;
    final restoreConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复历史版本？'),
        content: const Text('所选内容会保存为一个新的“历史恢复”版本，现有历史仍会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (restoreConfirmed == true) {
      await widget.controller.restoreVersion(versionId);
      widget.onFeedback();
    }
  }

  Future<void> _export(ResumeExportFormat format) async {
    await widget.controller.deliverCurrentText(format);
    if (mounted) widget.onFeedback();
  }

  Future<void> _handleExportAction(_ResumeExportAction action) async {
    if (!await confirmLeaving() || !mounted) return;
    switch (action) {
      case _ResumeExportAction.word:
        final document = widget.controller.currentDocument;
        final version = widget.controller.currentVersion;
        if (document == null || version == null) return;
        final word = await widget.controller.openCurrentWord();
        if (!mounted) return;
        if (word == null) {
          widget.onFeedback();
          return;
        }
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => ResumeWordPage(
              controller: widget.controller,
              document: document,
              version: version,
              word: word,
            ),
          ),
        );
        return;
      case _ResumeExportAction.markdown:
        await _export(ResumeExportFormat.markdown);
        return;
      case _ResumeExportAction.json:
        await _export(ResumeExportFormat.json);
        return;
      case _ResumeExportAction.pdfPreview:
        final preparedPdf = await widget.controller.prepareCurrentPdf();
        if (!mounted) {
          return;
        }
        if (preparedPdf == null) {
          widget.onFeedback();
          return;
        }
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => ResumePdfPreviewPage(
              controller: widget.controller,
              preparedPdf: preparedPdf,
            ),
          ),
        );
        return;
    }
  }
}

final class _EditorSection extends StatelessWidget {
  const _EditorSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _sectionIcon(title),
                  color: Theme.of(context).colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

final class _ValidationIssues extends StatelessWidget {
  const _ValidationIssues({super.key, required this.issues});

  final List<ValidationIssue> issues;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('验证结果', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final issue in issues)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      issue.blocksCommit
                          ? Icons.error_outline
                          : Icons.info_outline,
                      size: 20,
                      color: issue.blocksCommit
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${issue.message}（${issue.path}）')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _LocalAgentCheckCard extends StatelessWidget {
  const _LocalAgentCheckCard({required this.checkResult});

  final LocalAgentCheckResult checkResult;

  @override
  Widget build(BuildContext context) {
    final checkCompleted =
        checkResult.status == LocalAgentCheckStatus.completed;
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本地检查结果', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(_localAgentStatusLabel(checkResult.status)),
            if (checkCompleted) ...[
              const SizedBox(height: 8),
              Text('需要留意：${checkResult.validationIssueCount} 项'),
              Text('精确重复内容：${checkResult.repeatedContentGroupCount} 组'),
              if (checkResult.validationIssueCount == 0 &&
                  checkResult.repeatedContentGroupCount == 0)
                const Text('未发现格式、基本信息遗漏或精确重复问题。'),
              for (final finding in checkResult.findings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${_localCheckLocation(finding.path)}：${finding.message}',
                  ),
                ),
            ],
            const SizedBox(height: 8),
            const Text('离线检查当前已保存版本的格式与基本信息。不会自动修改，也不判断经历真假或代替AI优化。'),
          ],
        ),
      ),
    );
  }
}

final class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
          ],
        ),
      ),
    );
  }
}

final class _CreateResumeInput {
  const _CreateResumeInput(this.title, this.fullName);

  final String title;
  final String fullName;
}

final class _CreateResumeDialog extends StatefulWidget {
  const _CreateResumeDialog();

  @override
  State<_CreateResumeDialog> createState() => _CreateResumeDialogState();
}

final class _CreateResumeDialogState extends State<_CreateResumeDialog> {
  final _title = TextEditingController();
  final _name = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建简历'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('新建标题输入框'),
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                labelText: '简历标题',
                hintText: '例如：前端工程师 · 秋招',
                helperText: '简历标题仅用于区分不同简历，不会显示在导出的简历中。',
                helperMaxLines: 2,
                errorText: _error,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('新建姓名输入框'),
              controller: _name,
              decoration: const InputDecoration(labelText: '姓名（可稍后填写）'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('确认新建简历'),
          onPressed: () {
            if (_title.text.trim().isEmpty) {
              setState(() => _error = '请输入简历标题');
              return;
            }
            Navigator.pop(context, _CreateResumeInput(_title.text, _name.text));
          },
          child: const Text('创建'),
        ),
      ],
    );
  }
}

String _formatLocalTime(DateTime timestamp) {
  final localTime = timestamp.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${localTime.year}-${two(localTime.month)}-${two(localTime.day)} '
      '${two(localTime.hour)}:${two(localTime.minute)}';
}

IconData _sectionIcon(String title) => switch (title) {
  '基本信息' => Icons.person_outline_rounded,
  '工作经历' => Icons.work_outline_rounded,
  '教育经历' => Icons.school_outlined,
  '项目经历' => Icons.widgets_outlined,
  '技能分组' => Icons.bolt_outlined,
  '证书' => Icons.workspace_premium_outlined,
  '语言' => Icons.language_outlined,
  _ => Icons.view_agenda_outlined,
};

String _resumeVersionSourceLabel(ResumeVersionSource source) =>
    switch (source) {
      ResumeVersionSource.created => '创建',
      ResumeVersionSource.edited => '手动编辑',
      ResumeVersionSource.imported => '导入',
      ResumeVersionSource.aiConfirmed => 'AI 建议（已确认）',
      ResumeVersionSource.restored => '历史恢复',
      ResumeVersionSource.migrated => '数据迁移',
    };

String _localAgentStatusLabel(LocalAgentCheckStatus status) {
  return switch (status) {
    LocalAgentCheckStatus.completed => '检查完成',
    LocalAgentCheckStatus.networkDisabled => '联网关闭且本地能力不可用',
    LocalAgentCheckStatus.capabilityUnavailable => '本地能力不足',
    LocalAgentCheckStatus.cancelled => '检查已取消',
    LocalAgentCheckStatus.timedOut => '检查已超时',
    LocalAgentCheckStatus.providerFailed => '本地检查服务暂不可用',
    LocalAgentCheckStatus.invalidPlan => '不安全或无效的计划已拒绝',
    LocalAgentCheckStatus.failed => '检查失败',
  };
}

String _localCheckLocation(String path) {
  const names = {
    'profile': '基本信息',
    'fullName': '姓名',
    'phone': '电话',
    'email': '邮箱',
    'workExperiences': '工作经历',
    'educations': '教育经历',
    'projects': '项目经历',
    'organization': '单位',
    'position': '职位',
    'institution': '学校',
    'dateRange': '时间范围',
    'name': '名称',
    'skillGroups': '技能',
  };
  return path
      .split('/')
      .where((part) => part.isNotEmpty)
      .map((part) {
        final index = int.tryParse(part);
        return index == null ? (names[part] ?? part) : '第${index + 1}项';
      })
      .join(' · ');
}
