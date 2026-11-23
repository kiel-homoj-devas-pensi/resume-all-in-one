import 'remote_task_draft_store.dart';
import 'package:flutter/material.dart';
import 'package:resume_domain/resume_domain.dart';

import 'app_theme_controller.dart';

/// 页面只描述用户操作；所有读写和能力判断仍由 Application 提供。
final class ResumeLibraryPage extends StatefulWidget {
  const ResumeLibraryPage({
    super.key,
    required this.documents,
    required this.isBusy,
    required this.onCreate,
    required this.onImport,
    required this.onCompose,
    required this.onOpen,
  });

  final List<ResumeDocument> documents;
  final bool isBusy;
  final VoidCallback onCreate;
  final VoidCallback onImport;
  final VoidCallback onCompose;
  final ValueChanged<String> onOpen;

  @override
  State<ResumeLibraryPage> createState() => _ResumeLibraryPageState();
}

final class _ResumeLibraryPageState extends State<ResumeLibraryPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final documents = widget.documents
        .where(
          (document) => document.title.toLowerCase().contains(
            _query.toLowerCase().trim(),
          ),
        )
        .toList();
    return WorkspacePage(
      storageKey: 'resume-library',
      children: [
        const WorkspaceEyebrow(
          icon: Icons.lock_outline_rounded,
          text: '简历保存在本机',
        ),
        const SizedBox(height: 16),
        Text('整理经历，\n准备下一份简历。', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 12),
        Text(
          '按岗位准备不同版本，随时修改和导出。',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 28),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const Key('新建简历'),
              onPressed: widget.isBusy ? null : widget.onCreate,
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建简历'),
            ),
            Tooltip(
              message: '导入为新简历',
              child: FilledButton.tonalIcon(
                key: const Key('导入文本简历'),
                onPressed: widget.isBusy ? null : widget.onImport,
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('导入文件'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Row(
          children: [
            Expanded(child: Text('我的简历', style: theme.textTheme.titleLarge)),
            Text(
              '${widget.documents.length} 份',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (widget.documents.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: .6),
              ),
            ),
            child: Column(
              children: [
                const ResumePaperIllustration(),
                const SizedBox(height: 22),
                Text('还没有简历', style: theme.textTheme.titleLarge),
                const SizedBox(height: 10),
                Text(
                  '新建简历，或导入已有的简历文件。\n保存后可以查看和恢复历史版本。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else ...[
          TextField(
            key: const Key('搜索简历'),
            decoration: const InputDecoration(
              hintText: '搜索简历标题',
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onChanged: (query) => setState(() => _query = query),
          ),
          const SizedBox(height: 16),
          if (documents.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Text('没有找到匹配的简历，试试其他关键词。', textAlign: TextAlign.center),
            ),
          for (final document in documents) ...[
            Card(
              child: InkWell(
                key: ValueKey('打开简历_${document.id}'),
                borderRadius: BorderRadius.circular(24),
                onTap: widget.isBusy ? null : () => widget.onOpen(document.id),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      WorkspaceIcon(icon: Icons.description_outlined, size: 52),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              document.title,
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '保存在本机 · ${_friendlyDate(document.updatedAt)}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 20),
        Card(
          color: colors.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '还没想好怎么开始？',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '把零散经历交给 AI 整理，保存前由你逐项审阅。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSecondaryContainer,
                  ),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  key: const Key('AI创建基础简历'),
                  onPressed: widget.isBusy ? null : widget.onCompose,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onSecondaryContainer,
                  ),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('AI 起草 · 需联网与账号'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          '编辑、检查和 Word 转 PDF 均可离线使用。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

final class ResumeAssistantPage extends StatelessWidget {
  const ResumeAssistantPage({
    super.key,
    required this.isBusy,
    required this.onOpenLibrary,
    required this.onCompose,
    required this.onChooseResume,
    this.onReview,
    this.unfinishedTasks = const [],
    this.onResumeTask,
    this.onDiscardTask,
  });

  final List<RemoteTaskDraft> unfinishedTasks;
  final ValueChanged<RemoteTaskDraft>? onResumeTask;
  final ValueChanged<RemoteTaskDraft>? onDiscardTask;
  final bool isBusy;
  final VoidCallback onOpenLibrary;
  final VoidCallback onCompose;
  final VoidCallback onChooseResume;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkspacePage(
      storageKey: 'resume-assistant',
      children: [
        const WorkspaceEyebrow(
          icon: Icons.auto_awesome_outlined,
          text: '每一步，都由你决定',
        ),
        const SizedBox(height: 16),
        Text('打磨表达，\n保留真实。', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 12),
        Text('从整理格式到梳理经历，找到适合你的帮助。', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 28),
        if (onResumeTask != null)
          for (final task in unfinishedTasks) ...[
            _UnfinishedAiTaskCard(
              task: task,
              isBusy: isBusy,
              onResume: onResumeTask!,
              onDiscard: onDiscardTask,
            ),
            const SizedBox(height: 16),
          ],
        WorkspaceFeatureCard(
          icon: Icons.fact_check_outlined,
          title: '先做一次本地检查',
          description: '检查字段、重复内容与格式。无需账号，断网也可使用。',
          footer: '在简历编辑页检查格式与基本信息，不自动修改正文。',
          action: OutlinedButton.icon(
            onPressed: isBusy ? null : onOpenLibrary,
            icon: const Icon(Icons.description_outlined),
            label: const Text('选择一份简历'),
          ),
        ),
        const SizedBox(height: 16),
        WorkspaceFeatureCard(
          icon: Icons.auto_awesome_outlined,
          title: '让零散经历变成初稿',
          description: '随意写下一段经历和需求，AI 提取整理，再由你审阅确认。',
          footer: '需联网；可登录或进入游客体验。发送前确认材料，结果确认后才保存。',
          action: FilledButton.icon(
            key: const Key('AI创建基础简历'),
            onPressed: isBusy ? null : onCompose,
            icon: const Icon(Icons.add_rounded),
            label: const Text('开始 AI 起草'),
          ),
        ),
        const SizedBox(height: 16),
        WorkspaceFeatureCard(
          icon: Icons.work_outline_rounded,
          title: '围绕目标岗位，继续优化',
          description: '选择已保存的简历，输入目标岗位，完成后审阅修改。',
          footer: '能力与额度以服务端结果为准；每次修改都需你确认。',
          action: TextButton.icon(
            key: const Key('AI选择已有简历'),
            onPressed: isBusy ? null : onChooseResume,
            icon: const Icon(Icons.description_outlined),
            label: const Text('选择简历开始优化'),
          ),
        ),
        if (onReview != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('恢复候选审阅'),
            onPressed: isBusy ? null : onReview,
            icon: const Icon(Icons.rate_review_outlined),
            label: const Text('查看待审阅结果'),
          ),
        ],
      ],
    );
  }
}

final class ResumeAiTaskPage extends StatelessWidget {
  const ResumeAiTaskPage({
    super.key,
    required this.document,
    required this.version,
    required this.isBusy,
    this.unfinishedTasks = const [],
    this.onResumeTask,
    this.onDiscardTask,
    required this.hasPendingChange,
    required this.onOptimize,
    required this.onReview,
    required this.onEdit,
    required this.onConfirmFacts,
    required this.confirmedFactCount,
    required this.constraintCount,
  });

  final ResumeDocument document;
  final ResumeVersion version;
  final List<RemoteTaskDraft> unfinishedTasks;
  final ValueChanged<RemoteTaskDraft>? onResumeTask;
  final ValueChanged<RemoteTaskDraft>? onDiscardTask;
  final bool isBusy;
  final bool hasPendingChange;
  final VoidCallback onOptimize;
  final VoidCallback onReview;
  final VoidCallback onEdit;
  final VoidCallback onConfirmFacts;
  final int confirmedFactCount;
  final int constraintCount;

  @override
  Widget build(BuildContext context) {
    final blocked = isBusy || hasPendingChange;
    return WorkspacePage(
      storageKey: 'ai-task-${document.id}',
      children: [
        const WorkspaceEyebrow(
          icon: Icons.auto_awesome_outlined,
          text: 'AI 助手',
        ),
        const SizedBox(height: 16),
        Text(document.title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text('基于已保存版本：${_friendlyDate(version.createdAt)}'),
        if (version.content.extensions.containsKey(
              ResumeAiProvenance.extensionKey,
            ) ||
            version.content.extensions.containsKey(
              ResumeAigcMetadata.extensionKey,
            ))
          const Text('本简历带有AI来源标识，请核对事实。'),
        const SizedBox(height: 12),
        const Text('输入目标岗位即可优化当前简历，额外要求选填。AI 先提出候选，你确认后才保存新版本。'),
        if (onResumeTask != null)
          for (final task in unfinishedTasks) ...[
            const SizedBox(height: 16),
            _UnfinishedAiTaskCard(
              task: task,
              isBusy: isBusy,
              onResume: onResumeTask!,
              onDiscard: onDiscardTask,
            ),
          ],
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const Key('按目标岗位优化'),
              onPressed: blocked ? null : onOptimize,
              icon: const Icon(Icons.work_outline),
              label: const Text('岗位优化'),
            ),
            if (hasPendingChange)
              OutlinedButton.icon(
                key: const Key('恢复候选审阅'),
                onPressed: isBusy ? null : onReview,
                icon: const Icon(Icons.rate_review_outlined),
                label: const Text('继续审阅'),
              ),
            TextButton.icon(
              key: const Key('确认AI材料'),
              onPressed: blocked ? null : onConfirmFacts,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('确认事实与长期要求'),
            ),
            TextButton.icon(
              key: const Key('AI返回手工编辑'),
              onPressed: blocked ? null : onEdit,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('手工编辑'),
            ),
          ],
        ),
        if (confirmedFactCount > 0 || constraintCount > 0) ...[
          const SizedBox(height: 16),
          Text(
            '当前版本已确认 $confirmedFactCount 段事实、$constraintCount 条长期要求。简历保存新版本后需重新确认。',
          ),
        ],
      ],
    );
  }
}

final class WorkspaceSettingsPage extends StatelessWidget {
  const WorkspaceSettingsPage({
    super.key,
    required this.isBusy,
    required this.onPrivacy,
    required this.onAccount,
    this.onLegal,
  });
  final bool isBusy;
  final VoidCallback onPrivacy;
  final VoidCallback onAccount;
  final VoidCallback? onLegal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return WorkspacePage(
      storageKey: 'workspace-settings',
      children: [
        const WorkspaceEyebrow(icon: Icons.settings_rounded, text: '应用偏好'),
        const SizedBox(height: 16),
        Text('设置', style: theme.textTheme.headlineLarge),
        const SizedBox(height: 28),
        ThemePreferencePicker(isBusy: isBusy),
        const SizedBox(height: 24),
        Text('隐私与数据', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        if (onLegal != null) ...[
          Card(
            child: ListTile(
              key: const Key('协议与隐私入口'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 10,
              ),
              leading: const WorkspaceIcon(icon: Icons.policy_outlined),
              title: const Text('协议与隐私'),
              subtitle: const Text('阅读全文、查看版本记录和管理同意'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: isBusy ? null : onLegal,
            ),
          ),
          const SizedBox(height: 12),
        ],
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 10,
            ),
            leading: const WorkspaceIcon(icon: Icons.shield_outlined),
            title: const Text('隐私与本地数据'),
            subtitle: const Text('联网偏好、数据导出与清空'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: isBusy ? null : onPrivacy,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 10,
            ),
            leading: const WorkspaceIcon(icon: Icons.account_circle_outlined),
            key: const Key('开发账号'),
            title: const Text('账号与会员'),
            subtitle: const Text('本地编辑不需要账号'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: isBusy ? null : onAccount,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            key: const Key('第三方许可'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 10,
            ),
            leading: const WorkspaceIcon(icon: Icons.description_outlined),
            title: const Text('第三方许可'),
            subtitle: const Text('查看应用所用组件与中文字体许可'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () =>
                showLicensePage(context: context, applicationName: '简历全能帮'),
          ),
        ),
        const SizedBox(height: 32),
        const WorkspaceEyebrow(
          icon: Icons.favorite_border_rounded,
          text: '简历全能帮 · 本地优先',
        ),
        const SizedBox(height: 10),
        Text(
          'AI 建议需要确认后才会保存。\n本地编辑与导出无需登录。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

final class ThemePreferencePicker extends StatelessWidget {
  const ThemePreferencePicker({super.key, required this.isBusy});
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final appearance = AppThemeScope.maybeOf(context);
    if (appearance == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) {
        final theme = Theme.of(context);
        final enabled =
            !isBusy && !appearance.isLoading && !appearance.isSaving;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('外观', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '外观设置会保留到下次打开应用。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final vertical =
                    constraints.maxWidth < 300 ||
                    MediaQuery.textScalerOf(context).scale(14) > 20;
                final choices = [
                  for (final choice in const [
                    (ThemeMode.light, '浅色', '白与蓝', Icons.light_mode_outlined),
                    (ThemeMode.dark, '深色', '黑与紫', Icons.dark_mode_outlined),
                    (
                      ThemeMode.system,
                      '跟随系统',
                      '自动切换',
                      Icons.brightness_auto_outlined,
                    ),
                  ])
                    _ThemeChoice(
                      mode: choice.$1,
                      title: choice.$2,
                      description: choice.$3,
                      icon: choice.$4,
                      selected: appearance.mode == choice.$1,
                      compact: !vertical,
                      onTap: !enabled
                          ? null
                          : () async {
                              final success = await appearance.setMode(
                                choice.$1,
                              );
                              if (!success && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      appearance.errorMessage ??
                                          '未能保存外观设置，请重试。',
                                    ),
                                  ),
                                );
                              }
                            },
                    ),
                ];
                if (vertical) {
                  return Column(
                    children: [
                      for (final choice in choices)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: choice,
                        ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var index = 0; index < choices.length; index++) ...[
                      if (index != 0) const SizedBox(width: 10),
                      Expanded(child: choices[index]),
                    ],
                  ],
                );
              },
            ),
            if (appearance.errorMessage case final error?) ...[
              const SizedBox(height: 12),
              Text(error, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        );
      },
    );
  }
}

final class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.mode,
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    required this.compact,
    required this.onTap,
  });
  final ThemeMode mode;
  final String title;
  final String description;
  final IconData icon;
  final bool selected;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('主题_${mode.name}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
            child: compact
                ? Column(
                    children: [
                      Icon(
                        icon,
                        size: 28,
                        color: selected
                            ? colors.onPrimaryContainer
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? colors.onPrimaryContainer
                              : colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        description,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: selected
                              ? colors.onPrimaryContainer
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        size: 20,
                        color: selected ? colors.primary : colors.outline,
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Icon(
                        icon,
                        color: selected
                            ? colors.onPrimaryContainer
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            color: selected
                                ? colors.onPrimaryContainer
                                : colors.onSurface,
                          ),
                        ),
                      ),
                      if (selected)
                        Icon(Icons.check_circle_rounded, color: colors.primary),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

final class WorkspacePage extends StatelessWidget {
  const WorkspacePage({
    super.key,
    required this.children,
    required this.storageKey,
  });
  final List<Widget> children;
  final String storageKey;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: PageStorageKey(storageKey),
    padding: EdgeInsets.fromLTRB(
      MediaQuery.sizeOf(context).width < 360 ? 20 : 24,
      20,
      MediaQuery.sizeOf(context).width < 360 ? 20 : 24,
      32,
    ),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

final class WorkspaceEyebrow extends StatelessWidget {
  const WorkspaceEyebrow({super.key, required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
    ],
  );
}

final class WorkspaceIcon extends StatelessWidget {
  const WorkspaceIcon({super.key, required this.icon, this.size = 44});
  final IconData icon;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Icon(icon, color: Theme.of(context).colorScheme.onPrimaryContainer),
  );
}

final class WorkspaceFeatureCard extends StatelessWidget {
  const WorkspaceFeatureCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.footer,
    required this.action,
  });
  final IconData icon;
  final String title;
  final String description;
  final String footer;
  final Widget action;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WorkspaceIcon(icon: icon, size: 48),
          const SizedBox(height: 20),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          Text(description, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 12),
          Text(
            footer,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          action,
        ],
      ),
    ),
  );
}

/// 用现有 Material 图形构成轻量空态，不加载外部字体、图片或服务。
final class ResumePaperIllustration extends StatelessWidget {
  const ResumePaperIllustration({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: SizedBox(
        width: 172,
        height: 138,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 138,
              height: 120,
              decoration: BoxDecoration(
                color: colors.primaryContainer.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(44),
              ),
            ),
            Transform.rotate(
              angle: -.08,
              child: Container(
                width: 94,
                height: 118,
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 25,
                      height: 25,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        Icons.person_outline_rounded,
                        size: 19,
                        color: colors.primary,
                      ),
                    ),
                    const SizedBox(height: 15),
                    for (final width in [52.0, 40.0, 47.0]) ...[
                      Container(
                        width: width,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                  ],
                ),
              ),
            ),
            Positioned(
              right: 10,
              bottom: 3,
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: colors.surfaceContainerLow,
                    width: 3,
                  ),
                ),
                child: Icon(
                  Icons.edit_outlined,
                  size: 19,
                  color: colors.onPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _friendlyDate(DateTime timestamp) {
  final local = timestamp.toLocal();
  return '${local.year}.${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')}';
}

final class _UnfinishedAiTaskCard extends StatelessWidget {
  const _UnfinishedAiTaskCard({
    required this.task,
    required this.isBusy,
    required this.onResume,
    this.onDiscard,
  });
  final RemoteTaskDraft task;
  final bool isBusy;
  final ValueChanged<RemoteTaskDraft> onResume;
  final ValueChanged<RemoteTaskDraft>? onDiscard;
  @override
  Widget build(BuildContext context) => WorkspaceFeatureCard(
    icon: Icons.history_rounded,
    title: task.kind == 'compose' ? '未完成的 AI 起草' : '未完成的岗位优化',
    description: '材料已保存在本机。继续时先取回原任务结果，不会重新发送生成。',
    footer: '草稿可恢复7天；补充材料时，再确认本次发送范围。',
    action: Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          key: ValueKey('继续未完成AI任务_${task.id}'),
          onPressed: isBusy ? null : () => onResume(task),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('继续完成任务'),
        ),
        if (onDiscard != null)
          TextButton(
            onPressed: isBusy ? null : () => onDiscard!(task),
            child: const Text('移除本机草稿'),
          ),
      ],
    ),
  );
}
