import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/local_data_archive.dart';
import 'package:resume_domain/resume_domain.dart';

final _createdAt = DateTime.utc(2026, 10, 14, 8);

void main() {
  test('真实磁盘重开保留照片更换、移除和旧历史，档案恢复到独立文件库逐字段一致', () async {
    final directory = await Directory.systemTemp.createTemp(
      'resume-photo-persistence-',
    );
    final sourceFile = File('${directory.path}/source.sqlite');
    final restoredFile = File('${directory.path}/restored.sqlite');
    final photoA = _photo(
      '../../packages/resume_domain/test/fixtures/photo.jpg',
      'A',
    );
    final photoB = _photo(
      '../../packages/document_io/test/fixtures/resume-photo-500x700.jpg',
      'B',
    );
    expect(photoA.dataBase64, isNot(photoB.dataBase64));
    LocalStorageDatabase? database;
    LocalStorageDatabase? target;
    try {
      database = LocalStorageDatabase.openFile(sourceFile);
      var repository = DriftResumeRepository(database);
      final first = _version(0, null);
      await repository.createDocument(_document(first), first);
      expect(
        (first.content.toJson()['profile'] as JsonMap).containsKey('photo'),
        isFalse,
      );

      final withA = _version(1, photoA);
      await _append(repository, withA);
      await database.close();
      database = null;
      database = LocalStorageDatabase.openFile(sourceFile);
      repository = DriftResumeRepository(database);
      expect(
        (await repository.findCurrentVersion(
          first.documentId,
        ))!.content.profile.photo!.toJson(),
        photoA.toJson(),
      );
      expect(
        (await repository.findVersion(first.id))!.content.profile.photo,
        isNull,
      );

      final withB = _version(2, photoB);
      await _append(repository, withB);
      await database.close();
      database = null;
      database = LocalStorageDatabase.openFile(sourceFile);
      repository = DriftResumeRepository(database);
      expect(
        (await repository.findCurrentVersion(
          first.documentId,
        ))!.content.profile.photo!.bytes,
        photoB.bytes,
      );
      expect(
        (await repository.findVersion(
          withA.id,
        ))!.content.profile.photo!.toJson(),
        photoA.toJson(),
      );

      final removed = _version(3, null);
      await _append(repository, removed);
      await database.close();
      database = null;
      database = LocalStorageDatabase.openFile(sourceFile);
      repository = DriftResumeRepository(database);
      final history = await repository.listVersions(first.documentId);
      expect(history.map((v) => v.id), [
        removed.id,
        withB.id,
        withA.id,
        first.id,
      ]);
      expect(
        (await repository.findCurrentVersion(
          first.documentId,
        ))!.content.profile.photo,
        isNull,
      );
      expect(
        (await repository.findVersion(withA.id))!.content.profile.photo!.bytes,
        photoA.bytes,
      );
      expect(
        (await repository.findVersion(withB.id))!.content.profile.photo!.bytes,
        photoB.bytes,
      );

      final snapshot = await DriftLocalDataRepository(
        database,
      ).readExportSnapshot();
      const codec = LocalDataArchiveCodec();
      final archiveText = codec.encode(
        snapshot,
        _createdAt.add(const Duration(hours: 1)),
      );
      final archive = codec.parse(archiveText);
      expect(archive.summary.documentCount, 1);
      expect(archive.summary.versionCount, 4);
      expect(
        archive.resumes.single.document.toJson(),
        snapshot.resumes.single.document.toJson(),
      );
      expect(
        archive.resumes.single.versions.map((v) => v.toJson()),
        history.map((v) => v.toJson()),
      );

      target = LocalStorageDatabase.openFile(restoredFile);
      await DriftLocalDataRepository(target).restoreResumes(archive.resumes);
      await target.close();
      target = null;
      target = LocalStorageDatabase.openFile(restoredFile);
      final restoredRepository = DriftResumeRepository(target);
      final restoredHistory = await restoredRepository.listVersions(
        first.documentId,
      );
      expect(
        restoredHistory.map((v) => v.toJson()),
        history.map((v) => v.toJson()),
      );
      expect(
        (await restoredRepository.findDocument(
          first.documentId,
        ))!.currentVersionId,
        removed.id,
      );
      expect(
        (await restoredRepository.findCurrentVersion(
          first.documentId,
        ))!.content.profile.photo,
        isNull,
      );
      expect(
        (await restoredRepository.findVersion(
          withA.id,
        ))!.content.profile.photo!.toJson(),
        photoA.toJson(),
      );
      expect(
        (await restoredRepository.findVersion(
          withB.id,
        ))!.content.profile.photo!.toJson(),
        photoB.toJson(),
      );
      expect(
        await target.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
      expect(sourceFile.lengthSync(), greaterThan(0));
      expect(restoredFile.lengthSync(), greaterThan(0));
    } finally {
      await database?.close();
      await target?.close();
      await directory.delete(recursive: true);
    }
  });
}

ResumePhoto _photo(String path, String marker) => ResumePhoto(
  dataBase64: base64Encode(File(path).readAsBytesSync()),
  mimeType: 'image/jpeg',
  width: 500,
  height: 700,
  extensions: {
    'futurePhotoField': {'marker': marker, 'preserved': true},
  },
);

ResumeVersion _version(int number, ResumePhoto? photo) => ResumeVersion(
  id: 'photo-disk-version-$number',
  documentId: 'photo-disk-document',
  parentVersionId: number == 0 ? null : 'photo-disk-version-${number - 1}',
  schemaVersion: currentResumeSchemaVersion,
  content: ResumeData(
    profile: ResumeProfile(
      id: 'photo-disk-profile',
      fullName: '合成持久化用户',
      headline: '',
      email: 'synthetic@example.com',
      phone: '13800000000',
      location: '合成所在地',
      photo: photo,
      extensions: {
        'futureProfileField': ['保持'],
      },
    ),
    extensions: {'futureRootField': true},
  ),
  source: number == 0
      ? ResumeVersionSource.created
      : ResumeVersionSource.edited,
  createdAt: _createdAt.add(Duration(minutes: number)),
  extensions: {'futureVersionField': number},
);

ResumeDocument _document(ResumeVersion version) => ResumeDocument(
  id: version.documentId,
  title: '仅用于管理的合成标题',
  currentVersionId: version.id,
  createdAt: _createdAt,
  updatedAt: version.createdAt,
  metadata: {'synthetic': true},
  extensions: {'futureDocumentField': '保持'},
);

Future<void> _append(DriftResumeRepository repository, ResumeVersion version) =>
    repository.saveVersion(
      document: _document(version),
      version: version,
      expectedCurrentVersionId: version.parentVersionId!,
    );
