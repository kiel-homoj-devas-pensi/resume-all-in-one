import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:resume_domain/resume_domain.dart';

/// 以逐项表单编辑 Canonical 集合；控制器仅用作与整份简历草稿的桥接。
final class ResumeCollectionEditor extends StatelessWidget {
  const ResumeCollectionEditor({
    super.key,
    required this.sectionKey,
    required this.controller,
    this.enabled = true,
  });

  final String sectionKey;
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, editingValue, child) {
        final List<JsonMap> entries;
        try {
          final decoded = jsonDecode(editingValue.text);
          if (decoded is! List || decoded.any((entry) => entry is! Map)) {
            throw const FormatException('集合内容格式无效');
          }
          entries = decoded
              .map((entry) => Map<String, Object?>.from(entry as Map))
              .toList();
        } on FormatException {
          // 不用空数组覆盖无法解析的旧草稿，避免用户保存时静默丢失数据。
          return const Text('这部分内容暂时无法读取。请重新打开简历后再试，原内容仍保留。');
        }
        return _CollectionList(
          sectionKey: sectionKey,
          entries: entries,
          enabled: enabled,
          onChanged: (updatedEntries) {
            controller.text = jsonEncode(updatedEntries);
          },
        );
      },
    );
  }
}

const _collectionLabels = {
  'links': '链接',
  'workExperiences': '工作经历',
  'educations': '教育经历',
  'projects': '项目经历',
  'skillGroups': '技能分组',
  'certifications': '证书',
  'languages': '语言',
  'customSections': '自定义区段',
  'items': '内容条目',
};

const _collectionIcons = <String, IconData>{
  'links': Icons.link_rounded,
  'workExperiences': Icons.work_outline_rounded,
  'educations': Icons.school_outlined,
  'projects': Icons.folder_outlined,
  'skillGroups': Icons.auto_awesome_outlined,
  'certifications': Icons.workspace_premium_outlined,
  'languages': Icons.translate_rounded,
  'customSections': Icons.view_agenda_outlined,
  'items': Icons.notes_rounded,
};

enum _EntryAction { edit, up, down, delete }

final class _CollectionList extends StatelessWidget {
  const _CollectionList({
    required this.sectionKey,
    required this.entries,
    required this.onChanged,
    this.enabled = true,
  });

