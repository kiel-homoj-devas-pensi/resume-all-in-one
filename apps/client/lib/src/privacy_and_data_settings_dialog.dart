import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:resume_domain/resume_domain.dart';

import 'app_theme_controller.dart';
import 'legal_consent_pages.dart';
import 'privacy_rights_page.dart';
import 'cloud_policy_dialog.dart';
import 'resume_workspace_controller.dart';
import 'workspace_pages.dart';

/// 隐私偏好、导出和删除确认的界面；实际读写由工作区控制器执行。
final class PrivacyAndDataSettingsDialog extends StatelessWidget {
  const PrivacyAndDataSettingsDialog({
    super.key,
    required this.controller,
    required this.onFeedback,
    this.onBeforeRestore,
    this.onAccount,
  });

  final ResumeWorkspaceController controller;
  final VoidCallback onFeedback;
  final Future<bool> Function()? onBeforeRestore;
  final VoidCallback? onAccount;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => AlertDialog(
        title: const Text('设置'),
        content: SizedBox(
          width: 560,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 620),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ThemePreferencePicker(isBusy: controller.isBusy),
                  if (controller.legalConsent case final legal?) ...[
                    const SizedBox(height: 16),
                    ListTile(
                      key: const Key('设置协议与隐私'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.policy_outlined),
                      title: const Text('协议与隐私'),
                      subtitle: Text(
                        legal.canUseRemoteServices
                            ? '当前版本已同意；可查看记录或撤回'
                            : legal.blockedReason,
                      ),
                      onTap: () => showLegalCenter(
                        context,
                        legal,
                        enableNetwork: () => controller.setNetworkEnabled(true),
                      ),
                    ),
                    if (legal.errorMessage != null)
                      Text(
                        legal.errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                  if (onAccount != null) ...[
                    const SizedBox(height: 16),
                    ListTile(
                      key: const Key('开发账号'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.account_circle_outlined),
                      title: const Text('账号与会员'),
                      subtitle: const Text('登录状态、会员权益与 AI 用量'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: controller.isBusy ? null : onAccount,
                    ),
                  ],
                  ListTile(
                    key: const Key('设置个人信息请求'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.support_agent_outlined),
                    title: const Text('咨询、投诉与个人信息请求'),
                    subtitle: const Text('联系邮箱、请求说明与账号归属核验；无需登录即可咨询'),
                    onTap: () => showPrivacyRightsPage(context, controller),
                  ),
                  const SizedBox(height: 24),
                  Text('联网偏好', style: Theme.of(context).textTheme.titleMedium),
                  SwitchListTile(
                    key: const Key('允许联网开关'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许联网'),
                    subtitle: const Text(
                      '控制账号、联网 AI 和云政策查询；开启不代表已连接或同意上传，本地功能始终可用。',
                    ),
                    value: controller.networkEnabled,
                    onChanged: controller.isBusy
                        ? null
                        : (enabled) =>
                              _changeNetworkPreference(context, enabled),
                  ),
                  const Text('简历创建、编辑、验证、版本查看和导出均可完全离线完成。'),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      controller.remotePersonalDataWarningAcknowledged
                          ? Icons.verified_user_outlined
                          : Icons.gpp_maybe_outlined,
                    ),
                    title: const Text('联网 AI 隐私提醒'),
                    subtitle: Text(
                      controller.remotePersonalDataWarningAcknowledged
                          ? '已确认；每次任务使用一个整体选择，决定是否发送个人基础信息。'
                          : '首次使用联网 AI 时必须先确认。',
                    ),
                    trailing: controller.remotePersonalDataWarningAcknowledged
                        ? TextButton(
                            key: const Key('撤销联网AI隐私确认'),
                            onPressed: controller.isBusy
                                ? null
                                : () => _revokeRemoteWarning(context),
                            child: const Text('撤销'),
                          )
                        : null,
                  ),
                  const SizedBox(height: 20),
                  Text('能力状态', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  for (final accessDecision in controller.capabilityDecisions)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        accessDecision.isAllowed
                            ? Icons.check_circle_outline
                            : Icons.block_outlined,
                      ),
                      title: Text(
                        _productCapabilityLabel(accessDecision.capability),
                      ),
                      subtitle: Text(accessDecision.reason),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    '本地数据管理',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('导出全部本地数据'),
                    onPressed: controller.isBusy
                        ? null
                        : () => _exportAllLocalData(context),
                    icon: const Icon(Icons.archive_outlined),
                    label: const Text('导出全部本地数据'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '导出包含全部简历历史、设置和脱敏 Agent 审计；通过系统窗口另存 JSON。'
                    '不包含 Word/PDF 副本和联网待审阅记录。恢复只添加简历与全部历史，不恢复设置或联网同意。'
                    '档案文件上限 8 MiB；资料过多或结构过于复杂时整份拒绝，不截断。',
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('恢复简历与全部历史'),
                    onPressed: controller.isBusy
                        ? null
                        : () => _restoreArchive(context),
                    icon: const Icon(Icons.restore_outlined),
                    label: const Text('恢复简历与全部历史'),
                  ),
                  const SizedBox(height: 12),
                  if (controller.documents.isEmpty)
                    const Text('当前没有本地简历。')
                  else ...[
                    Text('本地简历（${controller.documents.length}）'),
                    for (final resumeDocument in controller.documents)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(resumeDocument.title),
                        trailing: IconButton(
                          key: Key('设置删除简历_${resumeDocument.id}'),
                          tooltip: '删除简历：${resumeDocument.title}',
                          onPressed: controller.isBusy
                              ? null
                              : () => _deleteDocument(context, resumeDocument),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    key: const Key('清空全部本地数据'),
                    onPressed:
                        controller.isBusy ||
                            (AppThemeScope.maybeOf(context)?.isSaving ?? false)
                        ? null
                        : () => _clearAllLocalData(context),
                    icon: const Icon(Icons.delete_forever_outlined),
                    label: const Text('清空全部本地数据'),
                  ),
                  const SizedBox(height: 8),
                  const Text('清空数据库不会删除你此前主动导出的 Markdown、JSON、PDF 或备份文件。'),
                  const SizedBox(height: 8),
                  const Text(
                    '未完成 AI 任务的材料仅保存在本机，草稿可恢复7天，过期后下次读取时清除；不纳入简历导出，可在任务卡移除，清空全部本地数据时一并清除。恢复材料不会恢复新的发送同意。游客体验使用随机本机标识，登录会话不落盘；清空本地数据会移除此标识，服务端仍保留必要额度与用量记录。',
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton.icon(
                    key: const Key('查询云同步政策'),
                    onPressed: controller.isBusy
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            builder: (context) =>
                                CloudPolicyDialog(controller: controller),
                          ),
                    icon: const Icon(Icons.cloud_outlined),
                    label: const Text('查询云同步政策'),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: controller.isBusy ? null : () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _changeNetworkPreference(
    BuildContext context,
    bool enabled,
  ) async {
    if (enabled) {
      final legal = controller.legalConsent;
      if (legal != null && !legal.canUseRemoteServices) {
        final accepted = await showLegalConsentPrompt(context, legal);
        if (!context.mounted || !accepted || !legal.canUseRemoteServices) {
          return;
        }
        await controller.setNetworkEnabled(true);
        onFeedback();
        return;
      }
    }
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('允许联网？'),
          content: const Text(
            '开启后允许账号、联网 AI 和云政策查询在你主动操作时访问已配置服务；开关本身不会上传数据。'
            '真正提交前仍会说明发送字段和额度影响，并允许你拒绝。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('确认允许联网'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('允许联网'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) {
        return;
      }
    }
    await controller.setNetworkEnabled(enabled);
    onFeedback();
  }

  Future<void> _revokeRemoteWarning(BuildContext context) async {
    await controller.setRemotePersonalDataWarningAcknowledged(false);
    if (context.mounted) {
      onFeedback();
    }
  }

  Future<void> _exportAllLocalData(BuildContext context) async {
    await controller.deliverAllLocalData();
    if (context.mounted) {
      onFeedback();
    }
  }

  Future<void> _restoreArchive(BuildContext context) async {
    if (onBeforeRestore != null && !await onBeforeRestore!()) return;
    if (!context.mounted) return;
    final archive = await controller.prepareLocalDataRestore();
    if (!context.mounted) {
      controller.cancelLocalDataRestore();
      return;
    }
    if (archive == null) {
      onFeedback();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复简历与全部历史？'),
        content: SingleChildScrollView(
          child: Text(
            '将添加 ${archive.summary.documentCount} 份简历及 ${archive.summary.versionCount} 个历史版本。'
            '不会覆盖本机已有资料；文档或版本身份重复时整份拒绝。'
            '不会恢复档案中的设置、联网同意、账号、审计、远程待审阅记录或 Word/PDF 副本。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('确认恢复档案'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      controller.cancelLocalDataRestore();
      return;
    }
    await controller.confirmLocalDataRestore(archive);
    if (context.mounted) onFeedback();
  }

  Future<void> _deleteDocument(
    BuildContext context,
    ResumeDocument resumeDocument,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这份简历？'),
        content: Text(
          '“${resumeDocument.title}”及其全部历史版本将不可恢复。'
          '不含正文的 Agent 审计会保留；“清空全部本地数据”可一并删除审计。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('确认设置删除简历'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除简历'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    await controller.deleteDocument(resumeDocument.id);
    onFeedback();
  }

  Future<void> _clearAllLocalData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _ClearAllLocalDataDialog(),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    await controller.clearAllLocalData();
    onFeedback();
  }
}

final class _ClearAllLocalDataDialog extends StatefulWidget {
  const _ClearAllLocalDataDialog();

  @override
  State<_ClearAllLocalDataDialog> createState() =>
      _ClearAllLocalDataDialogState();
}

final class _ClearAllLocalDataDialogState
    extends State<_ClearAllLocalDataDialog> {
  static const requiredConfirmationText = '清空全部数据';
  final confirmationController = TextEditingController();

  @override
  void dispose() {
    confirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final confirmationMatches =
        confirmationController.text == requiredConfirmationText;
    return AlertDialog(
      title: const Text('清空全部本地数据？'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('此操作会永久删除全部简历、历史版本、Agent 审计、协议选择记录和提醒偏好，外观将恢复跟随系统。'),
          const SizedBox(height: 8),
          const Text('已主动导出的文件会保留。请输入“清空全部数据”继续。'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('清空确认输入框'),
            controller: confirmationController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: '确认文字'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('确认清空全部数据'),
          onPressed: confirmationMatches
              ? () => Navigator.pop(context, true)
              : null,
          child: const Text('永久清空'),
        ),
      ],
    );
  }
}

String _productCapabilityLabel(ProductCapability capability) {
  return switch (capability) {
    ProductCapability.localResumeValidation => '本地简历检查',
    ProductCapability.localResumeSuggestion => '本地规则建议',
    ProductCapability.cloudAiRewrite => '云端 AI 改写（尚未接入）',
    ProductCapability.jobMatching => '岗位匹配（尚未接入）',
  };
}
