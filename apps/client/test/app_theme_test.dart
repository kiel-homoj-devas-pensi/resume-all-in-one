import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/app_theme.dart';
import 'package:resume_all_in_one_client/src/app_theme_controller.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';

void main() {
  late LocalStorageDatabase database;
  late DriftAppSettingsRepository settingsRepository;
  late AppThemeController controller;

  setUp(() {
    database = LocalStorageDatabase.inMemory();
    settingsRepository = DriftAppSettingsRepository(database);
    controller = AppThemeController(settingsRepository: settingsRepository);
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  test('启动读取已保存主题且连续切换只接受一个进行中的保存', () async {
    await settingsRepository.setThemePreference(AppThemePreference.light);
    await controller.initialize();
    expect(controller.mode, ThemeMode.light);
    expect(controller.isLoading, isFalse);

    final darkSaved = controller.setMode(ThemeMode.dark);
    expect(controller.isSaving, isTrue);
    expect(await controller.setMode(ThemeMode.system), isFalse);
    expect(await darkSaved, isTrue);
    await _waitForMode(controller, ThemeMode.dark);
    expect(controller.isSaving, isFalse);
    expect(controller.errorMessage, isNull);
    expect(
      await settingsRepository.getThemePreference(),
      AppThemePreference.dark,
    );
  });

  test('主题保存失败保留当前外观并提供脱敏反馈且允许重试', () async {
    await controller.initialize();
    await database.customStatement('''
      CREATE TRIGGER reject_theme_write BEFORE INSERT ON app_settings
      WHEN NEW.setting_key = 'theme_dark_enabled'
      BEGIN SELECT RAISE(ABORT, 'sensitive test path'); END;
    ''');

    expect(await controller.setMode(ThemeMode.dark), isFalse);
    expect(controller.mode, ThemeMode.system);
    expect(controller.isSaving, isFalse);
    expect(controller.errorMessage, contains('外观设置未能保存'));
    expect(controller.errorMessage, isNot(contains('sensitive')));
    expect(
      (await DriftLocalDataRepository(database).readSnapshot()).settings,
      hasLength(1),
    );

    await database.customStatement('DROP TRIGGER reject_theme_write');
    expect(await controller.setMode(ThemeMode.dark), isTrue);
    await _waitForMode(controller, ThemeMode.dark);
    expect(controller.errorMessage, isNull);
  });

  test('外观记录暂时无法读取时应用仍可启动并能在存储恢复后重试', () async {
    await database.customStatement(
      'ALTER TABLE app_settings RENAME TO unavailable_settings',
    );

    await controller.initialize();

    expect(controller.mode, ThemeMode.system);
    expect(controller.isLoading, isFalse);
    expect(controller.errorMessage, contains('无法读取外观设置'));
    expect(controller.errorMessage, isNot(contains('unavailable_settings')));
    await database.customStatement(
      'ALTER TABLE unavailable_settings RENAME TO app_settings',
    );
    expect(await controller.setMode(ThemeMode.dark), isTrue);
    await _waitForMode(controller, ThemeMode.dark);
    expect(controller.errorMessage, isNull);
  });

  test('全量导出包含双键外观且清空后当前 Controller 自动恢复跟随系统', () async {
    await controller.initialize();
    await controller.setMode(ThemeMode.dark);
    await _waitForMode(controller, ThemeMode.dark);
    final snapshot = await DriftLocalDataRepository(database).readSnapshot();
    const codec = LocalDataArchiveCodec();
    final archiveText = codec.encode(snapshot, DateTime.utc(2026, 10, 5));
    final archiveSummary = codec.decode(archiveText);
    final archive = jsonDecode(archiveText) as Map<String, dynamic>;
    expect(archive['exportFormatVersion'], '0.1.0');
    expect(archive['storageSchemaVersion'], 4);
    expect(archiveSummary.settingCount, 3);
    expect(archive['settings'], [
      containsPair('key', 'network_enabled'),
      containsPair('key', 'theme_dark_enabled'),
      containsPair('key', 'theme_override_enabled'),
    ]);

    await DriftLocalDataRepository(database).clearAll();
    await _waitForMode(controller, ThemeMode.system);
    expect(
      (await DriftLocalDataRepository(database).readSnapshot()).settings,
      isEmpty,
    );
  });

  test('释放时完成仍在等待的初始化且晚到事件不再通知界面', () async {
    final temporaryController = AppThemeController(
      settingsRepository: settingsRepository,
    );
    var notifications = 0;
    temporaryController.addListener(() => notifications++);
    final initialization = temporaryController.initialize();
    temporaryController.dispose();

    await initialization;
    await settingsRepository.setThemePreference(AppThemePreference.dark);
    expect(notifications, 0);
    expect(await temporaryController.setMode(ThemeMode.light), isFalse);
  });

  test('保存进行中离开应用不会向已释放的 Controller 发出通知', () async {
    final temporaryController = AppThemeController(
      settingsRepository: settingsRepository,
    );
    await temporaryController.initialize();
    final transactionEntered = Completer<void>();
    final releaseTransaction = Completer<void>();
    final blockingTransaction = database.transaction(() async {
      transactionEntered.complete();
      await releaseTransaction.future;
    });
    await transactionEntered.future;
    final save = temporaryController.setMode(ThemeMode.dark);
    expect(temporaryController.isSaving, isTrue);
    temporaryController.dispose();
    releaseTransaction.complete();

    await blockingTransaction;
    expect(await save, isTrue);
    expect(
      await settingsRepository.getThemePreference(),
      AppThemePreference.dark,
    );
  });

  for (final entry in {'浅色': AppTheme.light, '深色': AppTheme.dark}.entries) {
    test('${entry.key}正文与强调文案在对应容器上满足 4.5 比 1 对比度', () {
      final colors = entry.value.colorScheme;
      final foregroundBackgroundPairs = <(Color, Color)>[
        (colors.onPrimary, colors.primary),
        (colors.onPrimaryContainer, colors.primaryContainer),
        (colors.onSecondary, colors.secondary),
        (colors.onSecondaryContainer, colors.secondaryContainer),
        (colors.onTertiary, colors.tertiary),
        (colors.onTertiaryContainer, colors.tertiaryContainer),
        (colors.onError, colors.error),
        (colors.onErrorContainer, colors.errorContainer),
        (colors.onInverseSurface, colors.inverseSurface),
        (colors.inversePrimary, colors.inverseSurface),
        for (final surface in [
          colors.surface,
          colors.surfaceContainerLowest,
          colors.surfaceContainerLow,
          colors.surfaceContainer,
          colors.surfaceContainerHigh,
          colors.surfaceContainerHighest,
        ]) ...[
          (colors.onSurface, surface),
          (colors.onSurfaceVariant, surface),
          (colors.primary, surface),
          (colors.error, surface),
        ],
      ];
      for (final (foreground, background) in foregroundBackgroundPairs) {
        final foregroundLuminance = foreground.computeLuminance();
        final backgroundLuminance = background.computeLuminance();
        final contrast =
            (max(foregroundLuminance, backgroundLuminance) + 0.05) /
            (min(foregroundLuminance, backgroundLuminance) + 0.05);
        expect(
          contrast,
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} $foreground / $background 的文字对比度不足',
        );
      }
    });
  }

  testWidgets('跟随系统实时响应亮度变化而显式选择保持用户偏好', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.runAsync(controller.initialize);
    await tester.pumpWidget(_ThemeHarness(controller: controller));
    await tester.pumpAndSettle();
    expect(_currentBrightness(tester), Brightness.light);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(_currentBrightness(tester), Brightness.dark);

    await tester.runAsync(() async {
      await controller.setMode(ThemeMode.light);
      await _waitForMode(controller, ThemeMode.light);
    });
    await tester.pumpAndSettle();
    expect(_currentBrightness(tester), Brightness.light);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await controller.setMode(ThemeMode.dark);
      await _waitForMode(controller, ThemeMode.dark);
    });
    await tester.pumpAndSettle();
    expect(_currentBrightness(tester), Brightness.dark);

    await tester.runAsync(() async {
      await controller.setMode(ThemeMode.system);
      await _waitForMode(controller, ThemeMode.system);
    });
    await tester.pumpAndSettle();
    expect(_currentBrightness(tester), Brightness.light);
  });

  testWidgets('打开的弹层与编辑内容在切换主题后保留且可访问同一外观状态', (tester) async {
    await tester.runAsync(controller.initialize);
    await tester.pumpWidget(_ThemeHarness(controller: controller));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '尚未保存的简历标题');
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();

    final dialogContext = tester.element(find.byType(AlertDialog));
    expect(AppThemeScope.of(dialogContext), same(controller));
    await tester.runAsync(() async {
      await controller.setMode(ThemeMode.dark);
      await _waitForMode(controller, ThemeMode.dark);
    });
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(Theme.of(dialogContext).brightness, Brightness.dark);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('尚未保存的简历标题'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _waitForMode(
  AppThemeController controller,
  ThemeMode expected,
) async {
  if (controller.mode == expected) return;
  final updated = Completer<void>();
  void onThemeChanged() {
    if (controller.mode == expected && !updated.isCompleted) updated.complete();
  }

  controller.addListener(onThemeChanged);
  try {
    await updated.future.timeout(const Duration(seconds: 5));
  } finally {
    controller.removeListener(onThemeChanged);
  }
}

Brightness _currentBrightness(WidgetTester tester) {
  return Theme.of(tester.element(find.byType(Scaffold).first)).brightness;
}

final class _ThemeHarness extends StatelessWidget {
  const _ThemeHarness({required this.controller});

  final AppThemeController controller;

  @override
  Widget build(BuildContext context) {
    return AppThemeScope(
      controller: controller,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, child) => MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: controller.mode,
          home: child,
        ),
        child: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const TextField(),
                FilledButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('外观'),
                      content: const Text('切换主题不会丢失输入'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('打开设置'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