  final String sectionKey;
  final List<JsonMap> entries;
  final ValueChanged<List<JsonMap>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _collectionLabels[sectionKey]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (entries.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Icon(
                  _collectionIcons[sectionKey],
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 10),
                Text('还没有$label', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  '按需添加，让简历更完整。',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        for (final (index, entry) in entries.indexed) ...[
          Material(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              key: ValueKey('${sectionKey}_entry_${entry['id']}'),
              borderRadius: BorderRadius.circular(18),
              onTap: enabled ? () => _edit(context, index) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _entryTitle(sectionKey, entry),
                            style: theme.textTheme.titleSmall,
                          ),
                          if (_entrySubtitle(sectionKey, entry).isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              _entrySubtitle(sectionKey, entry),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    PopupMenuButton<_EntryAction>(
                      key: ValueKey('${sectionKey}_menu_${entry['id']}'),
                      enabled: enabled,
                      tooltip: '${_entryTitle(sectionKey, entry)}的操作',
                      icon: const Icon(Icons.more_vert_rounded),
                      onSelected: (action) => _act(context, index, action),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: _EntryAction.edit,
                          child: Text('编辑'),
                        ),
                        PopupMenuItem(
                          value: _EntryAction.up,
                          enabled: index > 0,
                          child: const Text('上移'),
                        ),
                        PopupMenuItem(
                          value: _EntryAction.down,
                          enabled: index + 1 < entries.length,
                          child: const Text('下移'),
                        ),
                        const PopupMenuItem(
                          value: _EntryAction.delete,
                          child: Text('删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: ValueKey('${sectionKey}_add'),
            onPressed: enabled ? () => _edit(context, null) : null,
            icon: const Icon(Icons.add_rounded),
            label: Text('添加$label'),
          ),
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, int? index) async {
    final editedEntry = await showDialog<JsonMap>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CollectionEntryDialog(
        sectionKey: sectionKey,
        entry: index == null ? _newEntry(sectionKey) : entries[index],
        isNew: index == null,
      ),
    );
    if (!context.mounted || editedEntry == null) {
      return;
    }
    final updatedEntries = [...entries];
    if (index == null) {
      updatedEntries.add(editedEntry);
    } else {
      updatedEntries[index] = editedEntry;
    }
    onChanged(updatedEntries);
  }

  Future<void> _act(
    BuildContext context,
    int index,
    _EntryAction action,
  ) async {
    if (action == _EntryAction.edit) {
      await _edit(context, index);
      return;
    }
    final updatedEntries = [...entries];
    if (action == _EntryAction.delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删除这条${_collectionLabels[sectionKey]}？'),
          content: const Text('将从当前草稿移除。已保存的历史版本仍会保留。'),
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
      if (!context.mounted || confirmed != true) {
        return;
      }
      updatedEntries.removeAt(index);
    } else {
      final destination = action == _EntryAction.up ? index - 1 : index + 1;
      if (destination < 0 || destination >= entries.length) {
        return;
      }
      updatedEntries.insert(destination, updatedEntries.removeAt(index));
    }
    onChanged(updatedEntries);
  }
}

final class _CollectionEntryDialog extends StatefulWidget {
  const _CollectionEntryDialog({
    required this.sectionKey,
    required this.entry,
    required this.isNew,
  });

  final String sectionKey;
  final JsonMap entry;
  final bool isNew;

  @override
  State<_CollectionEntryDialog> createState() => _CollectionEntryDialogState();
}

final class _CollectionEntryDialogState extends State<_CollectionEntryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  final _errorKey = GlobalKey();
  late final JsonMap _draft;
  String? _error;
  bool _confirmingDiscard = false;

  @override
  void initState() {
    super.initState();
    // 直接编辑原始树的副本，未展示的扩展字段和嵌套扩展不因表单重建丢失。
    _draft = Map<String, Object?>.from(
      jsonDecode(jsonEncode(widget.entry)) as Map,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<JsonMap>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            maxHeight: MediaQuery.sizeOf(context).height * .88,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题和错误也参与滚动，给键盘弹出、放大文字后的输入区留出空间。
              Flexible(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(
                            '${widget.isNew ? '添加' : '编辑'}${_collectionLabels[widget.sectionKey]}',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '只填写真实信息，标有 * 的项目为必填。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Semantics(
                            key: _errorKey,
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        ..._fields(),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: 12,
                  overflowSpacing: 8,
                  children: [
                    TextButton(
                      key: const Key('取消条目编辑'),
                      onPressed: _cancel,
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const Key('完成条目编辑'),
                      onPressed: _complete,
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _fields() => switch (widget.sectionKey) {
    'links' => [
      _text('label', '链接名称', required: true, hint: '例如：个人网站'),
      _text('url', '网址', hint: 'https://', keyboard: TextInputType.url),
    ],
    'workExperiences' => [
      _text('organization', '公司 / 组织', required: true),
      _text('position', '职位', required: true),
      _dateRange(required: true),
      _text('summary', '工作概述', multiline: true),
      _strings('highlights', '工作成果', '添加一项成果'),
    ],
    'educations' => [
      _text('institution', '学校', required: true),
      _text('degree', '学位 / 学历'),
      _text('fieldOfStudy', '专业'),
      _dateRange(required: true),
      _strings('highlights', '在校经历与成果', '添加一项经历'),
    ],
    'projects' => [
      _text('name', '项目名称', required: true),
      _text('role', '担任角色'),
      _dateRange(required: false),
      _text('summary', '项目概述', multiline: true),
      _strings('highlights', '项目成果', '添加一项成果'),
      _nested('links', '项目链接'),
    ],
    'skillGroups' => [
      _text('name', '技能分组名称', required: true, hint: '例如：产品设计'),
      _strings('skills', '技能', '添加一项技能', required: true),
    ],
    'certifications' => [
      _text('name', '证书名称', required: true),
      _text('issuer', '颁发机构'),
      _date('issuedOn', '颁发日期'),
      _date('expiresOn', '到期日期'),
      _text('credentialId', '证书编号'),
      _text('credentialUrl', '验证网址', keyboard: TextInputType.url),
    ],
    'languages' => [
      _text('name', '语言名称', required: true),
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: DropdownButtonFormField<String>(
          key: const Key('条目字段_proficiency'),
          initialValue: _draft['proficiency'] as String,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '熟练程度'),
          items: [
            for (final proficiency in _proficiencyLabels.entries)
              DropdownMenuItem(
                value: proficiency.key,
                child: Text(proficiency.value),
              ),
          ],
          onChanged: (proficiency) {
            if (proficiency != null) {
              _draft['proficiency'] = proficiency;
            }
          },
        ),
      ),
    ],
    'customSections' => [
      _text('title', '区段名称', required: true, hint: '例如：志愿服务'),
      _nested('items', '区段内容'),
    ],
    'items' => [
      _text('title', '条目标题', required: true),
      _text('description', '内容描述', multiline: true),
    ],
    _ => throw ArgumentError.value(widget.sectionKey, 'sectionKey'),
  };

  Widget _text(
    String field,
    String label, {
    bool required = false,
    bool multiline = false,
    String? hint,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: ValueKey('条目字段_$field'),
      initialValue: _draft[field] as String,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? 6 : 1,
      keyboardType: keyboard ?? (multiline ? TextInputType.multiline : null),
      decoration: InputDecoration(
        labelText: '$label${required ? ' *' : ''}',
        hintText: hint,
        errorMaxLines: 3,
      ),
      validator: required
          ? (text) => text == null || text.trim().isEmpty ? '请填写$label' : null
          : null,
      onChanged: (text) => _draft[field] = text,
    ),
  );

  Widget _dateRange({required bool required}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: _DateRangeFields(
      initialValue: _draft['dateRange'] as JsonMap?,
      required: required,
      onChanged: (dateRange) => _draft['dateRange'] = dateRange,
    ),
  );

  Widget _date(String field, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: _DateFields(
      fieldKey: field,
      label: label,
      initialValue: _draft[field] as JsonMap?,
      onChanged: (date) => _draft[field] = date,
    ),
  );

  Widget _strings(
    String field,
    String label,
    String addLabel, {
    bool required = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: _StringListFields(
      fieldKey: field,
      label: label,
      addLabel: addLabel,
      initialValue: List<String>.from(_draft[field]! as List),
      required: required,
      onChanged: (strings) => _draft[field] = strings,
    ),
  );

  Widget _nested(String field, String label) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      _CollectionList(
        sectionKey: field,
        entries: (_draft[field]! as List)
            .map((entry) => Map<String, Object?>.from(entry as Map))
            .toList(),
        onChanged: (entries) => setState(() => _draft[field] = entries),
      ),
    ],
  );

  void _complete() {
    if (!_formKey.currentState!.validate()) {
      _showError('请检查标红的必填项或日期。');
      return;
    }
    try {
      final entryValidation = const ResumeValidator().validate(
        _resumeForEntryValidation(widget.sectionKey, _draft),
      );
      final blockingIssues = entryValidation.issues.where(
        (issue) => issue.blocksCommit,
      );
      if (blockingIssues.isNotEmpty) {
        _showError(blockingIssues.map((issue) => issue.message).join('\n'));
        return;
      }
      Navigator.pop(context, _draft);
    } on FormatException catch (error) {
      _showError(error.message);
    }
  }

  void _showError(String message) {
    setState(() => _error = message);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final errorContext = _errorKey.currentContext;
      if (mounted && errorContext != null) {
        Scrollable.ensureVisible(
          errorContext,
          alignment: 0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _cancel() async {
    if (_confirmingDiscard) return;
    if (jsonDeepEquals(_draft, widget.entry)) {
      Navigator.pop(context);
      return;
    }
    _confirmingDiscard = true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('放弃这条修改？'),
        content: const Text('这条内容尚未加入简历草稿，放弃后本次输入不会保留。'),
        actions: [
          TextButton(
            key: const Key('继续填写条目'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续填写'),
          ),
          FilledButton(
            key: const Key('放弃条目修改'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    _confirmingDiscard = false;
    if (mounted && discard == true) Navigator.pop(context);
  }
}

final class _DateRangeFields extends StatefulWidget {
  const _DateRangeFields({
    required this.initialValue,
    required this.required,
    required this.onChanged,
  });

  final JsonMap? initialValue;
  final bool required;
  final ValueChanged<JsonMap?> onChanged;

  @override
  State<_DateRangeFields> createState() => _DateRangeFieldsState();
}

final class _DateRangeFieldsState extends State<_DateRangeFields> {
  late bool _hasRange;
  late final JsonMap _range;

  @override
  void initState() {
    super.initState();
    _hasRange = widget.initialValue != null || widget.required;
    _range = widget.initialValue ?? _emptyDateRange();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!widget.required)
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('填写项目时间'),
          subtitle: const Text('可只填写年份；关闭将移除整个时间段。'),
          value: _hasRange,
          onChanged: (enabled) {
            setState(() => _hasRange = enabled);
            widget.onChanged(enabled ? _range : null);
          },
        ),
      if (_hasRange) ...[
        _DateFields(
          fieldKey: 'start',
          label: '开始日期',
          required: true,
          initialValue: _range['start'] as JsonMap,
          onChanged: (date) {
            _range['start'] = date;
            widget.onChanged(_range);
          },
        ),
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          key: const Key('条目日期_至今'),
          contentPadding: EdgeInsets.zero,
          title: const Text('至今'),
          subtitle: const Text('仍在进行时开启；如已填写结束日期，请先关闭结束日期。'),
          value: _range['isCurrent']! as bool,
          onChanged: (isCurrent) {
            setState(() => _range['isCurrent'] = isCurrent);
            widget.onChanged(_range);
          },
        ),
        _DateFields(
          fieldKey: 'end',
          label: '结束日期',
          initialValue: _range['end'] as JsonMap?,
          onChanged: (date) {
            _range['end'] = date;
            widget.onChanged(_range);
          },
        ),
      ],
    ],
  );
}

final class _DateFields extends StatefulWidget {
  const _DateFields({
    required this.fieldKey,
    required this.label,
    required this.initialValue,
    required this.onChanged,
    this.required = false,
  });

  final String fieldKey;
  final String label;
  final JsonMap? initialValue;
  final ValueChanged<JsonMap?> onChanged;
  final bool required;

  @override
  State<_DateFields> createState() => _DateFieldsState();
}

final class _DateFieldsState extends State<_DateFields> {
  late bool _hasDate;
  late final JsonMap _date;

  @override
  void initState() {
    super.initState();
    _hasDate = widget.initialValue != null || widget.required;
    _date = widget.initialValue ?? {'year': '', 'month': null};
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!widget.required)
        SwitchListTile.adaptive(
          key: ValueKey('条目日期_${widget.fieldKey}_开关'),
          contentPadding: EdgeInsets.zero,
          title: Text('填写${widget.label}'),
          subtitle: const Text('关闭将移除此日期。'),
          value: _hasDate,
          onChanged: (enabled) {
            setState(() => _hasDate = enabled);
            widget.onChanged(enabled ? _date : null);
          },
        )
      else ...[
        Text(
          '${widget.label} *',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
      ],
      if (_hasDate) ...[
        TextFormField(
          key: ValueKey('条目日期_${widget.fieldKey}_year'),
          initialValue: '${_date['year']}',
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: '${widget.label} · 年份 *',
            hintText: '例如：2024',
            errorMaxLines: 3,
          ),
          validator: (text) {
            final year = int.tryParse(text ?? '');
            return year == null || year < 1900 || year > 2200
                ? '请输入 1900–2200 之间的年份'
                : null;
          },
          onChanged: (text) {
            _date['year'] = int.tryParse(text) ?? text;
            widget.onChanged(_date);
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: ValueKey('条目日期_${widget.fieldKey}_month'),
          initialValue: _date['month']?.toString() ?? '',
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: '${widget.label} · 月份',
            helperText: '不确定月份时留空，保留年份精度。',
            helperMaxLines: 3,
            errorMaxLines: 3,
          ),
          validator: (text) {
            if (text == null || text.isEmpty) {
              return null;
            }
            final month = int.tryParse(text);
            return month == null || month < 1 || month > 12
                ? '请输入 1–12 之间的月份，或留空'
                : null;
          },
          onChanged: (text) {
            _date['month'] = text.isEmpty ? null : int.tryParse(text) ?? text;
            widget.onChanged(_date);
          },
        ),
      ],
    ],
  );
}

final class _StringListFields extends StatefulWidget {
  const _StringListFields({
    required this.fieldKey,
    required this.label,
    required this.addLabel,
    required this.initialValue,
    required this.onChanged,
    required this.required,
  });

  final String fieldKey;
  final String label;
  final String addLabel;
  final List<String> initialValue;
  final ValueChanged<List<String>> onChanged;
  final bool required;

  @override
  State<_StringListFields> createState() => _StringListFieldsState();
}

final class _StringListFieldsState extends State<_StringListFields> {
  late final List<({Key key, String text})> _strings;

  @override
  void initState() {
    super.initState();
    _strings = [
      for (final text in widget.initialValue) (key: UniqueKey(), text: text),
    ];
  }

  void _notify() =>
      widget.onChanged([for (final entry in _strings) entry.text]);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(widget.label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 12),
      for (final (index, entry) in _strings.indexed)
        Padding(
          key: entry.key,
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('条目数组_${widget.fieldKey}_$index'),
                  initialValue: entry.text,
                  minLines: 1,
                  maxLines: 5,
                  decoration: InputDecoration(
                    labelText: '${widget.label} ${index + 1}',
                    errorMaxLines: 3,
                  ),
                  validator: widget.required
                      ? (text) => text == null || text.trim().isEmpty
                            ? '请填写技能，或删除这一项'
                            : null
                      : null,
                  onChanged: (text) {
                    _strings[index] = (key: entry.key, text: text);
                    _notify();
                  },
                ),
              ),
              PopupMenuButton<_EntryAction>(
                key: ValueKey('条目数组操作_${widget.fieldKey}_$index'),
                tooltip: '${widget.label} ${index + 1} 的操作',
                onSelected: (action) {
                  setState(() {
                    if (action == _EntryAction.delete) {
                      _strings.removeAt(index);
                    } else {
                      final destination = action == _EntryAction.up
                          ? index - 1
                          : index + 1;
                      _strings.insert(destination, _strings.removeAt(index));
                    }
                  });
                  _notify();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _EntryAction.up,
                    enabled: index > 0,
                    child: const Text('上移'),
                  ),
                  PopupMenuItem(
                    value: _EntryAction.down,
                    enabled: index + 1 < _strings.length,
                    child: const Text('下移'),
                  ),
                  const PopupMenuItem(
                    value: _EntryAction.delete,
                    child: Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: ValueKey('条目数组添加_${widget.fieldKey}'),
          onPressed: () {
            setState(() => _strings.add((key: UniqueKey(), text: '')));
            _notify();
          },
          icon: const Icon(Icons.add_rounded),
          label: Text(widget.addLabel),
        ),
      ),
    ],
  );
}

const _proficiencyLabels = {
  'native': '母语',
  'fluent': '流利',
  'professional': '专业工作水平',
  'intermediate': '中等',
  'basic': '基础',
  'unspecified': '暂不填写',
};

String _entryTitle(String sectionKey, JsonMap entry) {
  final field = switch (sectionKey) {
    'links' => 'label',
    'workExperiences' => 'organization',
    'educations' => 'institution',
    'customSections' || 'items' => 'title',
    _ => 'name',
  };
  final title = entry[field] as String? ?? '';
  return title.isEmpty ? '未命名${_collectionLabels[sectionKey]}' : title;
}

String _entrySubtitle(String sectionKey, JsonMap entry) => switch (sectionKey) {
  'links' => entry['url'] as String? ?? '',
  'workExperiences' => entry['position'] as String? ?? '',
  'educations' => [
    entry['degree'],
    entry['fieldOfStudy'],
  ].whereType<String>().where((text) => text.isNotEmpty).join(' · '),
  'projects' => entry['role'] as String? ?? '',
  'skillGroups' => (entry['skills']! as List).join(' · '),
  'certifications' => entry['issuer'] as String? ?? '',
  'languages' => _proficiencyLabels[entry['proficiency']] ?? '',
  'customSections' => '${(entry['items']! as List).length} 项内容',
  'items' => entry['description'] as String? ?? '',
  _ => '',
};

final _random = Random.secure();

String _newId() =>
    'entry_${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

JsonMap _emptyDateRange() => {
  'start': <String, Object?>{'year': '', 'month': null},
  'end': null,
  'isCurrent': false,
};

JsonMap _newEntry(String sectionKey) => {
  'id': _newId(),
  ...switch (sectionKey) {
    'links' => {'label': '', 'url': ''},
    'workExperiences' => {
      'organization': '',
      'position': '',
      'dateRange': _emptyDateRange(),
      'summary': '',
      'highlights': <String>[],
    },
    'educations' => {
      'institution': '',
      'degree': '',
      'fieldOfStudy': '',
      'dateRange': _emptyDateRange(),
      'highlights': <String>[],
    },
    'projects' => {
      'name': '',
      'role': '',
      'dateRange': null,
      'summary': '',
      'highlights': <String>[],
      'links': <JsonMap>[],
    },
    'skillGroups' => {'name': '', 'skills': <String>[]},
    'certifications' => {
      'name': '',
      'issuer': '',
      'issuedOn': null,
      'expiresOn': null,
      'credentialId': '',
      'credentialUrl': '',
    },
    'languages' => {'name': '', 'proficiency': 'unspecified'},
    'customSections' => {'title': '', 'items': <JsonMap>[]},
    'items' => {'title': '', 'description': ''},
    _ => throw ArgumentError.value(sectionKey, 'sectionKey'),
  },
};

// 领域校验器接收整份 ResumeData；这里包裹单条草稿仅用于提前反馈。
// 它不能发现与其他区段重复的 ID，整份简历保存仍必须再次校验。
ResumeData _resumeForEntryValidation(String sectionKey, JsonMap entry) {
  final canonicalJson = ResumeData(
    profile: ResumeProfile(
      id: _newId(),
      fullName: '',
      headline: '',
      email: '',
      phone: '',
      location: '',
    ),
  ).toJson();
  if (sectionKey == 'links') {
    (canonicalJson['profile']! as JsonMap)['links'] = [entry];
  } else if (sectionKey == 'items') {
    canonicalJson['customSections'] = [
      {
        'id': _newId(),
        'title': '区段',
        'items': [entry],
      },
    ];
  } else {
    canonicalJson[sectionKey] = [entry];
  }
  return ResumeData.fromJson(canonicalJson);
}
