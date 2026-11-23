import 'dart:convert';
import 'dart:io';

import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

void main() {
  test('既有有效紧凑时间与分钟精度仍可解析', () {
    for (final text in ['20261011T010000Z', '2026-10-11T01:00Z']) {
      final document = ResumeDocument.fromJson({
        'id': 'synthetic-backward-compatible',
        'title': '有效旧格式',
        'currentVersionId': null,
        'createdAt': text,
        'updatedAt': text,
        'metadata': <String, Object?>{},
      });
      expect(document.createdAt, DateTime.utc(2026, 10, 11, 1));
    }
  });
  final cases =
      jsonDecode(
            File(
              'test/fixtures/cloud_timestamp_cases_v0_1.json',
            ).readAsStringSync(),
          )!
          as List<Object?>;
  for (final value in cases) {
    final scenario = value! as Map<String, Object?>;
    test('文档时间共同用例 ${scenario['name']}', () {
      final source = <String, Object?>{
        'id': 'synthetic-document',
        'title': '原始时间',
        'currentVersionId': 'synthetic-version',
        'createdAt': scenario['value'],
        'updatedAt': scenario['value'],
        'metadata': <String, Object?>{},
      };
      if (scenario['accepted'] == true) {
        final document = ResumeDocument.fromJson(source);
        expect(
          document.createdAt,
          DateTime.parse(scenario['value']! as String),
        );
      } else {
        expect(
          () => ResumeDocument.fromJson(source),
          throwsA(isA<SchemaFormatException>()),
        );
      }
    });
  }
}
