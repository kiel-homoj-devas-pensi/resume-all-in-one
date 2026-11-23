import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:resume_domain/resume_domain.dart';

import 'gateway_api_client.dart';
import 'remote_account_service.dart';
import 'remote_operation_journal.dart';
import 'remote_resume_ai_service.dart';
import 'resume_workspace_controller.dart';
import 'account_lifecycle_dialog.dart';
import 'account_password_policy.dart';
import 'account_form_focus.dart';
import 'resume_profile_fields.dart';
import 'resume_review_format.dart';
import 'legal_consent_pages.dart' show showBundledPrivacyPolicy;

enum RemoteResumeReviewAction { accept, acceptWithFactReview, reject }

final class _AiRecipientNotice extends StatelessWidget {
  const _AiRecipientNotice();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '接收方：北京智谱华章科技股份有限公司。材料经本服务后端发送，用于本次AI生成并返回候选。智谱可能按其规则将匿名化数据用于训练；请检查材料后自行选择是否发送。此处同意仅针对本次发送。',
      ),
      TextButton(
        onPressed: () => showBundledPrivacyPolicy(context),
        child: const Text('查看隐私政策和接收方说明'),
      ),
    ],
  );
}

final class TargetedOptimizationDraft {
  TargetedOptimizationDraft({
    required this.targetJobTitle,
    required this.jobDescription,
    required this.userInstruction,
    required Set<RemotePersonalDataField> selectedPersonalFields,
    this.confirmedInputSharing = false,
    this.sharePersonalData,
  }) : selectedPersonalFields = Set.unmodifiable(selectedPersonalFields);

  final String targetJobTitle;
  final String jobDescription;
  final String userInstruction;
  final bool confirmedInputSharing;
  final bool? sharePersonalData;
  final Set<RemotePersonalDataField> selectedPersonalFields;
}

final class RemoteConversationDraft {
  RemoteConversationDraft({
    required this.targetJobTitle,
    required this.jobDescription,
    required this.userMessage,
    required Set<RemotePersonalDataField> selectedPersonalFields,
    this.confirmedInputSharing = false,
    this.sharePersonalData,
  }) : selectedPersonalFields = Set.unmodifiable(selectedPersonalFields);

  final String targetJobTitle;
  final String jobDescription;
  final String userMessage;
  final bool confirmedInputSharing;
  final bool? sharePersonalData;
  final Set<RemotePersonalDataField> selectedPersonalFields;
}

final class RemoteAccountDialog extends StatefulWidget {
  const RemoteAccountDialog({
    super.key,
    required this.controller,
    required this.onFeedback,
  });

  final ResumeWorkspaceController controller;
  final VoidCallback onFeedback;

  @override
  State<RemoteAccountDialog> createState() => _RemoteAccountDialogState();
}

