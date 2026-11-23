import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/resume_file_delivery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('resume_all_in_one/file_delivery');
  final calls = <MethodCall>[];
  String result = 'saved';
  setUp(() {
    calls.clear();
    result = 'saved';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return result;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('Word 与 PDF 使用正确 MIME 与通用文件名，不夹带正文', () async {
    const delivery = ResumeFileDelivery();
    expect(
      await delivery.deliver(
        '/private/resume_exports/saved.docx',
        ResumeFileDeliveryAction.saveAs,
      ),
      ResumeFileDeliveryOutcome.saved,
    );
    result = 'shareOpened';
    expect(
      await delivery.deliver(
        '/private/resume_exports/saved.pdf',
        ResumeFileDeliveryAction.share,
      ),
      ResumeFileDeliveryOutcome.shareOpened,
    );
    expect(calls.map((call) => call.method), ['saveAs', 'share']);
    expect(calls[0].arguments, {
      'path': '/private/resume_exports/saved.docx',
      'fileName': 'resume.docx',
      'mimeType':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    });
    expect(calls[1].arguments['mimeType'], 'application/pdf');
  });
  test('取消独立返回；权限错误保留为失败，未知响应不冒称保存', () async {
    const delivery = ResumeFileDelivery();
    result = 'cancelled';
    expect(
      await delivery.deliver('/private/a.pdf', ResumeFileDeliveryAction.saveAs),
      ResumeFileDeliveryOutcome.cancelled,
    );
    result = 'unknown';
    await expectLater(
      delivery.deliver('/private/a.pdf', ResumeFileDeliveryAction.share),
      throwsFormatException,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'file_delivery_failed'),
        );
    await expectLater(
      delivery.deliver('/private/a.pdf', ResumeFileDeliveryAction.saveAs),
      throwsA(isA<PlatformException>()),
    );
  });
  test('单份 JSON、Markdown 与数据档案使用正确 MIME 和无个人信息的名称', () async {
    const delivery = ResumeFileDelivery();
    for (final path in [
      '/private/resume_exports/synthetic.json',
      '/private/resume_exports/synthetic.md',
      '/private/local_data_exports/local_data_001.json',
    ]) {
      await delivery.deliver(path, ResumeFileDeliveryAction.saveAs);
    }
    expect(calls.map((call) => call.arguments['mimeType']), [
      'application/json',
      'text/markdown',
      'application/json',
    ]);
    expect(calls.map((call) => call.arguments['fileName']), [
      'resume.json',
      'resume.md',
      'local-data.json',
    ]);
  });
  test('不支持的类型在打开系统界面前拒绝', () async {
    await expectLater(
      const ResumeFileDelivery().deliver(
        '/private/database.sqlite',
        ResumeFileDeliveryAction.share,
      ),
      throwsFormatException,
    );
    expect(calls, isEmpty);
  });
}
