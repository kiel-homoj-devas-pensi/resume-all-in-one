import 'dart:io';

import 'package:flutter/services.dart';

enum ResumeFileDeliveryAction { saveAs, share }

enum ResumeFileDeliveryOutcome { saved, cancelled, shareOpened }

/// 平台边界只交付已保存文件；不会生成正文或修改 Canonical。
final class ResumeFileDelivery {
  const ResumeFileDelivery({
    MethodChannel channel = const MethodChannel(
      'resume_all_in_one/file_delivery',
    ),
  }) : _channel = channel;
  final MethodChannel _channel;

  Future<bool> consumeInterruptedSave() async {
    if (!Platform.isAndroid) return false;
    try {
      final value = await _channel.invokeMethod<bool>('consumeInterruptedSave');
      if (value == null) throw const FormatException('文件中断状态无效');
      return value;
    } on MissingPluginException {
      if (Platform.isAndroid) rethrow;
      return false;
    }
  }

  Future<ResumeFileDeliveryOutcome> deliver(
    String path,
    ResumeFileDeliveryAction action,
  ) async {
    final extension = path.toLowerCase().split('.').last;
    final mimeType = switch (extension) {
      'pdf' => 'application/pdf',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'json' => 'application/json',
      'md' => 'text/markdown',
      _ => throw const FormatException('不支持的文件交付类型'),
    };
    final parts = path.replaceAll('\\', '/').split('/');
    final isArchive =
        parts.length >= 2 && parts[parts.length - 2] == 'local_data_exports';
    final value = await _channel.invokeMethod<String>(action.name, {
      'path': path,
      'fileName': isArchive ? 'local-data.json' : 'resume.$extension',
      'mimeType': mimeType,
    });
    return switch (value) {
      'saved' => ResumeFileDeliveryOutcome.saved,
      'cancelled' => ResumeFileDeliveryOutcome.cancelled,
      'shareOpened' => ResumeFileDeliveryOutcome.shareOpened,
      _ => throw const FormatException('文件交付返回值无效'),
    };
  }
}