final class _RemoteAccountDialogState extends State<RemoteAccountDialog>
    with WidgetsBindingObserver, AccountFormFocus<RemoteAccountDialog> {
  final _phoneController = TextEditingController(text: '+15550001234');
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.supportsAccountLifecycle) {
      return AccountLifecycleDialog(
        controller: widget.controller,
        onFeedback: widget.onFeedback,
      );
    }
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final accountSnapshot = widget.controller.remoteAccountSnapshot;
        return NotificationListener<ScrollStartNotification>(
          onNotification: onAccountFormScroll,
          child: AlertDialog(
            scrollable: true,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            actionsOverflowButtonSpacing: 8,
            title: const Text('账号与 AI 额度'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (accountSnapshot.status ==
                      RemoteAccountSessionStatus.gatewayUnavailable)
                    const _RemoteFlowNotice(
                      icon: Icons.cloud_off_outlined,
                      title: '联网服务尚未配置',
                      message: '本次构建没有配置开发 Gateway。你可以继续在本机编辑、检查和导出简历。',
                    )
                  else if (!accountSnapshot.isSignedIn) ...[
                    const _RemoteFlowNotice(
                      icon: Icons.science_outlined,
                      title: '仅供开发测试',
                      message: '账号使用 Fake 验证，仅接受合成手机号。不会发送真实短信，请勿输入真实手机号。',
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      key: const Key('开发账号手机号'),
                      controller: _phoneController,
                      focusNode: accountFocus(_phoneController),
                      enabled: !widget.controller.isBusy,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) =>
                          focusAccountField(_passwordController),
                      decoration: const InputDecoration(
                        labelText: '合成手机号',
                        helperText: '格式：+1555000xxxx',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('开发账号密码'),
                      controller: _passwordController,
                      focusNode: accountFocus(_passwordController),
                      enabled: !widget.controller.isBusy,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!widget.controller.isBusy) {
                          _authenticate(register: false);
                        }
                      },
                      decoration: const InputDecoration(
                        labelText: '密码',
                        helperText: newPasswordRule,
                        helperMaxLines: 4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          key: const Key('登录开发账号'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(64, 48),
                          ),
                          onPressed: widget.controller.isBusy
                              ? null
                              : () => _authenticate(register: false),
                          child: const Text('登录'),
                        ),
                        OutlinedButton(
                          key: const Key('注册开发账号'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(64, 48),
                          ),
                          onPressed: widget.controller.isBusy
                              ? null
                              : () => _authenticate(register: true),
                          child: const Text('注册并登录'),
                        ),
                      ],
                    ),
                  ] else ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.account_circle_outlined),
                      title: Text(accountSnapshot.maskedPhone ?? '账号'),
                      subtitle: Text(
                        '套餐：${_planLabel(accountSnapshot.plan)}\n'
                        '令牌仅保存在本次进程内',
                      ),
                    ),
                    if (accountSnapshot.privileges case final privileges?)
                      ListTile(
                        key: const Key('账号身份与会员'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          privileges.role == GatewayAccountRole.admin
                              ? '管理员'
                              : '普通用户',
                        ),
                        subtitle: Text(
                          privileges.membership == GatewayMembership.permanent
                              ? '永久会员 · 无需缴费续期'
                              : '未授予永久会员',
                        ),
                      )
                    else
                      const Text('服务未提供永久会员与管理员身份信息。'),
                    for (final capability in const [
                      RemoteAiCapability.basicResumeCompose,
                      RemoteAiCapability.targetedResumeOptimization,
                    ])
                      _AccessSnapshotTile(
                        capability: capability,
                        snapshot:
                            accountSnapshot.accessByCapability[capability],
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: widget.controller.isBusy ? null : _refresh,
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('查询联网操作'),
                          onPressed: widget.controller.isBusy
                              ? null
                              : () => showDialog<void>(
                                  context: context,
                                  builder: (_) => RemoteOperationDialog(
                                    controller: widget.controller,
                                  ),
                                ),
                          icon: const Icon(Icons.receipt_long_outlined),
                          label: const Text('联网操作记录'),
                        ),
                        TextButton(
                          onPressed: widget.controller.isBusy
                              ? null
                              : () {
                                  widget.controller.signOutRemoteAccount();
                                  widget.onFeedback();
                                },
                          child: const Text('退出本机登录'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: widget.controller.isBusy
                    ? null
                    : () => Navigator.pop(context),
                child: const Text('退出'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _authenticate({required bool register}) async {
    FocusScope.of(context).unfocus();
    if (register) {
      await widget.controller.registerRemoteAccount(
        phoneE164: _phoneController.text,
        password: _passwordController.text,
      );
    } else {
      await widget.controller.signInRemoteAccount(
        phoneE164: _phoneController.text,
        password: _passwordController.text,
      );
    }
    if (mounted) {
      widget.onFeedback();
    }
  }

  Future<void> _refresh() async {
    await widget.controller.refreshRemoteAccess();
    if (mounted) {
      widget.onFeedback();
    }
  }
}

final class RemoteOperationDialog extends StatefulWidget {
  const RemoteOperationDialog({super.key, required this.controller});
  final ResumeWorkspaceController controller;
  @override
  State<RemoteOperationDialog> createState() => _RemoteOperationDialogState();
}

final class _RemoteOperationDialogState extends State<RemoteOperationDialog> {
  late Future<List<RemoteOperationRecord>> _records = widget.controller
      .readRemoteOperations();
  bool _busy = false;
  String? _error;
  Future<void> _query(RemoteOperationRecord record) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.controller.queryRemoteOperation(record);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _records = widget.controller.readRemoteOperations();
      _error = result == null ? widget.controller.formError : null;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('联网操作记录'),
    content: SizedBox(
      width: 520,
      child: FutureBuilder<List<RemoteOperationRecord>>(
        future: _records,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Text('操作记录无法读取，请保留本地数据；不要重复生成。');
          if (!snapshot.hasData) return const LinearProgressIndicator();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('查询只查看原任务，不会重新生成。退出登录或关闭联网不会撤销已经开始的任务。'),
              if (_error != null) Text(_error!),
              if (snapshot.data!.isEmpty) const Text('当前账号没有本地操作记录。'),
              for (final record in snapshot.data!.reversed)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_remoteCapabilityLabel(record.capability)),
                        Text(switch (record.status) {
                          'sent' || 'unknown' || 'notFound' => '正在确认原任务，请稍后查看。',
                          'reserved' => 'AI正在处理原任务。',
                          'pendingReconciliation' =>
                            '本次任务暂未完成，系统保留原任务记录；其他任务可继续。',
                          'committed' => '原任务已完成，可继续取回结果。',
                          'released' => '本次任务未完成，简历保持不变。',
                          'received' => '已收到原任务结果。',
                          'acknowledged' => '历史任务记录已保留。',
                          'expired' => '原结果已超过恢复保留期，本地简历保持不变。',
                          _ => '未知状态',
                        }),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: _busy ? null : () => _query(record),
                              child: const Text('查询状态'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  );
}

final class _AccessSnapshotTile extends StatelessWidget {
  const _AccessSnapshotTile({required this.capability, required this.snapshot});

  final RemoteAiCapability capability;
  final GatewayAccessSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final accessSnapshot = snapshot;
    final remaining =
        accessSnapshot?.remainingMonthlyGenerations ??
        accessSnapshot?.remainingMonthlyBasicGenerations;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        accessSnapshot?.allowed == true
            ? Icons.check_circle_outline
            : Icons.lock_outline,
      ),
      title: Text(_remoteCapabilityLabel(capability)),
      subtitle: Text(
        accessSnapshot?.isUnlimited == true
            ? '当前不限次数；安全限流和服务状态仍然适用。'
            : remaining == null
            ? _accessReasonLabel(accessSnapshot?.reason)
            : '本月剩余 $remaining 份${accessSnapshot?.monthlyLimit == null ? '' : ' / ${accessSnapshot!.monthlyLimit}份'}；按有效候选计次，未完成任务可继续。',
      ),
    );
  }
}

