import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/local_data_archive.dart';
import 'package:resume_domain/resume_domain.dart';

final _time = DateTime.utc(2026, 10, 12);
const _codec = LocalDataArchiveCodec();

void main() {
  test('实际UTF8 8MiB通过、多一字节拒绝，非ASCII不按字符计数', () {
    final base = jsonEncode(_emptyArchive({'payload': ''}));
    final atLimit = jsonEncode(
      _emptyArchive({
        'payload': 'X' * (localDataArchiveMaxBytes - base.length),
      }),
    );
    expect(utf8.encode(atLimit).length, localDataArchiveMaxBytes);
    expect(_codec.parse(atLimit).resumes, isEmpty);
    expect(() => _codec.parse('$atLimit '), _limit('8 MiB'));
    final chinese = jsonEncode(
      _emptyArchive({'payload': '中' * (localDataArchiveMaxBytes ~/ 3 + 1)}),
    );
    expect(chinese.length, lessThan(localDataArchiveMaxBytes));
    expect(() => _codec.parse(chinese), _limit('8 MiB'));
  });

  test('容器64层通过，第65层在JSON解析前拒绝', () {
    final accepted = jsonEncode(_emptyArchive({'nested': _nested(63)}));
    expect(_codec.parse(accepted).resumes, isEmpty);
    final rejected = jsonEncode(_emptyArchive({'nested': _nested(64)}));
    expect(() => _codec.parse(rejected), _limit('64'));
  });

  test('微小JSON项200000通过，多一项拒绝；对象键也计数', () {
    // 基础档案13项，加未知键与数组2项，其余为数组内null值。
    final values = List<Object?>.filled(localDataArchiveMaxNodes - 15, null);
    expect(
      _codec.parse(jsonEncode(_emptyArchive({'nodes': values}))).resumes,
      isEmpty,
    );
    expect(
      () => _codec.parse(
        jsonEncode(
          _emptyArchive({
            'nodes': [...values, null],
          }),
        ),
      ),
      _limit('200000'),
    );
    expect(
      () => _codec.parse(
        jsonEncode(
          _emptyArchive({
            'nodes': {
              for (var index = 0; index < 100000; index++) '$index': null,
            },
          }),
        ),
      ),
      _limit('200000'),
    );
  });

  test('字符串中的括号、转义引号和反斜线不会计为结构深度', () {
    final text = jsonEncode(
      _emptyArchive({
        'quoted': '${'[{\\"' * 1000}end',
        'scalar': [true, false, null, -1.2e3],
      }),
    );
    expect(_codec.parse(text).resumes, isEmpty);
    expect(
      () => _codec.parse('{"x": [}'),
      throwsA(isA<LocalDataArchiveException>()),
    );
  });

  test('encode流式UTF8上限含缩进，超限拒绝且不改变领域对象', () {
    final snapshot = _snapshot(
      unmapped: {'payload': 'X' * localDataArchiveMaxBytes},
    );
    expect(() => _codec.encode(snapshot, _time), _limit('8 MiB'));
    expect(
      snapshot.resumes.single.versions.single.content.unmapped['payload'],
      hasLength(localDataArchiveMaxBytes),
    );
  });

  test('encode先拒绝深层metadata和unmapped，合法未知字段无损往返', () {
    expect(
      () => _codec.encode(_snapshot(metadata: {'nested': _nested(60)}), _time),
      _limit('64'),
    );
    expect(
      () => _codec.encode(_snapshot(unmapped: {'nested': _nested(58)}), _time),
      _limit('64'),
    );
    final source = _snapshot(
      metadata: {'nested': _nested(59)},
      unmapped: {'nested': _nested(57), 'raw': '中文\\"[]{}'},
    );
    final parsed = _codec.parse(_codec.encode(source, _time));
    expect(
      parsed.resumes.single.document.toJson(),
      source.resumes.single.document.toJson(),
    );
    expect(
      parsed.resumes.single.versions.single.toJson(),
      source.resumes.single.versions.single.toJson(),
    );
  });

  test('encode限制大量微小未知项，不静默截断', () {
    final source = _snapshot(unmapped: {'nodes': List.filled(200000, null)});
    expect(() => _codec.encode(source, _time), _limit('200000'));
    expect(
      source.resumes.single.versions.single.content.unmapped['nodes'],
      hasLength(200000),
    );
  });
}

Matcher _limit(String message) => throwsA(
  isA<LocalDataArchiveException>().having(
    (error) => error.message,
    '资源错误',
    contains(message),
  ),
);

Object? _nested(int depth) {
  Object? value;
  for (var index = 0; index < depth; index++) {
    value = [value];
  }
  return value;
}

Map<String, Object?> _emptyArchive(Map<String, Object?> extra) => {
  'exportFormatVersion': currentLocalDataExportFormatVersion,
  'exportedAtUtc': _time.toIso8601String(),
  'storageSchemaVersion': 4,
  'resumes': <Object?>[],
  'settings': <Object?>[],
  'agentAudits': <Object?>[],
  ...extra,
};

LocalDataSnapshot _snapshot({
  JsonMap metadata = const {},
  JsonMap unmapped = const {},
}) => LocalDataSnapshot(
  storageSchemaVersion: 4,
  resumes: [
    LocalResumeDataSnapshot(
      document: ResumeDocument(
        id: 'synthetic-doc',
        title: 'Synthetic',
        currentVersionId: 'synthetic-version',
        createdAt: _time,
        updatedAt: _time,
        metadata: metadata,
        extensions: {
          'unknown': [1, true],
        },
      ),
      versions: [
        ResumeVersion(
          id: 'synthetic-version',
          documentId: 'synthetic-doc',
          parentVersionId: null,
          schemaVersion: currentResumeSchemaVersion,
          content: ResumeData(
            profile: ResumeProfile(
              id: 'synthetic-profile',
              fullName: 'Synthetic',
              headline: '',
              email: '',
              phone: '',
              location: '',
            ),
            unmapped: unmapped,
          ),
          source: ResumeVersionSource.created,
          createdAt: _time,
          extensions: {
            'unknown': {'value': 1},
          },
        ),
      ],
    ),
  ],
  settings: [],
  agentAudits: [],
);
