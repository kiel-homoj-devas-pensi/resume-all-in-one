import 'package:flutter/material.dart';
import 'package:resume_domain/resume_domain.dart';

import 'resume_collection_editor.dart';
import 'resume_photo_picker.dart';

/// The same profile controls serve manual editing and AI creation. None upload data.
final class ResumeProfileFields extends StatelessWidget {
  const ResumeProfileFields({
    super.key,
    required this.title,
    required this.fullName,
    required this.headline,
    required this.email,
    required this.phone,
    required this.location,
    required this.links,
    required this.photo,
    required this.onPhotoChanged,
    this.onPhotoBusyChanged,
    this.enabled = true,
    this.titleError,
    this.emailError,
    this.photoPicker = const SystemResumePhotoPicker(),
  });

  final TextEditingController title, fullName, headline, email, phone, location;
  final TextEditingController links;
  final ResumePhoto? photo;
  final ValueChanged<ResumePhoto?> onPhotoChanged;
  final ValueChanged<bool>? onPhotoBusyChanged;
  final bool enabled;
  final String? titleError, emailError;
  final ResumePhotoPicker photoPicker;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        key: const Key('简历标题输入框'),
        controller: title,
        enabled: enabled,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: '简历标题',
          hintText: '例如：产品设计师 · 校招',
          helperText: '简历标题仅用于区分不同简历，不会显示在导出的简历中。',
          helperMaxLines: 2,
          errorText: titleError,
        ),
      ),
      const SizedBox(height: 12),
      _field('姓名', fullName),
      const SizedBox(height: 12),
      _field('意向职业岗位（选填）', headline, keyName: '意向职业岗位输入框'),
      const SizedBox(height: 12),
      _field(
        '邮箱',
        email,
        keyboard: TextInputType.emailAddress,
        error: emailError,
      ),
      const SizedBox(height: 12),
      _field('电话', phone, keyboard: TextInputType.phone),
      const SizedBox(height: 12),
      _field('所在地', location),
      const SizedBox(height: 12),
      _ProfilePhotoField(
        photo: photo,
        enabled: enabled,
        picker: photoPicker,
        onChanged: onPhotoChanged,
        onBusyChanged: onPhotoBusyChanged,
      ),
      const SizedBox(height: 12),
      ExpansionTile(
        key: const Key('展开区段_个人链接'),
        maintainState: true,
        title: const Text('个人链接（选填）'),
        children: [
          ResumeCollectionEditor(
            key: const Key('个人链接结构化输入'),
            sectionKey: 'links',
            controller: links,
            enabled: enabled,
          ),
        ],
      ),
    ],
  );

  Widget _field(
    String label,
    TextEditingController controller, {
    String? keyName,
    TextInputType keyboard = TextInputType.text,
    String? error,
  }) => TextField(
    key: Key(keyName ?? '$label输入框'),
    controller: controller,
    enabled: enabled,
    keyboardType: keyboard,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(labelText: label, errorText: error),
  );
}

final class _ProfilePhotoField extends StatefulWidget {
  const _ProfilePhotoField({
    required this.photo,
    required this.enabled,
    required this.picker,
    required this.onChanged,
    this.onBusyChanged,
  });
  final ResumePhoto? photo;
  final bool enabled;
  final ResumePhotoPicker picker;
  final ValueChanged<ResumePhoto?> onChanged;
  final ValueChanged<bool>? onBusyChanged;
  @override
  State<_ProfilePhotoField> createState() => _ProfilePhotoFieldState();
}

final class _ProfilePhotoFieldState extends State<_ProfilePhotoField> {
  bool _busy = false;
  String? _error;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('证件照（选填）'),
      const SizedBox(height: 8),
      const Text('JPG 或 PNG，最大 10MB。首页右上角一寸（25×35mm），完整等比显示，不自动裁剪或拉伸。'),
      if (widget.photo case final photo?)
        Container(
          key: const Key('已选证件照'),
          width: 100,
          height: 140,
          color: Colors.white,
          child: Image.memory(
            photo.bytes,
            fit: BoxFit.contain,
            semanticLabel: '当前证件照完整预览',
          ),
        ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      Wrap(
        spacing: 12,
        children: [
          OutlinedButton.icon(
            key: const Key('选择证件照'),
            onPressed: widget.enabled && !_busy ? _pick : null,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
              _busy
                  ? '正在读取照片…'
                  : widget.photo == null
                  ? '选择照片'
                  : '更换照片',
            ),
          ),
          if (widget.photo != null)
            TextButton(
              key: const Key('移除证件照'),
              onPressed: widget.enabled && !_busy
                  ? () {
                      setState(() => _error = null);
                      widget.onChanged(null);
                    }
                  : null,
              child: const Text('移除照片'),
            ),
        ],
      ),
    ],
  );

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      final photo = await widget.picker.pickPhoto();
      if (!mounted || photo == null) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('确认照片'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 150,
                height: 210,
                color: Colors.white,
                child: Image.memory(
                  photo.bytes,
                  fit: BoxFit.contain,
                  semanticLabel: '待确认照片完整预览',
                ),
              ),
              const SizedBox(height: 12),
              const Text('请确认人像完整。打印时固定为一寸，比例不合时留白；保存简历后生效。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('确认使用证件照'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('使用照片'),
            ),
          ],
        ),
      );
      if (mounted && confirmed == true) widget.onChanged(photo);
    } on ResumePhotoException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }
}
