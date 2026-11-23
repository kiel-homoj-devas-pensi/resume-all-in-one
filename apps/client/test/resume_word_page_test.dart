import 'package:flutter/services.dart';
import 'dart:io';

import 'package:document_io/document_io.dart';
import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/main.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'support/legal_consent_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_home_page.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_word_page.dart';
import 'package:resume_all_in_one_client/src/resume_pdf_preview_page.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  late LocalStorageDatabase database;
  late DriftResumeRepository repository;
  late Directory exportRoot;
  late ResumeWorkspaceController controller;
  late ResumeVersion originalVersion;
  var fontLoadCount = 0;
  var failFileAccess = false;
  final deliveryCalls = <MethodCall>[];
  var deliveryResult = 'cancelled';
  var failDelivery = false;

  setUp(() async {
    database = LocalStorageDatabase.inMemory();
    repository = DriftResumeRepository(database);
    exportRoot = await Directory.systemTemp.createTemp('resume-word-ui-');
    fontLoadCount = 0;
    failFileAccess = false;
    deliveryCalls.clear();
    deliveryResult = 'cancelled';
    failDelivery = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('resume_all_in_one/file_delivery'),
          (call) async {
            deliveryCalls.add(call);
            if (failDelivery) {
              throw PlatformException(code: 'file_delivery_failed');
            }
            return deliveryResult;
          },
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('resume_all_in_one/file_delivery'),
          null,
        );
    await database.close();
    await exportRoot.delete(recursive: true);
  });

  void testWordPage(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        // 先移除应用，排空 Drift 设置监听后再关闭数据库。
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    });
  }

  Future<void> pumpSavedResume(
    WidgetTester tester, {
    AppThemePreference theme = AppThemePreference.light,
  }) async {
    await DriftAppSettingsRepository(database).setThemePreference(theme);
    await tester.pumpWidget(
      ResumeAllInOneApp(
        legalConsentController: await acceptedLegalConsentFixture(),
        repository: repository,
        settingsRepository: DriftAppSettingsRepository(database),
        localAgentCheckService: createOfflineLocalAgentCheckService(
          resumeRepository: repository,
          auditRepository: DriftAgentAuditRepository(database),
        ),
        localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
          resumeRepository: repository,
          auditRepository: DriftAgentAuditRepository(database),
        ),
        localDataManagementService: LocalDataManagementService(
          repository: DriftLocalDataRepository(database),
          rootDirectory: () async => exportRoot,
        ),
        accessPolicy: CapabilityAccessPolicy.mvp(),
        fileExporter: ResumeFileExporter(
          rootDirectory: () async {
            if (failFileAccess) {
              throw const FileSystemException('合成的文稿保存失败');
            }
            return exportRoot;
          },
          fontLoader: (_) async {
            fontLoadCount++;
            // 这里只验证转换入口及恢复；真实字体与 PDF 渲染由文档测试验证。
            throw const FileSystemException('合成的 PDF 字体加载失败');
          },
        ),
        importFilePicker: _UnusedTextImportPicker(),
      ),
    );
    await tester.pumpAndSettle();
    controller = tester
        .widget<ResumeHomePage>(find.byType(ResumeHomePage))
        .controller;
    expect(
      await controller.createDocument(title: '合成 Word 简历', fullName: '合成候选人'),
      isTrue,
    );
    originalVersion = controller.currentVersion!;
    controller.takeFeedback();
    await tester.pumpAndSettle();
  }

  List<File> savedWordFiles() {
    final directory = Directory(
      '${exportRoot.path}${Platform.pathSeparator}resume_exports',
    );
    if (!directory.existsSync()) return [];
    return directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.docx'))
        .toList();
  }

  Future<void> expectCanonicalUnchanged() async {
    final versions = await repository.listVersions(originalVersion.documentId);
    expect(versions, hasLength(1));
    expect(versions.single.id, originalVersion.id);
    expect(
      jsonDeepEquals(
        versions.single.content.toJson(),
        originalVersion.content.toJson(),
      ),
      isTrue,
    );
  }

  Future<void> openWord(WidgetTester tester) async {
    await _tapFileAction(tester, const Key('打开Word文稿'), controller);
    expect(find.byType(ResumeWordPage), findsOneWidget);
    expect(find.text('Word 已保存在本机'), findsOneWidget);
  }

  testWordPage('Word 是默认导出入口且修改段落保存重开后保留文字和原文稿', (tester) async {
    await pumpSavedResume(tester);
    expect(find.widgetWithText(FilledButton, '导出 Word'), findsOneWidget);
    await _tap(tester, const Key('导出菜单'));
    expect(find.text('Word 文稿（默认）'), findsOneWidget);
    expect(find.text('导出 Markdown'), findsOneWidget);
    expect(find.text('导出 JSON'), findsOneWidget);
    expect(find.textContaining('PDF 转 Word'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await openWord(tester);
    expect(find.textContaining('修改不会回写简历历史'), findsOneWidget);
    final originalFile = savedWordFiles().single;
    final originalBytes = originalFile.readAsBytesSync();
    const editedText = '修改后的交付姓名\n中文与 Flutter & <项目> 混排';
    await _editFirstParagraph(tester, editedText);
    expect(find.text('Word 有未保存的修改'), findsOneWidget);
    expect(savedWordFiles(), hasLength(1));
    await _tapFileAction(tester, const Key('保存Word'), controller);
    expect(find.text('Word 已保存在本机'), findsOneWidget);
    expect(savedWordFiles(), hasLength(2));
    expect(originalFile.readAsBytesSync(), originalBytes);
    final editedFile = savedWordFiles().singleWhere(
      (file) => file.path != originalFile.path,
    );
    expect(
      const ResumeDocxCodec()
          .decode(editedFile.readAsBytesSync())
          .paragraphs
          .first
          .text,
      editedText,
    );

    await _tap(tester, const Key('返回Word文稿'));
    expect(find.byType(ResumeWordPage), findsNothing);
    await openWord(tester);
    expect(
      tester.widget<ResumeWordPage>(find.byType(ResumeWordPage)).word.path,
      editedFile.path,
    );
    expect(find.text(editedText), findsOneWidget);
    expect(savedWordFiles(), hasLength(2));
    expect(fontLoadCount, 0);
    await expectCanonicalUnchanged();
  });

  testWordPage('顶部和系统返回支持继续编辑放弃修改及保存后返回', (tester) async {
    await pumpSavedResume(tester);
    await openWord(tester);
    await _editFirstParagraph(tester, '尚未保存的 Word 姓名');
    await _tap(tester, const Key('返回Word文稿'));
    expect(find.text('保存 Word 修改？'), findsOneWidget);
    await _tap(tester, const Key('继续编辑Word'));
    expect(find.text('尚未保存的 Word 姓名'), findsOneWidget);
    expect(find.text('Word 有未保存的修改'), findsOneWidget);
    expect(savedWordFiles(), hasLength(1));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保存 Word 修改？'), findsOneWidget);
    await _tap(tester, const Key('放弃Word修改'));
    expect(find.byType(ResumeWordPage), findsNothing);
    await openWord(tester);
    expect(find.text('合成候选人'), findsOneWidget);
    expect(find.text('尚未保存的 Word 姓名'), findsNothing);
    expect(savedWordFiles(), hasLength(1));

    await _editFirstParagraph(tester, '返回前明确保存的 Word 姓名');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _tapFileAction(tester, const Key('保存Word并继续'), controller);
    expect(find.byType(ResumeWordPage), findsNothing);
    expect(savedWordFiles(), hasLength(2));
    await openWord(tester);
    expect(find.text('返回前明确保存的 Word 姓名'), findsOneWidget);
    await expectCanonicalUnchanged();
  });

  for (final action in ['另存Word', '分享Word']) {
    testWordPage('$action 先保存草稿再交付已保存字节，取消或权限失败保护原件', (tester) async {
      await pumpSavedResume(tester);
      await openWord(tester);
      final originalFile = savedWordFiles().single;
      final originalBytes = originalFile.readAsBytesSync();
      deliveryResult = action == '另存Word' ? 'cancelled' : 'shareOpened';
      await _editFirstParagraph(tester, '交付标记_中文_028');
      await _tap(tester, const Key('Word交付菜单'));
      await _tap(tester, Key(action));
      expect(find.text('保存 Word 修改？'), findsOneWidget);
      expect(deliveryCalls, isEmpty);
      await _tapFileAction(tester, const Key('保存Word并继续'), controller);
      expect(deliveryCalls, hasLength(1));
      final selected = File(deliveryCalls.single.arguments['path'] as String);
      expect(
        const ResumeDocxCodec()
            .decode(selected.readAsBytesSync())
            .paragraphs
            .first
            .text,
        '交付标记_中文_028',
      );
      expect(originalFile.readAsBytesSync(), originalBytes);
      expect(find.text('Word 已保存在本机'), findsOneWidget);
      expect(
        find.textContaining(action == '另存Word' ? '已取消另存' : '已打开系统分享选择器'),
        findsOneWidget,
      );
      failDelivery = true;
      await _tap(tester, const Key('Word交付菜单'));
      await _tap(tester, Key(action));
      expect(find.textContaining('系统文件交付未完成'), findsOneWidget);
      expect(selected.existsSync(), isTrue);
      expect(originalFile.readAsBytesSync(), originalBytes);
      await expectCanonicalUnchanged();
    });
  }

  for (final choice in ['继续编辑Word', '放弃Word修改', '保存Word并继续']) {
    testWordPage('PDF 转换前选择 $choice 时只使用已保存文稿并保护修改', (tester) async {
      await pumpSavedResume(tester);
      await openWord(tester);
      final originalFile = savedWordFiles().single;
      final originalBytes = originalFile.readAsBytesSync();
      await _editFirstParagraph(tester, 'PDF 转换前修改的文字');
      await _tap(tester, const Key('Word转PDF'));
      expect(find.text('保存 Word 修改？'), findsOneWidget);
      expect(find.textContaining('转换、另存与分享只使用已保存的 Word'), findsOneWidget);
      expect(fontLoadCount, 0);
      expect(savedWordFiles(), hasLength(1));

      await _tapFileAction(tester, Key(choice), controller);
      expect(find.byType(ResumeWordPage), findsOneWidget);
      expect(originalFile.readAsBytesSync(), originalBytes);
      if (choice == '继续编辑Word') {
        expect(find.text('PDF 转换前修改的文字'), findsOneWidget);
        expect(find.text('Word 有未保存的修改'), findsOneWidget);
        expect(fontLoadCount, 0);
        expect(savedWordFiles(), hasLength(1));
      } else {
        expect(fontLoadCount, 1);
        expect(find.text('Word 转 PDF 失败，Word 文稿仍保留在本机。'), findsOneWidget);
        expect(find.text('Word 已保存在本机'), findsOneWidget);
        ScaffoldMessenger.of(
          tester.element(find.byType(ResumeWordPage)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('保存Word')).hitTestable(), findsOneWidget);
        if (choice == '放弃Word修改') {
          expect(find.text('合成候选人'), findsOneWidget);
          expect(find.text('PDF 转换前修改的文字'), findsNothing);
          expect(savedWordFiles(), hasLength(1));
        } else {
          expect(find.text('PDF 转换前修改的文字'), findsOneWidget);
          expect(savedWordFiles(), hasLength(2));
        }
        await _editFirstParagraph(tester, '转换失败后仍可继续修改');
        expect(find.text('Word 有未保存的修改'), findsOneWidget);
        await _tapFileAction(tester, const Key('保存Word'), controller);
        expect(find.text('Word 已保存在本机'), findsOneWidget);
      }
      await expectCanonicalUnchanged();
    });
  }

  testWordPage('保存失败不退出也不丢草稿并可在恢复后重新保存', (tester) async {
    await pumpSavedResume(tester);
    await openWord(tester);
    final originalFile = savedWordFiles().single;
    final originalBytes = originalFile.readAsBytesSync();
    await _editFirstParagraph(tester, '保存失败后保留的草稿');
    await _tap(tester, const Key('返回Word文稿'));
    failFileAccess = true;
    await _tapFileAction(tester, const Key('保存Word并继续'), controller);
    expect(find.byType(ResumeWordPage), findsOneWidget);
    expect(find.text('保存失败后保留的草稿'), findsOneWidget);
    expect(find.text('Word 有未保存的修改'), findsOneWidget);
    expect(find.text('Word 保存失败，请重试。已有文稿和简历版本未改变。'), findsOneWidget);
    expect(savedWordFiles(), hasLength(1));
    expect(originalFile.readAsBytesSync(), originalBytes);

    failFileAccess = false;
    await _tapFileAction(tester, const Key('保存Word'), controller);
    expect(find.text('Word 已保存在本机'), findsOneWidget);
    expect(savedWordFiles(), hasLength(2));
    await expectCanonicalUnchanged();
  });

  testWordPage('超过两万字的合法段落再次编辑并保存时保留全文和末尾追加内容', (tester) async {
    await pumpSavedResume(tester);
    await openWord(tester);
    final originalFile = savedWordFiles().single;
    final originalBytes = originalFile.readAsBytesSync();
    final longText = '${List.filled(20001, '文').join()}末尾标记';
    await _editFirstParagraph(tester, longText);

    final paragraph = find.byKey(const Key('Word段落_0'));
    await tester.ensureVisible(paragraph);
    await tester.pumpAndSettle();
    // 长段落本身高于屏幕，从可见顶部进入，不点击屏幕外的几何中心。
    await tester.tapAt(tester.getTopLeft(paragraph) + const Offset(18, 18));
    await tester.pumpAndSettle();
    final textField = find.byKey(const Key('Word段落文字'));
    expect(tester.widget<TextField>(textField).controller!.text, longText);
    final appendedText = '$longText再次编辑追加';
    await tester.enterText(textField, appendedText);
    await _tap(tester, const Key('完成Word段落'));
    await _tapFileAction(tester, const Key('保存Word'), controller);

    final editedFile = savedWordFiles().singleWhere(
      (file) => file.path != originalFile.path,
    );
    final savedText = const ResumeDocxCodec()
        .decode(editedFile.readAsBytesSync())
        .paragraphs
        .first
        .text;
    expect(savedText, appendedText);
    expect(savedText, endsWith('末尾标记再次编辑追加'));
    expect(originalFile.readAsBytesSync(), originalBytes);
    await expectCanonicalUnchanged();
  });

  for (final theme in [AppThemePreference.light, AppThemePreference.dark]) {
    testWordPage('${theme.name} PDF 交付按钮在窄屏大字体下可达，渲染失败可返回', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.7;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('net.nfet.printing'),
        (_) async => <String, bool>{'canRaster': false},
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('net.nfet.printing'),
          null,
        ),
      );
      await pumpSavedResume(tester, theme: theme);
      Navigator.of(tester.element(find.byType(ResumeHomePage))).push(
        MaterialPageRoute<void>(
          builder: (_) => ResumePdfPreviewPage(
            controller: controller,
            preparedPdf: PreparedResumePdf(
              document: controller.currentDocument!,
              version: originalVersion,
              bytes: Uint8List.fromList([37, 80, 68, 70]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final key in ['另存预览PDF', '分享预览PDF', '导出预览PDF']) {
        expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
      }
      expect(find.text('无法显示 PDF 预览，请返回后重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(OutlinedButton, '返回简历'));
      await tester.pumpAndSettle();
      expect(find.byType(ResumePdfPreviewPage), findsNothing);
      await expectCanonicalUnchanged();
    });
    testWordPage('${theme.name} 主题在 320 宽 1.7 倍文字与键盘下可编辑并处理未保存提示', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.7;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpSavedResume(tester, theme: theme);
      await openWord(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('保存Word')).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('Word转PDF')).hitTestable(), findsOneWidget);

      await _tap(tester, const Key('Word段落_0'));
      await tester.enterText(
        find.byKey(const Key('Word段落文字')),
        '窄屏下的 Word 编辑内容',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('Word段落文字')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('Word段落文字')).hitTestable(), findsOneWidget);
      final finish = find.byKey(const Key('完成Word段落'));
      expect(finish.hitTestable(), findsOneWidget);
      expect(tester.getRect(finish).bottom, lessThanOrEqualTo(400));
      expect(tester.takeException(), isNull);
      await tester.tap(finish);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text('Word 有未保存的修改'), findsOneWidget);

      await _tap(tester, const Key('Word转PDF'));
      for (final action in ['继续编辑Word', '放弃Word修改', '保存Word并继续']) {
        expect(find.byKey(Key(action)).hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await _tap(tester, const Key('继续编辑Word'));
      await _tapFileAction(tester, const Key('保存Word'), controller);
      expect(find.text('Word 已保存在本机'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tap(tester, const Key('Word交付菜单'));
      expect(find.byKey(const Key('另存Word')).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('分享Word')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await expectCanonicalUnchanged();
    });
  }
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _editFirstParagraph(WidgetTester tester, String text) async {
  await _tap(tester, const Key('Word段落_0'));
  await tester.enterText(find.byKey(const Key('Word段落文字')), text);
  await _tap(tester, const Key('完成Word段落'));
}

Future<void> _tapFileAction(
  WidgetTester tester,
  Key key,
  ResumeWorkspaceController controller,
) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  ScaffoldMessenger.of(tester.element(target)).removeCurrentSnackBar();
  await tester.pumpAndSettle();
  await tester.tap(target);
  // 先释放确认框的 Future，再交替推进真实文件 I/O 和测试中的微任务。
  await tester.pump();
  final elapsed = Stopwatch()..start();
  do {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  } while (controller.isBusy && elapsed.elapsed < const Duration(seconds: 5));
  expect(controller.isBusy, isFalse, reason: '文稿文件操作应结束');
  await tester.pumpAndSettle();
}

final class _UnusedTextImportPicker implements ResumeImportFilePicker {
  @override
  Future<SelectedResumeTextFile?> pickResumeTextFile() async => null;
}
