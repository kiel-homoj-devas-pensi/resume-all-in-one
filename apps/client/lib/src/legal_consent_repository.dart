import 'dart:convert';
import 'dart:io';

import 'legal_documents.dart';

abstract interface class LegalConsentRepository {
  Future<List<LegalConsentEntry>> load();
  Future<void> append(LegalConsentEntry entry);
  Future<void> clear();
}

/// Device-local decisions are never imported from a resume archive or account.
/// Each append writes a new generation; a crash cannot replace an old receipt.
final class FileLegalConsentRepository implements LegalConsentRepository {
  FileLegalConsentRepository({
    required Future<Directory> Function() rootDirectory,
  }) : _root = rootDirectory;
  final Future<Directory> Function() _root;
  static const _maximumEntries = 256;
  static const _maximumEntryBytes = 262144;
  static const _maximumTotalBytes = 8388608;

  Future<Directory> _directory() async => Directory(
    '${(await _root()).path}${Platform.pathSeparator}legal_consent_v1',
  );

  @override
  Future<List<LegalConsentEntry>> load() async {
    final directory = await _directory();
    if (!await directory.exists()) return [];
    final files = <File>[];
    var totalBytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || entity.path.endsWith('.pending')) {
        throw const FormatException('协议记录写入未完成或目录无效');
      }
      if (!RegExp(r'decision-\d{6}\.json$').hasMatch(entity.path)) {
        throw const FormatException('协议记录名称无效');
      }
      final length = await entity.length();
      if (length > _maximumEntryBytes) throw const FormatException('协议记录超限');
      totalBytes += length;
      files.add(entity);
    }
    if (files.length > _maximumEntries || totalBytes > _maximumTotalBytes) {
      throw const FormatException('协议记录总量超限');
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final entries = <LegalConsentEntry>[];
    for (final file in files) {
      final entry = LegalConsentEntry.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
      final expected = entries.length + 1;
      if (entry.record.sequence != expected ||
          !file.path.endsWith(
            'decision-${expected.toString().padLeft(6, '0')}.json',
          )) {
        throw const FormatException('协议记录序列不连续');
      }
      entries.add(entry);
    }
    return List.unmodifiable(entries);
  }

  @override
  Future<void> append(LegalConsentEntry entry) async {
    final entries = await load();
    if (entries.length >= _maximumEntries ||
        entry.record.sequence != entries.length + 1) {
      throw const FormatException('协议记录已满或发生冲突');
    }
    final bytes = utf8.encode(jsonEncode(entry.toJson()));
    if (bytes.length > _maximumEntryBytes) {
      throw const FormatException('协议记录超限');
    }
    var totalBytes = bytes.length;
    for (final item in entries) {
      totalBytes += utf8.encode(jsonEncode(item.toJson())).length;
    }
    if (totalBytes > _maximumTotalBytes) {
      throw const FormatException('协议记录总量超限');
    }
    final directory = await _directory();
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}decision-${entry.record.sequence.toString().padLeft(6, '0')}.json',
    );
    if (await file.exists()) throw const FormatException('协议记录不可覆盖');
    final pending = File('${file.path}.pending');
    await pending.writeAsBytes(bytes, flush: true);
    await pending.rename(file.path);
  }

  @override
  Future<void> clear() async {
    final directory = await _directory();
    if (!await directory.exists()) return;
    // Only our dedicated private directory, never its parent or exported files.
    await directory.delete(recursive: true);
  }
}
