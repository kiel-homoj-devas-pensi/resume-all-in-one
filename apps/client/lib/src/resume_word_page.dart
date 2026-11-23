import 'package:document_io/document_io.dart';
import 'package:flutter/material.dart';
import 'package:resume_domain/resume_domain.dart';

import 'resume_pdf_preview_page.dart';
import 'resume_file_delivery.dart';
import 'resume_word_store.dart';
import 'resume_workspace_controller.dart';

enum _WordDraftChoice { continueEditing, discard, save }

final class ResumeWordPage extends StatefulWidget {
  const ResumeWordPage({
    super.key,
    required this.controller,
    required this.document,
    required this.version,
    required this.word,
  });
  final ResumeWorkspaceController controller;
  final ResumeDocument document;
  final ResumeVersion version;
  final SavedResumeWord word;

  @override
  State<ResumeWordPage> createState() => _ResumeWordPageState();
}

final class _ResumeWordPageState extends State<ResumeWordPage> {
  late SavedResumeWord _savedWord = widget.word;
  late List<ResumeWordParagraph> _draftParagraphs = List.of(
    _savedWord.content.paragraphs,
  );
  bool _busy = false;
  bool _asking = false;

  bool get _hasUnsavedChanges =>
      _draftParagraphs.length != _savedWord.content.paragraphs.length ||
      _draftParagraphs.indexed.any(
        (entry) =>
            entry.$2.text != _savedWord.content.paragraphs[entry.$1].text ||
            entry.$2.style != _savedWord.content.paragraphs[entry.$1].style,
      );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_hasUnsavedChanges && !_busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_busy) _leave();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('返回Word文稿'),
          tooltip: '返回简历',
          onPressed: _busy ? null : _leave,
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text(
          'Word 文稿',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<ResumeFileDeliveryAction>(
            key: const Key('Word交付菜单'),
            tooltip: '另存或分享 Word',
            enabled: !_busy,
            icon: const Icon(Icons.ios_share_outlined),
            onSelected: _deliver,
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: ResumeFileDeliveryAction.saveAs,
                child: Text('另存 Word', key: Key('另存Word')),
              ),
              PopupMenuItem(
                value: ResumeFileDeliveryAction.share,
                child: Text('分享 Word', key: Key('分享Word')),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_savedWord.content.aiProvenance != null ||
                _savedWord.content.aigcMetadata != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _savedWord.content.aigcMetadata?.notice ??
                      ResumeAiProvenance.notice,
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '修改文稿，再转为 PDF',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '轻触段落修改文字。这里是 Word 交付副本，修改不会回写简历历史。PDF 按简历模板排版，全程在本机处理。',
                          ),
                          const SizedBox(height: 20),
                          for (final entry in _draftParagraphs.indexed)
                            Card(
                              child: InkWell(
                                key: Key('Word段落_${entry.$1}'),
                                borderRadius: BorderRadius.circular(24),
                                onTap: _busy
                                    ? null
                                    : () => _editParagraph(entry.$1),
                                child: Padding(
                                  padding: const EdgeInsets.all(18),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          entry.$2.text.isEmpty
                                              ? '空段落'
                                              : entry.$2.text,
                                          style: _paragraphStyle(
                                            context,
                                            entry.$2.style,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Icon(
                                        Icons.edit_outlined,
                                        size: 18,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: const Key('添加Word段落'),
                            onPressed: _busy
                                ? null
                                : () => _editParagraph(null),
                            icon: const Icon(Icons.add),
                            label: const Text('添加段落'),
                          ),
                          const SizedBox(height: 16),
                          ExpansionTile(
                            title: const Text('本机文件位置'),
                            children: [SelectableText(_savedWord.path)],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _hasUnsavedChanges ? 'Word 有未保存的修改' : 'Word 已保存在本机',
                      key: const Key('Word保存状态'),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('保存Word'),
                          onPressed: _busy ? null : _save,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('保存 Word'),
                        ),
                        FilledButton.icon(
                          key: const Key('Word转PDF'),
                          onPressed: _busy ? null : _convert,
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: Text(_busy ? '处理中…' : '转为 PDF'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  TextStyle? _paragraphStyle(BuildContext context, ResumeWordStyle style) =>
      switch (style) {
        ResumeWordStyle.title => Theme.of(context).textTheme.headlineSmall,
        ResumeWordStyle.heading => Theme.of(context).textTheme.titleLarge,
        ResumeWordStyle.subtitle ||
        ResumeWordStyle.entryHeader => Theme.of(context).textTheme.titleMedium,
        ResumeWordStyle.metadata ||
        ResumeWordStyle.contact ||
        ResumeWordStyle.headline => Theme.of(context).textTheme.bodySmall,
        _ => Theme.of(context).textTheme.bodyLarge,
      };

  Future<void> _editParagraph(int? index) async {
    final originalParagraph = index == null ? null : _draftParagraphs[index];
    final paragraphEdit = await showDialog<({bool delete, String text})>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WordParagraphDialog(
        initialText: originalParagraph?.text ?? '',
        canDelete: index != null,
      ),
    );
    if (!mounted || paragraphEdit == null) return;
    setState(() {
      if (paragraphEdit.delete && index != null) {
        _draftParagraphs.removeAt(index);
      } else if (!paragraphEdit.delete) {
        final paragraph = ResumeWordParagraph(
          text: paragraphEdit.text,
          style: originalParagraph?.style ?? ResumeWordStyle.body,
        );
        if (index == null) {
          _draftParagraphs.add(paragraph);
        } else {
          _draftParagraphs[index] = paragraph;
        }
      }
    });
  }

  Future<bool> _save() async {
    if (!_hasUnsavedChanges) return true;
    setState(() => _busy = true);
    final saved = await widget.controller.saveWord(
      widget.version,
      ResumeWordDocument(
        paragraphs: _draftParagraphs,
        photo: _savedWord.content.photo,
        aiProvenance: _savedWord.content.aiProvenance,
        aigcMetadata: _savedWord.content.aigcMetadata,
      ),
    );
    if (!mounted) return false;
    setState(() {
      _busy = false;
      if (saved != null) {
        _savedWord = saved;
        _draftParagraphs = List.of(saved.content.paragraphs);
      }
    });
    _feedback(
      saved == null ? widget.controller.takeFeedback() : 'Word 已保存，原文稿仍保留。',
    );
    return saved != null;
  }

  Future<bool> _resolveDraft() async {
    if (!_hasUnsavedChanges) return true;
    if (_asking) return false;
    _asking = true;
    final choice = await showDialog<_WordDraftChoice>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('保存 Word 修改？'),
        content: const Text('转换、另存与分享只使用已保存的 Word。放弃修改不会删除原文件。'),
        actions: [
          TextButton(
            key: const Key('继续编辑Word'),
            onPressed: () =>
                Navigator.pop(context, _WordDraftChoice.continueEditing),
            child: const Text('继续编辑'),
          ),
          TextButton(
            key: const Key('放弃Word修改'),
            onPressed: () => Navigator.pop(context, _WordDraftChoice.discard),
            child: const Text('放弃修改'),
          ),
          FilledButton(
            key: const Key('保存Word并继续'),
            onPressed: () => Navigator.pop(context, _WordDraftChoice.save),
            child: const Text('保存并继续'),
          ),
        ],
      ),
    );
    _asking = false;
    if (!mounted) return false;
    if (choice == _WordDraftChoice.save) return _save();
    if (choice == _WordDraftChoice.discard) {
      setState(() => _draftParagraphs = List.of(_savedWord.content.paragraphs));
      return true;
    }
    return false;
  }

  Future<void> _leave() async {
    if (await _resolveDraft() && mounted) Navigator.pop(context);
  }

  Future<void> _convert() async {
    if (!await _resolveDraft() || !mounted) return;
    setState(() => _busy = true);
    final prepared = await widget.controller.convertWordToPdf(
      _savedWord,
      widget.document,
      widget.version,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (prepared == null) {
      _feedback(widget.controller.takeFeedback());
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ResumePdfPreviewPage(
          controller: widget.controller,
          preparedPdf: prepared,
        ),
      ),
    );
  }

  Future<void> _deliver(ResumeFileDeliveryAction action) async {
    if (!await _resolveDraft() || !mounted) return;
    setState(() => _busy = true);
    await widget.controller.deliverSavedWord(_savedWord, action);
    if (!mounted) return;
    setState(() => _busy = false);
    _feedback(widget.controller.takeFeedback());
  }

  void _feedback(String? message) {
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _WordParagraphDialog extends StatefulWidget {
  const _WordParagraphDialog({
    required this.initialText,
    required this.canDelete,
  });
  final String initialText;
  final bool canDelete;
  @override
  State<_WordParagraphDialog> createState() => _WordParagraphDialogState();
}

final class _WordParagraphDialogState extends State<_WordParagraphDialog> {
  late final _text = TextEditingController(text: widget.initialText)
    ..addListener(_changed);
  bool _asking = false;
  void _changed() => setState(() {});
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _cancel() async {
    if (_asking) return;
    if (_text.text == widget.initialText) {
      Navigator.pop(context);
      return;
    }
    _asking = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('放弃这段修改？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续填写'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    _asking = false;
    if (discard == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _text.text == widget.initialText,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _cancel();
    },
    child: AlertDialog(
      scrollable: true,
      title: const Text('编辑段落'),
      content: SizedBox(
        width: 560,
        child: TextField(
          key: const Key('Word段落文字'),
          controller: _text,
          minLines: 3,
          maxLines: 12,
          // 原文可能是合法的长 summary/unmapped；输入格式器不能静默截断它。
          // 容量由文稿 codec 在保存时校验，失败仍保留当前草稿。
          decoration: const InputDecoration(labelText: '段落文字'),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('取消')),
        if (widget.canDelete)
          TextButton(
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  scrollable: true,
                  title: const Text('删除此段落？'),
                  content: const Text('只从当前 Word 草稿移除，已保存副本不变。'),
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
              if (confirmed == true && context.mounted) {
                Navigator.pop(context, (delete: true, text: ''));
              }
            },
            child: const Text('删除段落'),
          ),
        FilledButton(
          key: const Key('完成Word段落'),
          onPressed: () =>
              Navigator.pop(context, (delete: false, text: _text.text)),
          child: const Text('完成'),
        ),
      ],
    ),
  );
}