final class BasicResumeComposeDialog extends StatefulWidget {
  const BasicResumeComposeDialog({
    super.key,
    this.initialDraft,
    this.questions = const [],
    this.onDraftChanged,
  });
  final BasicResumeComposeDraft? initialDraft;
  final List<String> questions;
  final ValueChanged<BasicResumeComposeDraft>? onDraftChanged;
  @override
  State<BasicResumeComposeDialog> createState() =>
      _BasicResumeComposeDialogState();
}

final class _BasicResumeComposeDialogState
    extends State<BasicResumeComposeDialog> {
  final _title = TextEditingController(text: '我的简历');
  final _name = TextEditingController(), _headline = TextEditingController();
  final _email = TextEditingController(), _phone = TextEditingController();
  final _location = TextEditingController(), _source = TextEditingController();
  final _links = TextEditingController(text: '[]');
  final _selectedFields = <RemotePersonalDataField>{};
  ResumePhoto? _photo;
  bool _photoBusy = false, _attempted = false;
  String? _error;
  List<TextEditingController> get _controllers => [
    _title,
    _name,
    _headline,
    _email,
    _phone,
    _location,
    _source,
    _links,
  ];
  @override
  void initState() {
    super.initState();
    if (widget.initialDraft case final draft?) {
      _title.text = draft.documentTitle;
      _name.text = draft.fullName;
      _headline.text = draft.headline;
      _email.text = draft.email;
      _phone.text = draft.phone;
      _location.text = draft.preciseAddress;
      _source.text = draft.sourceText;
      _photo = draft.photo;
      _links.text = jsonEncode(
        draft.links.map((link) => link.toJson()).toList(),
      );
    }
    for (final controller in _controllers) {
      controller.addListener(_inputChanged);
    }
  }

  BasicResumeComposeDraft _draft({bool submitting = false}) =>
      BasicResumeComposeDraft(
        documentTitle: _title.text,
        sourceText: _source.text,
        fullName: _name.text,
        headline: _headline.text,
        phone: _phone.text,
        email: _email.text,
        preciseAddress: _location.text,
        photo: _photo,
        links: (jsonDecode(_links.text) as List)
            .map(
              (value) =>
                  ResumeLink.fromJson(Map<String, Object?>.from(value as Map)),
            )
            .toList(),
        selectedPersonalFields: _selectedFields,
        sharePersonalData: _selectedFields.isNotEmpty,
        naturalLanguageInput: true,
        confirmedInputSharing: submitting,
      );
  void _inputChanged() {
    if (_selectedFields.isNotEmpty || _attempted) {
      setState(() {
        _selectedFields.clear();
        _error = null;
      });
    }
    _remember();
  }

  void _remember() => widget.onDraftChanged?.call(_draft());
  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  String? get _emailError => !_attempted
      ? null
      : _draft().profileValidationIssues
            .where(
              (issue) => issue.path == '/profile/email' && issue.blocksCommit,
            )
            .firstOrNull
            ?.message;
  void _submit() {
    setState(() => _attempted = true);
    final draft = _draft(submitting: true);
    if (_title.text.trim().isEmpty ||
        _source.text.trim().isEmpty ||
        draft.profileValidationIssues.any((issue) => issue.blocksCommit)) {
      setState(() => _error = '请检查基础信息，并写下一些真实经历；不需要按模板整理。');
      return;
    }
    Navigator.pop(context, draft);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    actionsOverflowButtonSpacing: 8,
    title: const Text('AI 创建简历'),
    content: SizedBox(
      width: 620,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('个人基础信息', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ResumeProfileFields(
            title: _title,
            fullName: _name,
            headline: _headline,
            email: _email,
            phone: _phone,
            location: _location,
            links: _links,
            photo: _photo,
            onPhotoChanged: (photo) {
              setState(() => _photo = photo);
              _remember();
            },
            onPhotoBusyChanged: (busy) => setState(() => _photoBusy = busy),
            titleError: _attempted && _title.text.trim().isEmpty
                ? '请填写简历标题'
                : null,
            emailError: _emailError,
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('AI碎片信息'),
            controller: _source,
            minLines: 5,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: '经历与能力',
              floatingLabelBehavior: FloatingLabelBehavior.always,
              alignLabelWithHint: true,
              hintText: '去年学校做过一个小程序，跟同学一起写页面，想找前端，数据库也碰过一点……',
              helperText: '随意说或整段粘贴即可，顺序、标题、日期格式都不必整理。最多20000字。',
              helperMaxLines: 4,
            ),
          ),
          if (widget.questions.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('本次尚未生成可用候选，原材料已保留：'),
            for (final question in widget.questions) Text(question),
          ],
          PersonalDataSelector(
            selectedFields: _selectedFields,
            onChanged: () {
              setState(() {});
              _remember();
            },
          ),
          TextButton.icon(
            key: const Key('查看AI发送材料'),
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('查看发送材料'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                scrollable: true,
                title: const Text('本次发送的经历材料'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '如有不想发送的内容，请返回“经历与能力”修改。自动隐藏无法识别全部个人信息；基础信息按本次整体选择处理，照片不会发送。',
                    ),
                    const SizedBox(height: 16),
                    SelectableText(_draft().remoteMaterialPreview),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回编辑'),
                  ),
                ],
              ),
            ),
          ),
          const Text(
            '点击“同意发送并生成”会发送上方经历材料，基础信息按本次选择处理，照片留在本机。请勿粘贴密码、验证码或无关敏感资料。',
          ),
          const _AiRecipientNotice(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _photoBusy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('提交基础生成'),
        onPressed: _photoBusy ? null : _submit,
        child: const Text('同意发送并生成'),
      ),
    ],
  );
}

