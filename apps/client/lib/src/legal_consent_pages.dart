import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'legal_consent_controller.dart';
import 'legal_documents.dart';

/// The introduction records an explicit choice without preventing local editing.
final class LegalConsentIntroduction extends StatefulWidget {
  const LegalConsentIntroduction({
    super.key,
    required this.controller,
    required this.onContinue,
  });

  final LegalConsentController controller;
  final VoidCallback onContinue;

  @override
  State<LegalConsentIntroduction> createState() =>
      _LegalConsentIntroductionState();
}

final class _LegalConsentIntroductionState
    extends State<LegalConsentIntroduction> {
  String? _choiceHash;
  bool _termsChecked = false;
  bool _privacyChecked = false;
  bool _adultConfirmed = false;
  bool _suppressReminder = false;

  void _changeChoice(LegalBundle bundle, VoidCallback update) {
    setState(() {
      if (_choiceHash != bundle.contentHash) {
        _termsChecked = false;
        _privacyChecked = false;
        _adultConfirmed = false;
        _suppressReminder = widget.controller.isCurrentReminderSuppressed;
        _choiceHash = bundle.contentHash;
      }
      update();
    });
  }

  Future<void> _accept() async {
    final accepted = await widget.controller.accept(
      termsChecked: _termsChecked,
      privacyChecked: _privacyChecked,
      adultConfirmed: _adultConfirmed,
    );
    if (mounted && accepted) widget.onContinue();
  }

  Future<void> _continueLocally() async {
    final continued = await widget.controller.continueLocally(
      suppressReminder: _choiceHash == widget.controller.bundle?.contentHash
          ? _suppressReminder
          : widget.controller.isCurrentReminderSuppressed,
    );
    if (mounted && continued) widget.onContinue();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final bundle = controller.bundle;
      final sameBundle = _choiceHash == bundle?.contentHash;
      final busy = controller.isLoading || controller.isSaving;
      final termsChecked = sameBundle && _termsChecked;
      final privacyChecked = sameBundle && _privacyChecked;
      final adultConfirmed = sameBundle && _adultConfirmed;
      final allOpened =
          bundle != null &&
          bundle.documents.every(
            (document) => controller.hasOpenedDocument(document.id),
          );
      final canAccept =
          !busy &&
          bundle != null &&
          controller.canAcceptCurrentBundle &&
          allOpened &&
          termsChecked &&
          privacyChecked &&
          adultConfirmed;
      return PopScope(
        canPop: false,
        child: Dialog(
          key: const Key('首次使用协议弹窗'),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          constraints: const BoxConstraints(maxWidth: 560),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 560,
            height: MediaQuery.sizeOf(context).height * .84,
            child: Scaffold(
              appBar: AppBar(
                automaticallyImplyLeading: false,
                title: const Text('欢迎使用简历全能帮'),
              ),
              body: SafeArea(
                child: _LegalBody(
                  children: [
                    Text(
                      '先了解，再选择',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const Text(
                      '本地简历编辑、版本管理和导出可继续使用。账号和联网 AI 服务仅面向已满18周岁用户，需要先阅读并同意完整有效的用户协议与隐私政策；每次发送材料仍会单独确认。',
                    ),
                    if (busy) const LinearProgressIndicator(),
                    if (bundle != null) ...[
                      _BundleStatus(bundle: bundle),
                      for (final document in bundle.documents)
                        _FoldedLegalDocument(
                          key: ValueKey('${bundle.contentHash}:${document.id}'),
                          bundle: bundle,
                          document: document,
                          onOpened: () =>
                              controller.markDocumentOpened(document.id),
                        ),
                      const Text('点击展开协议全文，阅读后分别确认。未同意时仅使用本地功能。'),
                      CheckboxListTile(
                        key: const Key('同意用户协议'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: termsChecked,
                        onChanged: busy || !controller.canAcceptCurrentBundle
                            ? null
                            : (value) => _changeChoice(
                                bundle,
                                () => _termsChecked = value ?? false,
                              ),
                        title: const Text('我已阅读并同意《用户协议》'),
                      ),
                      CheckboxListTile(
                        key: const Key('同意隐私政策'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: privacyChecked,
                        onChanged: busy || !controller.canAcceptCurrentBundle
                            ? null
                            : (value) => _changeChoice(
                                bundle,
                                () => _privacyChecked = value ?? false,
                              ),
                        title: const Text('我已阅读并同意《隐私政策》'),
                      ),
                      CheckboxListTile(
                        key: const Key('确认已满18周岁'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: adultConfirmed,
                        onChanged: busy || !controller.canAcceptCurrentBundle
                            ? null
                            : (value) => _changeChoice(
                                bundle,
                                () => _adultConfirmed = value ?? false,
                              ),
                        title: const Text('我已满18周岁'),
                        subtitle: const Text(
                          '未确认可继续使用本地功能。不采集身份证或完整生日；此声明不代替协议同意。',
                        ),
                      ),
                      FilledButton(
                        key: const Key('同意并继续'),
                        onPressed: canAccept ? _accept : null,
                        child: const Text('同意并启用联网'),
                      ),
                      if (!bundle.isComplete)
                        const Text(
                          '当前为待补充草案，尚不能同意或启用联网服务。可查看全部内容与待填信息，继续使用本地功能。',
                        ),
                      if (bundle.isComplete &&
                          !controller.canAcceptCurrentBundle)
                        Text(controller.blockedReason),
                      CheckboxListTile(
                        key: const Key('不再提醒当前版本'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: sameBundle
                            ? _suppressReminder
                            : controller.isCurrentReminderSuppressed,
                        onChanged: busy
                            ? null
                            : (value) => _changeChoice(
                                bundle,
                                () => _suppressReminder = value ?? false,
                              ),
                        title: const Text('不再提醒当前版本'),
                        subtitle: const Text(
                          '仅保存提醒偏好，不代表同意，也不会开启联网功能。仅取消启动提醒；主动使用联网功能时仍需同意。文档内容更新后会重新提醒。',
                        ),
                      ),
                    ],
                    if (controller.errorMessage != null)
                      _LegalError(message: controller.errorMessage!),
                    OutlinedButton(
                      key: const Key('仅使用本地功能'),
                      onPressed: busy ? null : _continueLocally,
                      child: const Text('暂不同意，仅使用本地功能'),
                    ),
                    const Text(
                      '已同意同一版本后，启动时不会重复弹出协议窗口。随时可在设置的“协议与隐私”中阅读、查看本机记录或撤回同意。',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// An intentional attempt to use a remote feature ignores startup suppression.
Future<bool> showLegalConsentPrompt(
  BuildContext context,
  LegalConsentController controller,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => LegalConsentIntroduction(
        controller: controller,
        onContinue: () =>
            Navigator.of(dialogContext).pop(controller.canUseRemoteServices),
      ),
    ) ??
    false;

/// Opens the same offline policy used by the consent flow, without granting consent.
Future<void> showBundledPrivacyPolicy(BuildContext context) async {
  try {
    final source = await rootBundle.loadString(
      'assets/legal/legal_bundle.json',
    );
    final bundle = LegalBundle.fromJson(
      jsonDecode(source) as Map<String, dynamic>,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _LegalDocumentPage(
          bundle: bundle,
          document: bundle.documents.firstWhere((doc) => doc.id == 'privacy'),
        ),
      ),
    );
  } on Object {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('隐私政策暂时无法读取，请稍后重试。')));
  }
}

final class _FoldedLegalDocument extends StatelessWidget {
  const _FoldedLegalDocument({
    super.key,
    required this.bundle,
    required this.document,
    required this.onOpened,
  });
  final LegalBundle bundle;
  final LegalDocument document;
  final VoidCallback onOpened;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: Key('阅读${document.id}'),
    initiallyExpanded: false,
    title: Text('${document.title}（${document.version}）'),
    subtitle: const Text('展开阅读完整内容'),
    onExpansionChanged: (expanded) {
      if (expanded) onOpened();
    },
    childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
    children: [
      if (!bundle.isComplete) const Text('待补充草案，尚未生效。空白及注释为负责人待填写信息。'),
      for (final section in document.sections) ...[
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            section.heading,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final paragraph in section.paragraphs)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                bundle.renderText(paragraph),
                style: section.important
                    ? const TextStyle(fontWeight: FontWeight.bold)
                    : null,
              ),
            ),
          ),
      ],
    ],
  );
}

Future<void> showLegalCenter(
  BuildContext context,
  LegalConsentController controller, {
  Future<bool> Function()? enableNetwork,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) =>
        _LegalCenter(controller: controller, enableNetwork: enableNetwork),
  ),
);

final class _LegalCenter extends StatelessWidget {
  const _LegalCenter({required this.controller, this.enableNetwork});

  final Future<bool> Function()? enableNetwork;

  final LegalConsentController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final bundle = controller.bundle;
      return Scaffold(
        appBar: AppBar(title: const Text('协议与隐私')),
        body: SafeArea(
          child: _LegalBody(
            children: [
              Text(
                controller.canUseRemoteServices ? '当前已同意' : '当前仅使用本地功能',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!controller.canUseRemoteServices)
                Text(controller.blockedReason),
              if (controller.isLoading || controller.isSaving)
                const LinearProgressIndicator(),
              if (bundle != null) ...[
                _BundleStatus(bundle: bundle),
                for (final document in bundle.documents)
                  _DocumentButton(
                    document: document,
                    opened: controller.hasOpenedDocument(document.id),
                    onPressed: () => _openDocument(
                      context,
                      bundle,
                      document,
                      onOpened: () =>
                          controller.markDocumentOpened(document.id),
                    ),
                  ),
                if (!controller.canUseRemoteServices)
                  OutlinedButton(
                    key: const Key('重新选择协议'),
                    onPressed: controller.isSaving
                        ? null
                        : () async {
                            if (await showLegalConsentPrompt(
                              context,
                              controller,
                            )) {
                              await enableNetwork?.call();
                            }
                          },
                    child: const Text('查看并重新选择'),
                  ),
              ],
              if (controller.errorMessage != null)
                _LegalError(message: controller.errorMessage!),
              if (controller.canUseRemoteServices)
                OutlinedButton(
                  key: const Key('撤回协议同意'),
                  onPressed: controller.isSaving
                      ? null
                      : () => _confirmWithdrawal(context, controller),
                  child: const Text('撤回同意，转为本地使用'),
                ),
              Text('本机版本与选择记录', style: Theme.of(context).textTheme.titleLarge),
              const Text(
                '记录保存在当前设备，包含文档内容摘要和选择时间，不是服务端签署证明。设备时钟可能不准确；清除应用数据会移除这些记录。',
              ),
              if (controller.records.isEmpty) const Text('当前设备尚无选择记录。'),
              for (final record in controller.records.reversed)
                _RecordTile(controller: controller, record: record),
              OutlinedButton.icon(
                key: const Key('复制协议选择记录'),
                onPressed: controller.records.isEmpty
                    ? null
                    : () => _copyText(
                        context,
                        controller.exportRecordText(),
                        '本机记录已复制',
                      ),
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制本机记录'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _confirmWithdrawal(
  BuildContext context,
  LegalConsentController controller,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('撤回同意'),
      scrollable: true,
      content: const Text(
        '撤回后将停止本机后续账号及联网 AI 操作。本地简历、历史版本和已导出的文件不会因此被删除。撤回不能撤销已经发送的请求，也不等于注销账号或删除服务端已有信息。需要处理已有信息时，请按隐私政策提供的途径提出请求。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('保留同意'),
        ),
        FilledButton(
          key: const Key('确认撤回同意'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('确认撤回'),
        ),
      ],
    ),
  );
  if (confirmed == true) await controller.withdraw();
}

final class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.controller, required this.record});

  final LegalConsentController controller;
  final LegalConsentRecord record;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.bundleForHash(record.bundleHash);
    final action = switch (record.action) {
      LegalConsentAction.accepted => '同意用户协议与隐私政策',
      LegalConsentAction.localOnly => '仅使用本地功能',
      LegalConsentAction.withdrawn => '撤回同意',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Text('#${record.sequence} $action'),
            Text('记录时间（UTC）：${record.recordedAtUtc.toUtc().toIso8601String()}'),
            if (record.suppressReminder) const Text('该次选择：不再提醒当前版本'),
            if (record.action == LegalConsentAction.accepted)
              Text(
                record.adultConfirmed
                    ? '该次声明：我已满18周岁（用户自行确认）'
                    : '该次记录不含年龄声明，不授予当前联网权限',
              ),
            SelectableText('内容摘要：${record.bundleHash}'),
            if (snapshot == null)
              const Text('该版本的本机文档快照不可用，不能以当前文档代替。')
            else
              for (final document in snapshot.documents)
                TextButton(
                  onPressed: () => _openDocument(context, snapshot, document),
                  child: Text('阅读记录中的${document.title}（${document.version}）'),
                ),
          ],
        ),
      ),
    );
  }
}

final class _BundleStatus extends StatelessWidget {
  const _BundleStatus({required this.bundle});

  final LegalBundle bundle;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Text(bundle.statusLabel),
          Text(
            bundle.documents
                .map((doc) => '${doc.title} v${doc.version}')
                .join(' · '),
          ),
          Text(
            '${bundle.status == 'final' ? '计划公开公布' : '公布'}：${bundle.publicationDateLabel}（北京时间）',
          ),
          Text(
            '${bundle.status == 'final' ? '计划公开生效' : '生效'}：${bundle.effectiveDateLabel}（北京时间）',
          ),
          if (bundle.pendingFields.isNotEmpty)
            ExpansionTile(
              key: const Key('查看待填写信息'),
              tilePadding: EdgeInsets.zero,
              title: Text('待填写信息（${bundle.pendingFields.length}项）'),
              children: [
                for (final field in bundle.pendingFields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        '${field.label}：________（待补充；${field.reason}）',
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    ),
  );
}

final class _DocumentButton extends StatelessWidget {
  const _DocumentButton({
    required this.document,
    required this.opened,
    required this.onPressed,
  });

  final LegalDocument document;
  final bool opened;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: Key('阅读${document.id}'),
    onPressed: onPressed,
    icon: Icon(opened ? Icons.article : Icons.article_outlined),
    label: Text(
      '${document.title}（${document.version}）${opened ? ' · 已打开' : ''}',
    ),
  );
}

Future<void> _openDocument(
  BuildContext context,
  LegalBundle bundle,
  LegalDocument document, {
  VoidCallback? onOpened,
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _LegalDocumentPage(bundle: bundle, document: document),
    ),
  );
  // This only enables the explicit choice; reading is never a consent event.
  onOpened?.call();
}

