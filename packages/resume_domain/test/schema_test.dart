import 'dart:convert';
import 'dart:io';

import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

String _fixtureSource() =>
    File('test/fixtures/resume_v0_1.json').readAsStringSync();

Map<String, Object?> _fixtureJson() =>
    jsonDecode(_fixtureSource())! as Map<String, Object?>;

void main() {
  group('Canonical Resume Schema v0.1', () {
    test('fixture 可以完整 round-trip 且保留未知字段', () {
      const codec = CanonicalResumeCodec();
      final decoded = codec.decode(_fixtureSource());
      final encoded =
          jsonDecode(codec.encode(decoded))! as Map<String, Object?>;
      final original = _fixtureJson();

      expect(jsonDeepEquals(encoded, original), isTrue);
      expect(encoded['futureRootField'], ['必须', '保留']);
      final profile = encoded['profile']! as Map<String, Object?>;
      expect(profile['futureProfileField'], {'enabled': true});
    });

    test('实体集合和未知 JSON 值不可从外部修改', () {
      final mutableSkills = ['Dart'];
      final mutableExtension = <String, Object?>{
        'nested': <String, Object?>{'value': 1},
      };
      final resume = ResumeData(
        profile: ResumeProfile(
          id: 'profile-immutable',
          fullName: '',
          headline: '',
          email: '',
          phone: '',
          location: '',
        ),
        skillGroups: [
          SkillGroup(
            id: 'skills-immutable',
            name: '技能',
            skills: mutableSkills,
            extensions: mutableExtension,
          ),
        ],
      );

      mutableSkills.add('Flutter');
      (mutableExtension['nested']! as Map<String, Object?>)['value'] = 2;

      expect(resume.skillGroups.single.skills, ['Dart']);
      expect(resume.skillGroups.single.extensions['nested'], {'value': 1});
      expect(
        () => resume.skillGroups.add(SkillGroup(id: 'new', name: 'new')),
        throwsUnsupportedError,
      );
    });

    test('非法月份在解析阶段被拒绝', () {
      final json = _fixtureJson();
      final work =
          (json['workExperiences']! as List<Object?>).single
              as Map<String, Object?>;
      final range = work['dateRange']! as Map<String, Object?>;
      final start = range['start']! as Map<String, Object?>;
      start['month'] = 13;

      expect(
        () => ResumeData.fromJson(json),
        throwsA(isA<SchemaFormatException>()),
      );
    });

    test('结束日期早于开始日期时被拒绝', () {
      final json = _fixtureJson();
      final work =
          (json['workExperiences']! as List<Object?>).single
              as Map<String, Object?>;
      final range = work['dateRange']! as Map<String, Object?>;
      range['isCurrent'] = false;
      range['end'] = <String, Object?>{'year': 2020, 'month': 1};

      expect(
        () => ResumeData.fromJson(json),
        throwsA(isA<SchemaFormatException>()),
      );
    });

    test('未知枚举值不会被静默降级', () {
      final json = _fixtureJson();
      final language =
          (json['languages']! as List<Object?>).single as Map<String, Object?>;
      language['proficiency'] = 'expert';

      expect(
        () => ResumeData.fromJson(json),
        throwsA(isA<SchemaFormatException>()),
      );
    });

    test('非法 URL 由 codec 校验并阻止提交', () {
      final json = _fixtureJson();
      final profile = json['profile']! as Map<String, Object?>;
      final link =
          (profile['links']! as List<Object?>).single as Map<String, Object?>;
      link['url'] = 'github.com/example';

      expect(
        () => const CanonicalResumeCodec().decode(jsonEncode(json)),
        throwsA(
          isA<ResumeValidationException>().having(
            (error) => error.result.issues
                .where((issue) => issue.blocksCommit)
                .single
                .ruleId,
            'ruleId',
            'url.http_absolute',
          ),
        ),
      );
    });

    test('重复稳定 ID 被阻止', () {
      final json = _fixtureJson();
      final skill =
          (json['skillGroups']! as List<Object?>).single
              as Map<String, Object?>;
      skill['id'] = 'work-001';

      expect(
        () => const CanonicalResumeCodec().decode(jsonEncode(json)),
        throwsA(isA<ResumeValidationException>()),
      );
    });

    test('首版迁移为保真 no-op，并拒绝未知版本', () {
      const migrator = ResumeSchemaMigrator();
      final original = _fixtureJson();
      final migrated = migrator.migrate(original);

      expect(jsonDeepEquals(migrated, original), isTrue);
      expect(() => migrated['new'] = true, throwsUnsupportedError);

      final old = _fixtureJson()..['schemaVersion'] = '0.0.1';
      expect(
        () => migrator.migrate(old),
        throwsA(isA<UnsupportedSchemaVersionException>()),
      );

      final future = _fixtureJson()..['schemaVersion'] = '1.0.0';
      expect(
        () => migrator.migrate(future),
        throwsA(isA<UnsupportedSchemaVersionException>()),
      );

      final missing = _fixtureJson()..remove('schemaVersion');
      expect(
        () => migrator.migrate(missing),
        throwsA(isA<UnsupportedSchemaVersionException>()),
      );
    });

    test('ResumeVersion 校验 Schema 版本一致性并保留快照', () {
      final content = const CanonicalResumeCodec().decode(_fixtureSource());
      final version = ResumeVersion(
        id: 'version-001',
        documentId: 'document-001',
        parentVersionId: null,
        schemaVersion: currentResumeSchemaVersion,
        content: content,
        source: ResumeVersionSource.created,
        createdAt: DateTime.utc(2026, 9, 29),
      );

      final roundTrip = ResumeVersion.fromJson(version.toJson());
      expect(jsonDeepEquals(roundTrip.toJson(), version.toJson()), isTrue);
      expect(
        () => ResumeVersion(
          id: 'version-invalid',
          documentId: 'document-001',
          parentVersionId: null,
          schemaVersion: '1.0.0',
          content: content,
          source: ResumeVersionSource.edited,
          createdAt: DateTime.utc(2026, 9, 29),
        ),
        throwsA(isA<SchemaFormatException>()),
      );
    });

    test('ResumeDocument 要求带时区时间并保留 metadata', () {
      final document = ResumeDocument.fromJson({
        'id': 'document-001',
        'title': '主简历',
        'currentVersionId': 'version-001',
        'createdAt': '2026-09-29T12:00:00Z',
        'updatedAt': '2026-09-29T12:30:00+00:00',
        'metadata': {
          'tags': ['中文', '移动端'],
        },
        'futureDocumentField': true,
      });

      expect(document.metadata['tags'], ['中文', '移动端']);
      expect(document.toJson()['futureDocumentField'], isTrue);
      expect(
        () => ResumeDocument.fromJson({
          'id': 'document-invalid',
          'title': '无效时间',
          'currentVersionId': null,
          'createdAt': '2026-09-29T12:00:00',
          'updatedAt': '2026-09-29T12:30:00Z',
          'metadata': <String, Object?>{},
        }),
        throwsA(isA<SchemaFormatException>()),
      );
    });
  });
}
