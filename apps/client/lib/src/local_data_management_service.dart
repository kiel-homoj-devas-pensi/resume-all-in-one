import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:local_storage/local_storage.dart';

import 'local_data_archive.dart';
import 'local_data_archive_file_picker.dart';

export 'local_data_archive.dart';

final class LocalDataExportResult {
  const LocalDataExportResult({required this.file, required this.summary});

  final File file;
  final LocalDataArchiveSummary summary;
}

final class LocalDataManagementService {
  LocalDataManagementService({
    required LocalDataRepository repository,
    required Future<Directory> Function() rootDirectory,
    DateTime Function()? clock,
    this.codec = const LocalDataArchiveCodec(),
    LocalDataArchiveFilePicker archiveFilePicker =
        const SystemLocalDataArchiveFilePicker(),
  }) : _repository = repository,
       _archiveFilePicker = archiveFilePicker,
       _rootDirectory = rootDirectory,
       _clock = clock ?? _utcNow;

  final LocalDataRepository _repository;
  final Future<Directory> Function() _rootDirectory;
  final DateTime Function() _clock;
  final LocalDataArchiveCodec codec;
  final LocalDataArchiveFilePicker _archiveFilePicker;

  Future<LocalDataArchive?> prepareRestore() async {
    final selected = await _archiveFilePicker.pickArchive();
    if (selected == null) return null;
    if (selected.bytes.length > localDataArchiveMaxBytes) {
      throw const LocalDataArchiveException('本地数据档案不能超过 8 MiB');
    }
    // 解析和逐版校验不占用界面线程；结果只含已校验的领域对象。
    return _parseArchiveInWorker(selected.bytes);
  }

  Future<void> restoreResumes(LocalDataArchive archive) =>
      _repository.restoreResumes(archive.resumes);

  Future<LocalDataExportResult> exportAll() async {
    final localDataSnapshot = await _repository.readExportSnapshot();
    final exportedAtUtc = _clock().toUtc();
    final encoded = await _encodeArchiveInWorker(
      codec,
      localDataSnapshot,
      exportedAtUtc,
    );
    final archiveText = encoded.text;
    final archiveSummary = encoded.summary;
    final applicationDocumentsDirectory = await _rootDirectory();
    final exportDirectory = Directory(
      '${applicationDocumentsDirectory.path}'
      '${Platform.pathSeparator}local_data_exports',
    );
    await exportDirectory.create(recursive: true);
    final exportedFile = await _nextExportFile(exportDirectory, exportedAtUtc);
    final temporaryFile = File('${exportedFile.path}.tmp');
    try {
      await temporaryFile.writeAsString(archiveText, flush: true);
      await temporaryFile.rename(exportedFile.path);
    } finally {
      await _deleteTemporaryFileIfPresent(temporaryFile);
    }
    return LocalDataExportResult(file: exportedFile, summary: archiveSummary);
  }

  Future<LocalDataClearResult> clearAll() => _repository.clearAll();

  Future<File> _nextExportFile(
    Directory exportDirectory,
    DateTime exportedAtUtc,
  ) async {
    final timestamp = exportedAtUtc.toIso8601String().replaceAll(
      RegExp('[^0-9]'),
      '',
    );
    for (var sequence = 1; sequence <= 999; sequence++) {
      final candidate = File(
        '${exportDirectory.path}${Platform.pathSeparator}'
        'local_data_${timestamp}_$sequence.json',
      );
      if (!await candidate.exists()) {
        return candidate;
      }
    }
    throw StateError('同一时刻的本地数据导出文件过多');
  }

  Future<void> _deleteTemporaryFileIfPresent(File temporaryFile) async {
    try {
      if (await temporaryFile.exists()) {
        await temporaryFile.delete();
      }
    } on FileSystemException {
      // 目标文件只有 rename 成功后才出现；临时文件清理失败不伪造导出成功。
    }
  }
}

DateTime _utcNow() => DateTime.now().toUtc();

Future<LocalDataArchive> _parseArchiveInWorker(Uint8List bytes) =>
    Isolate.run(() {
      final String text;
      try {
        text = utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        throw const LocalDataArchiveException('档案不是有效的 UTF-8 JSON');
      }
      return const LocalDataArchiveCodec().parse(text);
    });

Future<({String text, LocalDataArchiveSummary summary})> _encodeArchiveInWorker(
  LocalDataArchiveCodec codec,
  LocalDataSnapshot snapshot,
  DateTime exportedAtUtc,
) => Isolate.run(() {
  final text = codec.encode(snapshot, exportedAtUtc);
  // 只在同一 worker 完整校验后交给落盘边界，避免界面线程构建档案树。
  return (text: text, summary: codec.decode(text));
});