final class _LegalDocumentPage extends StatelessWidget {
  const _LegalDocumentPage({required this.bundle, required this.document});

  final LegalBundle bundle;
  final LegalDocument document;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(document.title)),
    body: SafeArea(
      child: SelectionArea(
        child: _LegalBody(
          children: [
            Text('版本：${document.version}'),
            Text(bundle.statusLabel),
            Text(
              '${bundle.status == 'final' ? '计划公开生效' : '生效'}：${bundle.effectiveDateLabel}（北京时间）',
            ),
            if (!bundle.isComplete) const Text('待补充草案，尚未生效。空白及注释为负责人待填写信息。'),
            const Text('全文已随应用保存在本机，可离线阅读。复制仅在你点击后写入系统剪贴板。'),
            OutlinedButton.icon(
              key: const Key('复制文档全文'),
              onPressed: () =>
                  _copyText(context, document.plainText(bundle), '文档全文已复制'),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制全文'),
            ),
            for (final section in document.sections) ...[
              Text(
                section.heading,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final paragraph in section.paragraphs)
                Text(
                  bundle.renderText(paragraph),
                  style: section.important
                      ? const TextStyle(fontWeight: FontWeight.bold)
                      : null,
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

Future<void> _copyText(
  BuildContext context,
  String text,
  String message,
) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

final class _LegalBody extends StatelessWidget {
  const _LegalBody({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, index) => children[index],
      ),
    ),
  );
}

final class _LegalError extends StatelessWidget {
  const _LegalError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}