final class TargetedOptimizationDialog extends StatefulWidget {
  const TargetedOptimizationDialog({
    super.key,
    this.initialDraft,
    this.onDraftChanged,
    this.documentTitle = '',
    this.initialJobTitle = '',
  });
  final TargetedOptimizationDraft? initialDraft;
  final ValueChanged<TargetedOptimizationDraft>? onDraftChanged;
  final String documentTitle, initialJobTitle;
  @override
  State<TargetedOptimizationDialog> createState() =>
      _TargetedOptimizationDialogState();
}

final class _TargetedOptimizationDialogState
    extends State<TargetedOptimizationDialog> {
  final _jobTitleController = TextEditingController();
  final _jobDescriptionController = TextEditingController();
  final _instructionController = TextEditingController();
  final _selectedFields = <RemotePersonalDataField>{};
  bool _attempted = false;
  @override
  void initState() {
    super.initState();
    _jobTitleController.text =
        widget.initialDraft?.targetJobTitle ?? widget.initialJobTitle;
    _jobDescriptionController.text = widget.initialDraft?.jobDescription ?? '';
    _instructionController.text = widget.initialDraft?.userInstruction ?? '';
    for (final c in [
      _jobTitleController,
      _jobDescriptionController,
      _instructionController,
    ]) {
      c.addListener(_inputChanged);
    }
  }

  TargetedOptimizationDraft _draft({bool submitting = false}) =>
      TargetedOptimizationDraft(
        targetJobTitle: _jobTitleController.text,
        jobDescription: _jobDescriptionController.text,
        userInstruction: _instructionController.text,
        selectedPersonalFields: _selectedFields,
        confirmedInputSharing: submitting,
        sharePersonalData: _selectedFields.isNotEmpty,
      );
  void _inputChanged() {
    if (_selectedFields.isNotEmpty || _attempted) {
      setState(() => _selectedFields.clear());
    }
    _rememberDraft();
  }

  void _rememberDraft() => widget.onDraftChanged?.call(_draft());
  @override
  void dispose() {
    _jobTitleController.dispose();
    _jobDescriptionController.dispose();
    _instructionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    actionsOverflowButtonSpacing: 8,
    title: const Text('按目标岗位优化'),
    content: SizedBox(
      width: 600,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.documentTitle.isEmpty
                ? '基于当前已保存的简历'
                : '所选简历：${widget.documentTitle}',
          ),
          const Text('输入目标岗位即可开始，不必重填经历。未保存的编辑不会发送。'),
          const SizedBox(height: 16),
          TextField(
            key: const Key('目标岗位输入框'),
            controller: _jobTitleController,
            maxLength: 100,
            decoration: InputDecoration(
              labelText: '目标岗位',
              hintText: '例如：前端开发工程师',
              errorText: _attempted && _jobTitleController.text.trim().isEmpty
                  ? '请输入目标岗位'
                  : null,
            ),
          ),
          ExpansionTile(
            title: const Text('补充要求（选填）'),
            children: [
              TextField(
                key: const Key('岗位描述输入框'),
                controller: _jobDescriptionController,
                maxLength: 2000,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(labelText: '岗位描述（可选）'),
              ),
              TextField(
                key: const Key('优化要求输入框'),
                controller: _instructionController,
                maxLength: 4000,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '额外要求（可选）',
                  hintText: '例如：只改项目描述，不要改日期。',
                ),
              ),
            ],
          ),
          PersonalDataSelector(
            selectedFields: _selectedFields,
            onChanged: () {
              setState(() {});
              _rememberDraft();
            },
          ),
          const Text('点击“同意发送并优化”会发送目标岗位和简历相关材料；个人信息按上方选择处理。结果先供审阅，确认后保存新版本。'),
          const _AiRecipientNotice(),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('提交岗位优化'),
        onPressed: () {
          if (_jobTitleController.text.trim().isEmpty) {
            setState(() => _attempted = true);
            return;
          }
          Navigator.pop(context, _draft(submitting: true));
        },
        child: const Text('同意发送并优化'),
      ),
    ],
  );
}

