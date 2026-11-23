import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/local_data_archive.dart';
import 'package:resume_all_in_one_client/src/local_data_archive_file_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('已知超限不打开正文，读取中增长超限会关闭流', () async {
    final known = _ArchiveFile(localDataArchiveMaxBytes + 1, []);
    await expectLater(_picker(known).pickArchive(), throwsFormatException);
    expect(known.opened, isFalse);
    final growing = _ArchiveFile(1, [
      Uint8List(localDataArchiveMaxBytes),
      Uint8List(1),
      Uint8List(1),
    ]);
    await expectLater(_picker(growing).pickArchive(), throwsFormatException);
    expect(growing.closed, isTrue);
    expect(growing.delivered, 2);
  });

  test('边界大小保持原字节，选择取消不构造档案', () async {
    final bytes = Uint8List(localDataArchiveMaxBytes)..[0] = 255;
    final selected = await _picker(_ArchiveFile(-1, [bytes])).pickArchive();
    expect(selected!.bytes, bytes);
    expect(await _picker(null).pickArchive(), isNull);
  });

  test('名称错误和流读取失败都不返回可确认的档案', () async {
    final wrongType = _ArchiveFile(1, [], name: 'synthetic.md');
    await expectLater(_picker(wrongType).pickArchive(), throwsFormatException);
    expect(wrongType.opened, isFalse);
    final failing = _ArchiveFile(1, [Uint8List(1)], fail: true);
    await expectLater(_picker(failing).pickArchive(), throwsStateError);
    expect(failing.closed, isTrue);
  });

  group('Android 档案通道', () {
    const channel = MethodChannel('resume_all_in_one/archive_import');
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    test('默认路径接收 bytes 和取消，不调用插件预读', () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'pickLocalDataArchiveFile');
            return ++calls == 1
                ? {
                    'fileName': 'synthetic.JSON',
                    'bytes': Uint8List.fromList([255]),
                  }
                : null;
          });
      const picker = SystemLocalDataArchiveFilePicker();
      expect((await picker.pickArchive())!.bytes, [255]);
      expect(await picker.pickArchive(), isNull);
    });
    test('原生超限和无效响应均拒绝，错误不泄露 provider 详情', () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            if (++calls == 1) {
              throw PlatformException(
                code: 'input_too_large',
                message: 'private',
              );
            }
            return {'fileName': 'synthetic.json', 'bytes': 'invalid'};
          });
      const picker = SystemLocalDataArchiveFilePicker();
      await expectLater(
        picker.pickArchive(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            '本地数据档案不能超过 8 MiB',
          ),
        ),
      );
      await expectLater(picker.pickArchive(), throwsFormatException);
    });
  });
}

SystemLocalDataArchiveFilePicker _picker(XFile? file) =>
    SystemLocalDataArchiveFilePicker(
      pickFile: ({required acceptedTypeGroups}) async => file,
    );

class _ArchiveFile extends XFile {
  _ArchiveFile(
    this.reportedLength,
    this.chunks, {
    String name = 'synthetic.json',
    this.fail = false,
  }) : super(name);
  final int reportedLength;
  final List<Uint8List> chunks;
  final bool fail;
  bool opened = false;
  bool closed = false;
  int delivered = 0;
  @override
  Future<int> length() async => reportedLength;
  @override
  Future<Uint8List> readAsBytes() => throw StateError('禁止整文件读取');
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    opened = true;
    try {
      for (final chunk in chunks) {
        delivered++;
        yield chunk;
      }
      if (fail) throw StateError('synthetic read failure');
    } finally {
      closed = true;
    }
  }
}
