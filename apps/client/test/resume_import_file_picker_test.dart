import 'package:document_io/document_io.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SystemResumeImportFilePicker picker(XFile? file) =>
      SystemResumeImportFilePicker(
        pickFile: ({required acceptedTypeGroups}) async {
          expect(acceptedTypeGroups.single.extensions, ['txt', 'md']);
          return file;
        },
      );

  test('取消选择不读取文件', () async {
    expect(await picker(null).pickResumeTextFile(), isNull);
  });

  test('超过 512 KiB 在打开字节流前拒绝', () async {
    final file = _StreamFile(defaultResumeImportMaxBytes + 1, []);
    await expectLater(
      picker(file).pickResumeTextFile(),
      throwsA(
        isA<ResumeTextImportException>().having(
          (error) => error.failure,
          'failure',
          ResumeTextImportFailure.inputTooLarge,
        ),
      ),
    );
    expect(file.opened, isFalse);
  });

  test('长度检查后增长的文件在累积超限前拒绝并取消流', () async {
    final file = _StreamFile(1, [
      Uint8List(defaultResumeImportMaxBytes),
      Uint8List(1),
      Uint8List(10),
    ]);
    await expectLater(
      picker(file).pickResumeTextFile(),
      throwsA(isA<ResumeTextImportException>()),
    );
    expect(file.deliveredChunks, 2);
    expect(file.closed, isTrue);
  });

  test('恰好 512 KiB 保留文件名和原始字节，不调用整文件读取', () async {
    final content = Uint8List(defaultResumeImportMaxBytes)..last = 42;
    final selected = await picker(
      _StreamFile(content.length, [content]),
    ).pickResumeTextFile();
    expect(selected!.fileName, 'synthetic.md');
    expect(selected.bytes, content);
  });

  test('字节流读取失败保持失败，不返回截断的文件', () async {
    final file = _StreamFile(1, [Uint8List(1)], fail: true);
    await expectLater(picker(file).pickResumeTextFile(), throwsStateError);
    expect(file.closed, isTrue);
  });

  test('无效 UTF-8 不在平台边界修复，后续导入器严格拒绝', () async {
    final selected = await picker(
      _StreamFile(1, [
        Uint8List.fromList([255]),
      ]),
    ).pickResumeTextFile();
    expect(
      () => const ResumeTextImporter().importBytes(
        selected!.bytes,
        fileName: selected.fileName,
        profileId: 'synthetic',
      ),
      throwsA(
        isA<ResumeTextImportException>().having(
          (error) => error.failure,
          'failure',
          ResumeTextImportFailure.invalidUtf8,
        ),
      ),
    );
  });

  group('Android 原生有界选择通道', () {
    const channel = MethodChannel('resume_all_in_one/text_import');
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('默认 Android 路径接收原始字节和取消，绕开整文件预读插件', () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'pickResumeTextFile');
            calls++;
            return calls == 1
                ? {
                    'fileName': 'synthetic.md',
                    'bytes': Uint8List.fromList([255]),
                  }
                : null;
          });
      const picker = SystemResumeImportFilePicker();
      final selected = await picker.pickResumeTextFile();
      expect(selected!.fileName, 'synthetic.md');
      expect(selected.bytes, [255]);
      expect(await picker.pickResumeTextFile(), isNull);
      expect(calls, 2);
    });

    test('原生超限错误与响应超限均以导入失败返回，不展示原始异常', () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            calls++;
            if (calls == 1) {
              throw PlatformException(
                code: 'input_too_large',
                message: 'synthetic private details',
              );
            }
            return {
              'fileName': 'synthetic.txt',
              'bytes': Uint8List(defaultResumeImportMaxBytes + 1),
            };
          });
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          const SystemResumeImportFilePicker().pickResumeTextFile(),
          throwsA(
            isA<ResumeTextImportException>()
                .having(
                  (error) => error.failure,
                  'failure',
                  ResumeTextImportFailure.inputTooLarge,
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('private')),
                ),
          ),
        );
      }
    });

    test('无效原生响应不当成取消或成功文件', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {
              'fileName': 'synthetic.txt',
              'bytes': 'invalid bytes',
            },
          );
      await expectLater(
        const SystemResumeImportFilePicker().pickResumeTextFile(),
        throwsFormatException,
      );
    });

    test('中文DOCX和PDF提取文本保留格式与未知内容，确认前只生成预览', () async {
      for (final format in ['docx', 'pdf']) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (_) async => {
                'fileName': '合成简历.${format.toUpperCase()}',
                'bytes': Uint8List(0),
                'extractedText': '姓名：合成用户\n项目：只保留来源，不编造经历',
                'format': format,
              },
            );
        final selected = await const SystemResumeImportFilePicker()
            .pickResumeTextFile();
        final preview = selected!.createPreview(profileId: 'synthetic');
        expect(preview.resume.profile.fullName, '合成用户');
        expect(preview.format.name, format);
        expect(preview.unmappedLineCount, 1);
        expect(selected.bytes, isEmpty);
      }
    });

    test('空扫描件、加密、超限、超时和旧DOC给出可操作错误', () async {
      for (final code in [
        'no_document_text',
        'encrypted_document',
        'document_too_complex',
        'document_timeout',
        'legacy_word_document',
        'document_input_too_large',
        'invalid_document',
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (_) async => throw PlatformException(
                code: code,
                message: 'private provider details',
              ),
            );
        await expectLater(
          const SystemResumeImportFilePicker().pickResumeTextFile(),
          throwsA(
            isA<ResumeTextImportException>().having(
              (e) => e.message,
              'redacted error',
              isNot(contains('private')),
            ),
          ),
        );
      }
    });

    test('提取文本不能越过512KiB或冒充另一种文件格式', () async {
      for (final response in [
        {
          'fileName': 'resume.pdf',
          'bytes': Uint8List(0),
          'extractedText': 'x' * (defaultResumeImportMaxBytes + 1),
          'format': 'pdf',
        },
        {
          'fileName': 'resume.txt',
          'bytes': Uint8List(0),
          'extractedText': '姓名：合成用户',
          'format': 'pdf',
        },
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => response);
        await expectLater(
          const SystemResumeImportFilePicker().pickResumeTextFile(),
          throwsException,
        );
      }
    });
  });
}

class _StreamFile extends XFile {
  _StreamFile(this.reportedLength, this.chunks, {this.fail = false})
    : super('synthetic.md');
  final int reportedLength;
  final List<Uint8List> chunks;
  final bool fail;
  bool opened = false;
  bool closed = false;
  int deliveredChunks = 0;

  @override
  Future<int> length() async => reportedLength;

  @override
  Future<Uint8List> readAsBytes() => throw StateError('不允许整文件读取');

  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    opened = true;
    try {
      for (final chunk in chunks) {
        deliveredChunks++;
        yield chunk;
      }
      if (fail) throw StateError('synthetic read failure');
    } finally {
      closed = true;
    }
  }
}
