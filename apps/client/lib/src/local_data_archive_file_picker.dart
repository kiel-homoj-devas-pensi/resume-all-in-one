import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_data_archive.dart';

final class SelectedLocalDataArchiveFile {
  const SelectedLocalDataArchiveFile({required this.bytes});
  final Uint8List bytes;
}

abstract interface class LocalDataArchiveFilePicker {
  Future<SelectedLocalDataArchiveFile?> pickArchive();
}

final class SystemLocalDataArchiveFilePicker
    implements LocalDataArchiveFilePicker {
  const SystemLocalDataArchiveFilePicker({
    MethodChannel channel = const MethodChannel(
      'resume_all_in_one/archive_import',
    ),
    Future<XFile?> Function({required List<XTypeGroup> acceptedTypeGroups})?
    pickFile,
  }) : _channel = channel,
       _pickFile = pickFile;

  final MethodChannel _channel;
  final Future<XFile?> Function({required List<XTypeGroup> acceptedTypeGroups})?
  _pickFile;

  @override
  Future<SelectedLocalDataArchiveFile?> pickArchive() async {
    if (_pickFile == null &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      try {
        final result = await _channel.invokeMapMethod<String, Object?>(
          'pickLocalDataArchiveFile',
        );
        if (result == null) return null;
        final name = result['fileName'];
        final bytes = result['bytes'];
        if (name is! String ||
            !name.toLowerCase().endsWith('.json') ||
            bytes is! Uint8List) {
          throw const FormatException('档案选择返回值无效');
        }
        _checkLength(bytes.length);
        return SelectedLocalDataArchiveFile(bytes: bytes);
      } on PlatformException catch (error) {
        if (error.code == 'input_too_large') {
          throw const FormatException('本地数据档案不能超过 8 MiB');
        }
        if (error.code == 'unsupported_file_type') {
          throw const FormatException('请选择应用导出的 JSON 档案');
        }
        rethrow;
      }
    }
    final file = await (_pickFile ?? openFile)(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '本地数据 JSON 档案',
          extensions: ['json'],
          mimeTypes: ['application/json'],
          uniformTypeIdentifiers: ['public.json'],
        ),
      ],
    );
    if (file == null) return null;
    if (!file.name.toLowerCase().endsWith('.json')) {
      throw const FormatException('请选择应用导出的 JSON 档案');
    }
    _checkLength(await file.length());
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      _checkLength(bytes.length + chunk.length);
      bytes.add(chunk);
    }
    return SelectedLocalDataArchiveFile(bytes: bytes.takeBytes());
  }

  static void _checkLength(int length) {
    if (length > localDataArchiveMaxBytes) {
      throw const FormatException('本地数据档案不能超过 8 MiB');
    }
  }
}
