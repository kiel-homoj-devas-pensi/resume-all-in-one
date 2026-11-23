import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

void main() {
  final data = File('test/fixtures/photo.jpg').readAsBytesSync();
  ResumePhoto photo({Uint8List? bytes, int width = 500}) => ResumePhoto(
    dataBase64: base64Encode(bytes ?? data),
    mimeType: 'image/jpeg',
    width: width,
    height: 700,
    extensions: const {'futurePhotoField': 'preserved'},
  );
  test('照片在Canonical往返并保留扩展，无照片旧JSON不增加字段', () {
    final original = const CanonicalResumeCodec().decode(
      File('test/fixtures/resume_v0_1.json').readAsStringSync(),
    );
    expect(original.profile.toJson().containsKey('photo'), isFalse);
    final json = original.toJson();
    (json['profile']! as Map)['photo'] = photo().toJson();
    final decoded = const CanonicalResumeCodec().decode(jsonEncode(json));
    expect(decoded.profile.photo!.bytes, data);
    expect(decoded.profile.photo!.extensions['futurePhotoField'], 'preserved');
    expect(decoded.toJson(), json);
    expect(const ResumeValidator().validate(decoded).isValid, isTrue);
  });
  test('编码、MIME、真实像素尺寸和字节上限不能伪报', () {
    expect(() => photo(width: 25), throwsFormatException);
    expect(
      () => photo(bytes: Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(
      () => photo(bytes: Uint8List.fromList([0xff, 0xd8, ...List.filled(12, 0xff), 0xd9])),
      throwsFormatException,
    );
    expect(
      () => photo(bytes: Uint8List(ResumePhoto.maxBytes + 1)),
      throwsFormatException,
    );
    final wrongSize = Uint8List.fromList(data);
    for (var i = 2; i < wrongSize.length - 9; i++) {
      if (wrongSize[i] == 0xff && wrongSize[i + 1] == 0xc0) {
        wrongSize[i + 7] = 0;
        wrongSize[i + 8] = 1;
        break;
      }
    }
    expect(() => photo(bytes: wrongSize), throwsFormatException);
    expect(
      () => ResumePhoto(
        dataBase64: base64Encode(data),
        mimeType: 'image/png',
        width: 500,
        height: 700,
      ),
      throwsFormatException,
    );
  });
  test('取出的图片字节是副本，修改不污染历史版本', () {
    final value = photo();
    value.bytes[0] = 0;
    expect(value.bytes, data);
  });
}
