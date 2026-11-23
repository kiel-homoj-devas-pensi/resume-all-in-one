import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:document_io/document_io.dart';
import 'package:flutter/services.dart';
import 'package:resume_domain/resume_domain.dart';

final class SavedResumeWord {
  const SavedResumeWord({required this.path, required this.content});
  final String path;
  final ResumeWordDocument content;
}

/// Word 是交付副本；文件修订不会写回 Canonical 或覆盖旧文稿。
final class ResumeWordStore {
  ResumeWordStore({
    required Future<Directory> Function() rootDirectory,
    Future<ByteData> Function(String)? fontLoader,
  }) : _rootDirectory = rootDirectory,
       _fontLoader = fontLoader ?? rootBundle.load;

  final Future<Directory> Function() _rootDirectory;
  final Future<ByteData> Function(String) _fontLoader;
  static const _codec = ResumeDocxCodec();

  Future<Directory> _directory() async {
    final root = await _rootDirectory();
    return Directory(
      '${root.path}${Platform.pathSeparator}resume_exports',
    ).create(recursive: true);
  }

  String _prefix(ResumeVersion version) =>
      'ResumeWord_${sha256.convert(utf8.encode(jsonEncode([version.documentId, version.id])))}_';

  Future<SavedResumeWord> open(ResumeVersion version) async {
    final directory = await _directory();
    final prefix =
        '${directory.path}${Platform.pathSeparator}${_prefix(version)}';
    final candidates = <File>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          entry.path.startsWith(prefix) &&
          entry.path.endsWith('.docx')) {
        candidates.add(entry);
      }
    }
    // 名称含保存时间；只打开当前不可变版本的最新副本，不重新覆盖用户改好的文字。
    candidates.sort((left, right) => right.path.compareTo(left.path));
    if (candidates.isNotEmpty) {
      final bytes = await _readWord(candidates.first.path);
      final decoded = _codec.decode(bytes);
      final provenance = ResumeAiProvenance.fromResume(version.content);
      final metadata = ResumeAigcMetadata.fromResume(version.content);
      _requireMatchingMetadata(metadata, decoded.aigcMetadata);
      if ((provenance != null && decoded.aiProvenance == null) ||
          (metadata != null && decoded.aigcMetadata == null)) {
        // Upgrade only this delivery copy; preserve all previously edited text.
        return save(
          version,
          ResumeWordDocument(
            paragraphs: decoded.paragraphs,
            photo: decoded.photo,
            aiProvenance: decoded.aiProvenance ?? provenance,
            aigcMetadata: decoded.aigcMetadata ?? metadata,
          ),
        );
      }
      return SavedResumeWord(path: candidates.first.path, content: decoded);
    }
    return save(version, _codec.fromResume(version.content));
  }

  Future<SavedResumeWord> save(
    ResumeVersion version,
    ResumeWordDocument content,
  ) async {
    // 校验与回读在创建文件前完成；超限/结构错误不会留下半份文稿。
    final provenance = ResumeAiProvenance.fromResume(version.content);
    final metadata = ResumeAigcMetadata.fromResume(version.content);
    _requireMatchingMetadata(metadata, content.aigcMetadata);
    final encodedDocxBytes = _codec.encode(
      ResumeWordDocument(
        paragraphs: content.paragraphs,
        photo: content.photo,
        aiProvenance: content.aiProvenance ?? provenance,
        aigcMetadata: content.aigcMetadata ?? metadata,
      ),
    );
    final verifiedWordContent = _codec.decode(encodedDocxBytes);
    final directory = await _directory();
    final nonce = List.generate(
      8,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final newRevisionFile = File(
      '${directory.path}${Platform.pathSeparator}${_prefix(version)}${DateTime.now().toUtc().microsecondsSinceEpoch}_$nonce.docx',
    );
    await _writeNewFile(newRevisionFile, encodedDocxBytes);
    return SavedResumeWord(
      path: newRevisionFile.path,
      content: verifiedWordContent,
    );
  }

  Future<Uint8List> convertToPdf(SavedResumeWord word) async {
    // 转换源是磁盘上的 DOCX 正文，不使用内存草稿或原简历替代。
    final savedDocxBytes = await _readWord(word.path);
    final regularFontData = await _fontLoader(
      'packages/document_io/assets/fonts/NotoSansSC-Regular.ttf',
    );
    final boldFontData = await _fontLoader(
      'packages/document_io/assets/fonts/NotoSansSC-Bold.ttf',
    );
    return const ResumeDocxPdfConverter().convert(
      savedDocxBytes,
      fonts: ResumePdfFonts(regular: regularFontData, bold: boldFontData),
    );
  }

  Future<File> savePdf(String wordPath, Uint8List bytes) async {
    await _validateWordPath(wordPath);
    // PDF 跟随具体 Word 修订，不覆盖别的 Word 修订或旧 Canonical 导出。
    final target = File('${wordPath.substring(0, wordPath.length - 5)}.pdf');
    if (await target.exists()) {
      final suffix = DateTime.now().toUtc().microsecondsSinceEpoch;
      final copy = File(
        '${wordPath.substring(0, wordPath.length - 5)}_$suffix.pdf',
      );
      await _writeNewFile(copy, bytes);
      return copy;
    }
    await _writeNewFile(target, bytes);
    return target;
  }

  Future<Uint8List> _readWord(String path) async {
    final file = await _validateWordPath(path);
    if (await file.length() > ResumeDocxCodec.maxFileBytes) {
      throw const FormatException('Word 文稿超过大小限制。');
    }
    return file.readAsBytes();
  }

  Future<File> _validateWordPath(String path) async {
    final directory = await _directory();
    final file = File(path);
    final name = file.uri.pathSegments.last;
    if (!RegExp(
          r'^ResumeWord_[0-9a-f]{64}_[0-9]+_[0-9a-f]{16}\.docx$',
        ).hasMatch(name) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.parent.resolveSymbolicLinks() !=
            await directory.resolveSymbolicLinks()) {
      throw const FormatException('只能处理本应用保存的 Word 文稿。');
    }
    return file;
  }

  Future<void> _writeNewFile(File target, Uint8List bytes) async {
    final pending = File('${target.path}.pending');
    try {
      await pending.writeAsBytes(bytes, flush: true);
      if (await target.exists()) throw const FileSystemException('文稿文件已存在。');
      await pending.rename(target.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  void _requireMatchingMetadata(
    ResumeAigcMetadata? versionMetadata,
    ResumeAigcMetadata? wordMetadata,
  ) {
    if (versionMetadata != null &&
        wordMetadata != null &&
        !jsonDeepEquals(versionMetadata.toJson(), wordMetadata.toJson())) {
      throw const FormatException('Word的AI来源与当前简历版本不一致，请保留原文件。');
    }
  }
}
