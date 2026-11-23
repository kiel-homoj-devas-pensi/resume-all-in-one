import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/main.dart';
import 'package:resume_all_in_one_client/src/app_theme.dart';
import 'package:resume_all_in_one_client/src/workspace_pages.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final screenshotDirectory = Platform.environment['LICENSE_SCREENSHOT_DIR'];
  setUpAll(() async {
    if (screenshotDirectory != null) {
      await (FontLoader('LicenseQaFont')..addFont(
            rootBundle.load(
              'packages/document_io/assets/fonts/NotoSansSC-Regular.ttf',
            ),
          ))
          .load();
    }
  });

  setUp(LicenseRegistry.reset);
  tearDown(LicenseRegistry.reset);

  test('实际打包字体提供版权告知和完整 OFL 许可', () async {
    registerBundledFontLicense();
    final entry = await LicenseRegistry.licenses.single;
    expect(entry.packages, const ['Noto Sans SC']);
    final text = entry.paragraphs.map((paragraph) => paragraph.text).join('\n');
    expect(text, contains('2014-2021 Adobe'));
    expect(text, contains("Reserved Font Name 'Source'"));
    expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
    expect(text, contains('PERMISSION & CONDITIONS'));
    expect(text, contains('DISCLAIMER'));
  });

  for (final mode in ThemeMode.values) {
    testWidgets('${mode.name} 许可页在窄屏双倍文字下可阅读和返回', (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      registerBundledFontLicense();
      final captureKey = GlobalKey();
      var otherActionCalls = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _visualTheme(AppTheme.light, screenshotDirectory != null),
            darkTheme: _visualTheme(AppTheme.dark, screenshotDirectory != null),
            themeMode: mode,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: WorkspaceSettingsPage(
                isBusy: false,
                onPrivacy: () => otherActionCalls++,
                onAccount: () => otherActionCalls++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('第三方许可')));
      await tester.tap(find.byKey(const Key('第三方许可')));
      await tester.pump();
      // 许可页已订阅原收集器；在假时钟之外排空资产读取和流的完成事件。
      await tester.runAsync(() async {
        await LicenseRegistry.licenses.toList();
      });
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      expect(find.text('Noto Sans SC'), findsOneWidget);
      await _capture(
        tester,
        captureKey,
        screenshotDirectory,
        '${mode.name}-list',
      );
      await tester.tap(find.text('Noto Sans SC'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2014-2021 Adobe'), findsWidgets);
      await _capture(
        tester,
        captureKey,
        screenshotDirectory,
        '${mode.name}-notice',
      );
      await tester.scrollUntilVisible(
        find.textContaining('PERMISSION & CONDITIONS'),
        160,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 200,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('PERMISSION & CONDITIONS'), findsWidgets);
      await _capture(
        tester,
        captureKey,
        screenshotDirectory,
        '${mode.name}-terms',
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('第三方许可')), findsOneWidget);
      expect(otherActionCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

ThemeData _visualTheme(ThemeData base, bool enabled) => enabled
    ? base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: 'LicenseQaFont'),
        primaryTextTheme: base.primaryTextTheme.apply(
          fontFamily: 'LicenseQaFont',
        ),
        appBarTheme: base.appBarTheme.copyWith(
          titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
            fontFamily: 'LicenseQaFont',
          ),
        ),
      )
    : base;

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  String? directory,
  String name,
) async {
  if (directory == null) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$directory/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
