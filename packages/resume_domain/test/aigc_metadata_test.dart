import 'dart:convert';
import 'dart:io';

import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

void main() {
  final metadata = ResumeAigcMetadata.firstGeneration(
    providerName: 'Ji Ouqi',
    contentId: 'synthetic-usage-00000001',
  );
  test(
    'explicit name and content identity roundtrip without inventing a code',
    () {
      expect(metadata.contentProducer, 'Ji Ouqi');
      expect(metadata.contentPropagator, 'Ji Ouqi');
      expect(metadata.produceId, metadata.propagateId);
      expect(metadata.toJson().length, 7);
      expect(metadata.reservedCode1, isEmpty);
      expect(
        ResumeAigcMetadata.fromJson(
          jsonDecode(metadata.toJsonString()),
        ).contentProducer,
        'Ji Ouqi',
      );
    },
  );

  test('missing, extra, mistyped, invalid label and controls are rejected', () {
    for (final json in [
      {...metadata.toJson()}..remove('ProduceID'),
      {...metadata.toJson(), 'unverifiedSupplier': 'made-up'},
      {...metadata.toJson(), 'Label': 1},
      {...metadata.toJson(), 'Label': '0'},
      {...metadata.toJson(), 'ContentProducer': ''},
      {...metadata.toJson(), 'ProduceID': 'bad\nID'},
      {...metadata.toJson(), 'PropagateID': '\u007f'},
      {...metadata.toJson(), 'ContentProducer': 'Ji\u2028Ouqi'},
      {...metadata.toJson(), 'ContentProducer': 'Ji\u202eOuqi'},
      {...metadata.toJson(), 'ContentProducer': 'a' * 513},
      {...metadata.toJson(), 'ReservedCode1': 'a' * 4097},
      {
        ...metadata.toJson(),
        'ReservedCode1': '测' * 4096,
        'ReservedCode2': '测' * 4096,
      },
    ]) {
      expect(() => ResumeAigcMetadata.fromJson(json), throwsFormatException);
    }
  });

  test(
    'source absence stays absent and codec preserves the exact seven fields',
    () {
      final resume = const CanonicalResumeCodec().decode(
        File('test/fixtures/resume_v0_1.json').readAsStringSync(),
      );
      expect(ResumeAigcMetadata.fromResume(resume), isNull);
      final marked = metadata.attachTo(resume);
      final restored = const CanonicalResumeCodec().decode(
        const CanonicalResumeCodec().encode(marked),
      );
      expect(
        ResumeAigcMetadata.fromResume(restored)!.toJson(),
        metadata.toJson(),
      );
      expect(ResumeAiProvenance.fromResume(restored), isNull);
      expect(ResumeAiProvenance.noticeForResume(restored), contains('AI生成'));
    },
  );

  test(
    'possible and suspected labels remain distinct from confirmed generation',
    () {
      for (final label in ['2', '3']) {
        final value = ResumeAigcMetadata.fromJson({
          ...metadata.toJson(),
          'Label': label,
        });
        expect(value.notice, isNot(ResumeAiProvenance.notice));
      }
    },
  );
}