final class RemoteConversationDialog extends StatefulWidget {
  const RemoteConversationDialog({
    super.key,
    required this.recentRounds,
    this.initialDraft,
    this.onDraftChanged,
  });

  final List<RemoteConversationRound> recentRounds;
  final RemoteConversationDraft? initialDraft;
  final ValueChanged<RemoteConversationDraft>? onDraftChanged;

  @override
  State<RemoteConversationDialog> createState() =>
      _RemoteConversationDialogState();
}

final class _RemoteConversationDialogState
    extends State<RemoteConversationDialog> {
  final _jobTitleController = TextEditingController();
  final _jobDescriptionController = TextEditingController();
  final _messageController = TextEditingController();
  final _selectedFields = <RemotePersonalDataField>{};

  @override
  void initState() {
    super.initState();
    final draft = widget.initialDraft;
    if (draft != null) {
      _jobTitleController.text = draft.targetJobTitle;
      _jobDescriptionController.text = draft.jobDescription;
      _messageController.text = draft.userMessage;
    }
    for (final field in [
      _jobTitleController,
      _jobDescriptionController,
      _messageController,
    ]) {
      field.addListener(_inputChanged);
    }
  }

  void _inputChanged() {
    if (_selectedFields.isNotEmpty) setState(() => _selectedFields.clear());
    _rememberDraft();
  }

  void _rememberDraft() => widget.onDraftChanged?.call(
    RemoteConversationDraft(
      targetJobTitle: _jobTitleController.text,
      jobDescription: _jobDescriptionController.text,
      userMessage: _messageController.text,
      selectedPersonalFields: _selectedFields,
    ),
  );

  @override
  void dispose() {
    _jobTitleController.dispose();
    _jobDescriptionController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      actionsOverflowButtonSpacing: 8,
      title: const Text('继续岗位优化对话'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _RemoteFlowNotice(
              icon: Icons.forum_outlined,
              title: '围绕这份简历继续完善',
              message: '使用已保存简历与最近对话作为上下文，不用重填。按容量最多带入三轮，本机保留七天；结果仍需你确认。',
            ),
            const SizedBox(height: 16),
            if (widget.recentRounds.isEmpty)
              const Text('还没有对话，写下你希望改进的地方。')
            else
              ExpansionTile(
                title: Text('最近 ${widget.recentRounds.length} 轮（展开查看）'),
                children: [
                  for (final round in widget.recentRounds)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '你',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 4),
                            Text(round.userMessage),
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Divider(),
                            ),
                            Text(
                              'AI 建议',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 4),
                            Text(round.assistantSummary),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('多轮问题输入框'),
              controller: _messageController,
              maxLength: 4000,
              minLines: 5,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: '继续说说你的想法或补充',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                alignLabelWithHint: true,
                helperText: '自然表达即可，AI会结合当前简历和已有上下文处理。',
                helperMaxLines: 3,
              ),
            ),
            ExpansionTile(
              title: const Text('岗位与发送范围（可选）'),
              children: [
                TextField(
                  controller: _jobTitleController,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: '目标岗位（可选）'),
                ),
                TextField(
                  controller: _jobDescriptionController,
                  maxLength: 2000,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '岗位描述（可选）'),
                ),
              ],
            ),
            PersonalDataSelector(
              selectedFields: _selectedFields,
              onChanged: () {
                _rememberDraft();
                setState(() {});
              },
            ),
            const Text('点击“同意发送”会提交本轮输入与相关材料，个人信息按上方选择处理。'),
            const _AiRecipientNotice(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('提交多轮优化'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
          onPressed: () => Navigator.pop(
            context,
            RemoteConversationDraft(
              targetJobTitle: _jobTitleController.text,
              jobDescription: _jobDescriptionController.text,
              userMessage: _messageController.text,
              selectedPersonalFields: _selectedFields,
              confirmedInputSharing: true,
              sharePersonalData: _selectedFields.isNotEmpty,
            ),
          ),
          child: const Text('同意发送'),
        ),
      ],
    );
  }
}

