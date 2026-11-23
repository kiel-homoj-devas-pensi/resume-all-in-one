import 'dart:convert';
import 'dart:io';

import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

void main() {
  final cases =
      jsonDecode(
            File(
              'test/fixtures/cloud_content_cases_v0_1.json',
            ).readAsStringSync(),
          )!
          as List<Object?>;
  for (final value in cases) {
    final scenario = value! as Map<String, Object?>;
    test('云快照共同用例 ${scenario['name']}', () {
      final content =
          jsonDecode(File('test/fixtures/resume_v0_1.json').readAsStringSync())!
              as Map<String, Object?>;
      final path = scenario['path']! as List<Object?>;
      Object? container = content;
      for (final part in path.take(path.length - 1)) {
        container = part is int
            ? (container! as List<Object?>)[part]
            : (container! as Map<String, Object?>)[part];
      }
      final key = path.last;
      if (key is int) {
        (container! as List<Object?>)[key] = scenario['value'];
      } else {
        (container! as Map<String, Object?>)[key! as String] =
            scenario['value'];
      }
      const codec = CanonicalResumeCodec();
      if (scenario['accepted'] == true) {
        final loaded = codec.decode(jsonEncode(content));
        expect(
          jsonDeepEquals(jsonDecode(codec.encode(loaded)), content),
          isTrue,
        );
      } else {
        expect(
          () => codec.decode(jsonEncode(content)),
          throwsA(isA<Exception>()),
        );
      }
    });
  }
}
