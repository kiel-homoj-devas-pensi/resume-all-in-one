import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/resume_photo_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('resume_all_in_one/photo_import');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final bytes = File(
    '../../packages/resume_domain/test/fixtures/photo.jpg',
  ).readAsBytesSync();
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('原生规范化照片契约与取消', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'bytes': bytes,
        'mimeType': 'image/jpeg',
        'width': 500,
        'height': 700,
      },
    );
    final photo = await const SystemResumePhotoPicker().pickPhoto();
    expect(photo!.bytes, bytes);
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await const SystemResumePhotoPicker().pickPhoto(), isNull);
  });
  test('10MB限制、格式、损坏和读取超时转换为可操作提示', () async {
    for (final (code, message) in [
      ('photo_too_large', '10MB'),
      ('photo_unsupported', '.jpg'),
      ('photo_invalid', '损坏'),
      ('photo_timeout', '超时'),
    ]) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: code),
      );
      await expectLater(
        const SystemResumePhotoPicker().pickPhoto(),
        throwsA(
          isA<ResumePhotoException>().having(
            (e) => e.message,
            'message',
            contains(message),
          ),
        ),
      );
    }
  });
  test('错误类型、尺寸与内容均拒绝', () async {
    for (final data in [
      <String, Object?>{
        'bytes': bytes,
        'mimeType': 'image/jpeg',
        'width': 25,
        'height': 35,
      },
      <String, Object?>{
        'bytes': Uint8List(5),
        'mimeType': 'image/jpeg',
        'width': 500,
        'height': 700,
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => data);
      await expectLater(
        const SystemResumePhotoPicker().pickPhoto(),
        throwsA(isA<ResumePhotoException>()),
      );
    }
  });
}