final class RemoteWritingContextDialog extends StatefulWidget {
  const RemoteWritingContextDialog({
    super.key,
    required this.content,
    required this.initial,
  });
  final ResumeData content;
  final RemoteWritingContext initial;
  @override
  State<RemoteWritingContextDialog> createState() =>
      _RemoteWritingContextDialogState();
}

final class _RemoteWritingContextDialogState
    extends State<RemoteWritingContextDialog> {
  late final List<RemoteWritingFactField> _fields = remoteWritingFactFields(
    widget.content,
  );
  late final Map<String, String> _confirmed = Map.of(
    widget.initial.confirmedFacts,
  );
  final _drafts = <String, String>{};
  final _factsController = TextEditingController();
  final _constraintsController = TextEditingController();
  late String _selectedPath;
  bool _checked = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _selectedPath = _fields.first.path;
    _factsController.text = _confirmed[_selectedPath] ?? _fields.first.text;
    _constraintsController.text = widget.initial.constraints.join('\n');
  }

  @override
  void dispose() {
    _factsController.dispose();
    _constraintsController.dispose();
    super.dispose();
  }

  void _confirmParagraph() {
    final text = _factsController.text.trim();
    if (!_checked || text.isEmpty) return;
    final next = {..._confirmed, _selectedPath: text};
    setState(() {
      if (next.length > 12 ||
          next.values.fold<int>(0, (n, v) => n + v.runes.length) > 6000) {
        _error = '最多确认12段事实，合计不超过6000字。';
      } else {
        _confirmed[_selectedPath] = text;
        _error = null;
        _checked = false;
      }
    });
  }

  void _submit() {
    final constraints = _constraintsController.text
        .split('\n')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
    if (constraints.length > 12 ||
        constraints.any((v) => v.runes.length > 500) ||
        constraints.fold<int>(0, (n, v) => n + v.runes.length) > 3000) {
      setState(() => _error = '长期要求最多12条，每条500字，合计3000字。');
      return;
    }
    Navigator.pop(
      context,
      RemoteWritingContext(
        confirmedFacts: _confirmed,
        constraints: constraints,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('确认事实与长期要求'),
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    content: SizedBox(
      width: 620,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('AI提出问题时，在这里确认对应段落的真实情况。此操作只准备AI材料，简历仍需审阅候选后保存。'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('AI事实段落选择'),
            initialValue: _selectedPath,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '选择段落'),
            items: [
              for (final field in _fields)
                DropdownMenuItem(
                  value: field.path,
                  child: Text(
                    field.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (path) {
              if (path == null) return;
              _drafts[_selectedPath] = _factsController.text;
              setState(() {
                _selectedPath = path;
                _factsController.text =
                    _drafts[path] ??
                    _confirmed[path] ??
                    _fields.firstWhere((field) => field.path == path).text;
                _checked = false;
              });
            },
          ),
          TextField(
            key: const Key('AI完整事实输入'),
            controller: _factsController,
            minLines: 3,
            maxLines: 7,
            maxLength: 1000,
            onChanged: (_) => setState(() => _checked = false),
            decoration: const InputDecoration(
              labelText: '这一段完整、已核实的事实',
              helperText:
                  '保留仍然属实的原信息，再补充或更正。不要只填几个新增词；姓名、联系方式、公司和日期等结构信息请先在编辑页保存。',
              helperMaxLines: 5,
            ),
          ),
          CheckboxListTile(
            key: const Key('核实AI段落事实'),
            contentPadding: EdgeInsets.zero,
            value: _checked,
            title: const Text('我已核实这段事实，并保留仍然属实的信息'),
            onChanged: (value) => setState(() => _checked = value == true),
          ),
          OutlinedButton(
            key: const Key('确认这一段AI事实'),
            onPressed: _checked && _factsController.text.trim().isNotEmpty
                ? _confirmParagraph
                : null,
            child: const Text('确认这一段'),
          ),
          for (final fact in _confirmed.entries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                _fields.firstWhere((field) => field.path == fact.key).label,
              ),
              subtitle: Text(
                fact.value,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '移除已确认事实',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => setState(() => _confirmed.remove(fact.key)),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('AI长期要求输入'),
            controller: _constraintsController,
            minLines: 2,
            maxLines: 6,
            maxLength: 3000,
            decoration: const InputDecoration(
              labelText: '后续各轮都需遵守的要求（每行一条）',
              helperText: '例如：只改项目描述；不要改日期；保持中文。公司、日期、联系方式不能作为事实从这里修改。',
              helperMaxLines: 4,
            ),
          ),
          const SizedBox(height: 8),
          const Text('这些材料仅用于当前账号、这份简历的当前版本。发起AI请求时会随同已保存内容发送；不确认的输入不会发送。'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
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
        key: const Key('保存AI确认材料'),
        onPressed: _submit,
        child: const Text('保存已确认材料'),
      ),
    ],
  );
}

final class PersonalDataSelector extends StatelessWidget {
  const PersonalDataSelector({
    super.key,
    required this.selectedFields,
    required this.onChanged,
  });
  final Set<RemotePersonalDataField> selectedFields;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => CheckboxListTile(
    key: const Key('允许整体发送个人信息'),
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    value: selectedFields.isNotEmpty,
    title: const Text('允许将个人基础信息一并发送给 AI'),
    subtitle: const Text(
      '不勾选：基础信息保留本地，已知姓名、联系方式会从材料中隐藏。经历材料仍会发送；请检查未识别的个人信息。生成结果在服务器加密暂存最多24小时，用于断线取回，到期清理。',
    ),
    onChanged: (value) {
      selectedFields.clear();
      if (value == true) selectedFields.addAll(RemotePersonalDataField.values);
      onChanged();
    },
  );
}

final class RemoteResumeReviewDialog extends StatefulWidget {
  const RemoteResumeReviewDialog({super.key, required this.pendingChange});

  final PendingRemoteResumeChange pendingChange;

  @override
  State<RemoteResumeReviewDialog> createState() =>
      _RemoteResumeReviewDialogState();
}

final class _RemoteResumeReviewDialogState
    extends State<RemoteResumeReviewDialog> {
  bool _confirmedSemanticReview = false;

  PendingRemoteResumeChange get pendingChange => widget.pendingChange;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      actionsOverflowButtonSpacing: 8,
      title: const Text('审阅联网 AI 建议'),
      content: SizedBox(
        width: 660,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RemoteFlowNotice(
              icon: Icons.rate_review_outlined,
              title: '最终决定由你做出',
              message: formatResumeReviewNotice(pendingChange.summary),
            ),
            if (pendingChange.diff.containsFactChanges) ...[
              const SizedBox(height: 12),
              const _RemoteFlowNotice(
                icon: Icons.warning_amber_rounded,
                title: '请逐项核对事实',
                message: '包含事实信息变更。请确认经历、日期和其他信息真实准确，再保存新版本。',
                isWarning: true,
              ),
            ],
            const SizedBox(height: 20),
            Semantics(
              header: true,
              child: Text(
                '变更明细（${pendingChange.diff.entries.length} 项）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const SizedBox(height: 8),
            for (final diffEntry in pendingChange.diff.entries)
              _RemoteDiffCard(entry: diffEntry),
            if (pendingChange.missingInformation.isNotEmpty ||
                pendingChange.warnings.isNotEmpty)
              const SizedBox(height: 12),
            for (final missingInformation in pendingChange.missingInformation)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('待补充：$missingInformation'),
              ),
            for (final warning in pendingChange.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('提示：${formatResumeReviewNotice(warning)}'),
              ),
            if (pendingChange.requiresSemanticReview)
              CheckboxListTile(
                key: const Key('确认改写含义与事实'),
                value: _confirmedSemanticReview,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('我已核对改写含义、事实和修改范围'),
                onChanged: (value) =>
                    setState(() => _confirmedSemanticReview = value ?? false),
              ),
            const SizedBox(height: 16),
            const Text('只有确认后才会创建新版本；AI 不会覆盖已有事实或历史版本。'),
          ],
        ),
      ),
      actions: [
        SizedBox(
          width: 660,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                ResumeAiProvenance.candidateNotice,
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    key: const Key('拒绝远程建议'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(64, 48),
                    ),
                    onPressed: () =>
                        Navigator.pop(context, RemoteResumeReviewAction.reject),
                    child: const Text('拒绝建议'),
                  ),
                  FilledButton(
                    key: const Key('确认远程建议'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 48),
                    ),
                    onPressed:
                        pendingChange.requiresSemanticReview &&
                            !_confirmedSemanticReview
                        ? null
                        : () => Navigator.pop(
                            context,
                            pendingChange.requiresSemanticReview
                                ? RemoteResumeReviewAction.acceptWithFactReview
                                : RemoteResumeReviewAction.accept,
                          ),
                    child: const Text('确认并保存新版本'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class _RemoteFlowNotice extends StatelessWidget {
  const _RemoteFlowNotice({
    required this.icon,
    required this.title,
    required this.message,
    this.isWarning = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = isWarning
        ? colors.onErrorContainer
        : colors.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isWarning ? colors.errorContainer : colors.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Icon(icon, color: foreground),
          ),
          const SizedBox(height: 10),
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(color: foreground),
            ),
          ),
          const SizedBox(height: 6),
          Text(message, style: TextStyle(color: foreground)),
        ],
      ),
    );
  }
}

final class _RemoteDiffCard extends StatelessWidget {
  const _RemoteDiffCard({required this.entry});

  final ResumeDiffEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final category = switch (entry.category) {
      ResumeChangeCategory.fact => '事实变更',
      ResumeChangeCategory.wording => '措辞调整',
      ResumeChangeCategory.format => '格式整理',
    };
    final operation = switch (entry.operation) {
      PatchOperationType.add => '新增',
      PatchOperationType.remove => '删除',
      PatchOperationType.replace => '修改',
    };
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$category · $operation', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            SelectableText(
              resumeReviewFieldLabel(entry.path),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _DiffValuePanel(
              label: '修改前',
              value: entry.oldValue,
              proposed: false,
            ),
            const SizedBox(height: 8),
            _DiffValuePanel(
              label: '修改后',
              value: entry.newValue,
              proposed: true,
            ),
            const SizedBox(height: 12),
            Text('理由：${formatResumeReviewNotice(entry.reason)}'),
          ],
        ),
      ),
    );
  }
}

final class _DiffValuePanel extends StatelessWidget {
  const _DiffValuePanel({
    required this.label,
    required this.value,
    required this.proposed,
  });

  final String label;
  final Object? value;
  final bool proposed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = proposed ? colors.onPrimaryContainer : colors.onSurface;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: proposed ? colors.primaryContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(color: foreground),
          ),
          const SizedBox(height: 6),
          SelectableText(
            formatResumeReviewValue(value),
            style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

String _planLabel(GatewaySubscriptionPlan? plan) => switch (plan) {
  GatewaySubscriptionPlan.free => '免费',
  GatewaySubscriptionPlan.pro => '月订阅（开发快照）',
  null => '未知',
};

String _remoteCapabilityLabel(RemoteAiCapability capability) =>
    switch (capability) {
      RemoteAiCapability.basicResumeCompose => '基础简历生成',
      RemoteAiCapability.targetedResumeOptimization => '目标岗位优化',
      RemoteAiCapability.resumeOptimizationConversation => '多轮优化对话',
    };

String _accessReasonLabel(String? reason) => switch (reason) {
  'allowed' => '可用',
  'subscription_required' => '需要订阅',
  'quota_exhausted' => '本月额度已用完',
  _ => '状态未知',
};
