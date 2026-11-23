import 'dart:async';
import 'dart:io';

import 'package:local_storage/local_storage.dart';
import 'package:test/test.dart';

void main() {
  late LocalStorageDatabase database;
  late DriftAppSettingsRepository settingsRepository;
  Directory? persistentTestDirectory;

  setUp(() {
    persistentTestDirectory = null;
    database = LocalStorageDatabase.inMemory();
    settingsRepository = DriftAppSettingsRepository(database);
  });

  tearDown(() async {
    await database.close();
    await persistentTestDirectory?.delete(recursive: true);
  });

  for (final previousChoice in <bool?>[null, false, true]) {
    test('旧库联网选择 $previousChoice 重启后保持且不会初始化上传同意', () async {
      final directory = persistentTestDirectory = await Directory.systemTemp
          .createTemp('resume-network-');
      final file = File('${directory.path}/settings.sqlite');
      await database.close();
      database = LocalStorageDatabase.openFile(file);
      final oldSettings = DriftAppSettingsRepository(database);
      if (previousChoice == null) {
        await database.customStatement('DELETE FROM app_settings');
      } else {
        await oldSettings.setNetworkEnabled(previousChoice);
      }
      await database.close();
      database = LocalStorageDatabase.openFile(file);
      final reopened = DriftAppSettingsRepository(database);
      expect(await reopened.getNetworkEnabled(), previousChoice ?? false);
      expect(
        await reopened.getRemotePersonalDataWarningAcknowledged(),
        isFalse,
      );
      expect(
        (await DriftLocalDataRepository(database).readSnapshot()).settings,
        hasLength(previousChoice == null ? 0 : 1),
      );
    });
  }

  test('新库默认值重启保留，清空后重启仍关闭联网且无上传确认', () async {
    final directory = persistentTestDirectory = await Directory.systemTemp
        .createTemp('resume-fresh-network-');
    final file = File('${directory.path}/settings.sqlite');
    await database.close();
    database = LocalStorageDatabase.openFile(file);
    expect(
      await DriftAppSettingsRepository(database).getNetworkEnabled(),
      isTrue,
    );
    await database.close();
    database = LocalStorageDatabase.openFile(file);
    expect(
      await DriftAppSettingsRepository(database).getNetworkEnabled(),
      isTrue,
    );
    await DriftAppSettingsRepository(
      database,
    ).setRemotePersonalDataWarningAcknowledged(true);
    await DriftLocalDataRepository(database).clearAll();
    await database.close();
    database = LocalStorageDatabase.openFile(file);
    final cleared = DriftAppSettingsRepository(database);
    expect(await cleared.getNetworkEnabled(), isFalse);
    expect(await cleared.getRemotePersonalDataWarningAcknowledged(), isFalse);
  });

  test('联网偏好写入失败保留已存选择及未确认隐私状态', () async {
    expect(await settingsRepository.getNetworkEnabled(), isTrue);
    await database.customStatement('''
      CREATE TRIGGER reject_network_write BEFORE INSERT ON app_settings
      WHEN NEW.setting_key = 'network_enabled'
      BEGIN SELECT RAISE(ABORT, 'network write unavailable'); END;
    ''');
    await expectLater(
      settingsRepository.setNetworkEnabled(false),
      throwsA(isA<Exception>()),
    );
    expect(await settingsRepository.getNetworkEnabled(), isTrue);
    expect(
      await settingsRepository.getRemotePersonalDataWarningAcknowledged(),
      isFalse,
    );
  });

  test('新库允许主动联网而个人信息提醒仍未确认', () async {
    expect(await settingsRepository.getNetworkEnabled(), isTrue);
    expect(
      await settingsRepository.getRemotePersonalDataWarningAcknowledged(),
      isFalse,
    );

    await settingsRepository.setNetworkEnabled(true);

    expect(await settingsRepository.getNetworkEnabled(), isTrue);
    expect(
      await settingsRepository.getRemotePersonalDataWarningAcknowledged(),
      isFalse,
    );

    await settingsRepository.setRemotePersonalDataWarningAcknowledged(true);

    expect(await settingsRepository.getNetworkEnabled(), isTrue);
    expect(
      await settingsRepository.getRemotePersonalDataWarningAcknowledged(),
      isTrue,
    );
  });

  test('撤销已阅读状态不会关闭联网偏好', () async {
    await settingsRepository.setNetworkEnabled(true);
    await settingsRepository.setRemotePersonalDataWarningAcknowledged(true);

    await settingsRepository.setRemotePersonalDataWarningAcknowledged(false);

    expect(await settingsRepository.getNetworkEnabled(), isTrue);
    expect(
      await settingsRepository.getRemotePersonalDataWarningAcknowledged(),
      isFalse,
    );
  });

  test('没有外观记录或只有一半记录时跟随系统且不补写默认设置', () async {
    await database.customStatement('DELETE FROM app_settings');
    expect(
      await settingsRepository.getThemePreference(),
      AppThemePreference.system,
    );
    expect(
      (await DriftLocalDataRepository(database).readSnapshot()).settings,
      isEmpty,
    );

    await database.customStatement(
      'INSERT INTO app_settings (setting_key, bool_value, updated_at) '
      "VALUES ('theme_override_enabled', 1, 0)",
    );
    expect(
      await settingsRepository.getThemePreference(),
      AppThemePreference.system,
    );
    expect(
      (await DriftLocalDataRepository(database).readSnapshot()).settings,
      hasLength(1),
    );
  });

  test('外观记录只保存深色位或关闭覆盖位时仍然跟随系统', () async {
    await database.customStatement(
      'INSERT INTO app_settings (setting_key, bool_value, updated_at) '
      "VALUES ('theme_dark_enabled', 1, 0)",
    );
    expect(
      await settingsRepository.getThemePreference(),
      AppThemePreference.system,
    );

    await database.customStatement(
      'INSERT INTO app_settings (setting_key, bool_value, updated_at) '
      "VALUES ('theme_override_enabled', 0, 0)",
    );
    expect(
      await settingsRepository.getThemePreference(),
      AppThemePreference.system,
    );
  });

  test('外观双键使用同一更新时间且不会改变隐私偏好', () async {
    var clockReads = 0;
    final selectedAt = DateTime.utc(2026, 10, 5, 9, 30);
    final appearanceRepository = DriftAppSettingsRepository(
      database,
      clock: () {
        clockReads++;
        return selectedAt;
      },
    );
    await settingsRepository.setNetworkEnabled(true);
    await settingsRepository.setRemotePersonalDataWarningAcknowledged(true);

    await appearanceRepository.setThemePreference(AppThemePreference.dark);

    final snapshot = await DriftLocalDataRepository(database).readSnapshot();
    final themeSettings = snapshot.settings.where(
      (setting) => setting.key.startsWith('theme_'),
    );
    expect(themeSettings, hasLength(2));
    expect(themeSettings.every((setting) => setting.value), isTrue);
    expect(
      themeSettings.every((setting) => setting.updatedAtUtc == selectedAt),
      isTrue,
    );
    expect(clockReads, 1);
    expect(await settingsRepository.getNetworkEnabled(), isTrue);
    expect(
      await settingsRepository.getRemotePersonalDataWarningAcknowledged(),
      isTrue,
    );
    expect(snapshot.storageSchemaVersion, 4);
  });

  for (final preference in AppThemePreference.values) {
    test('选择 ${preference.name} 后重启文件数据库仍保留外观', () async {
      final testDirectory = persistentTestDirectory = await Directory.systemTemp
          .createTemp('resume-theme-');
      final databaseFile = File('${testDirectory.path}/settings.sqlite');
      await database.close();
      database = LocalStorageDatabase.openFile(databaseFile);
      await DriftAppSettingsRepository(database).setThemePreference(preference);
      await database.close();
      database = LocalStorageDatabase.openFile(databaseFile);

      expect(
        await DriftAppSettingsRepository(database).getThemePreference(),
        preference,
      );
      expect(
        (await DriftLocalDataRepository(database).readSnapshot()).settings,
        hasLength(3),
      );
    });
  }

  test('第二个主题键写入失败时第一个键一起回滚', () async {
    await settingsRepository.setThemePreference(AppThemePreference.system);
    await database.customStatement('''
      CREATE TRIGGER reject_theme_write BEFORE INSERT ON app_settings
      WHEN NEW.setting_key = 'theme_dark_enabled'
      BEGIN SELECT RAISE(ABORT, 'theme write unavailable'); END;
    ''');

    await expectLater(
      settingsRepository.setThemePreference(AppThemePreference.dark),
      throwsA(isA<Exception>()),
    );

    expect(
      await settingsRepository.getThemePreference(),
      AppThemePreference.system,
    );
    final snapshot = await DriftLocalDataRepository(database).readSnapshot();
    expect(snapshot.settings, hasLength(3));
    expect(
      snapshot.settings
          .where((setting) => setting.key.startsWith('theme_'))
          .every((setting) => !setting.value),
      isTrue,
    );
  });

  test('观察者只接收完整主题且清空后恢复系统而不重新写入设置', () async {
    final preferences = StreamIterator(
      settingsRepository.watchThemePreference(),
    );
    addTearDown(preferences.cancel);
    expect(await preferences.moveNext(), isTrue);
    expect(preferences.current, AppThemePreference.system);

    final nextDark = preferences.moveNext();
    await settingsRepository.setThemePreference(AppThemePreference.dark);
    expect(await nextDark, isTrue);
    expect(preferences.current, AppThemePreference.dark);

    final nextLight = preferences.moveNext();
    await settingsRepository.setThemePreference(AppThemePreference.light);
    expect(await nextLight, isTrue);
    expect(preferences.current, AppThemePreference.light);

    final nextSystem = preferences.moveNext();
    final clearResult = await DriftLocalDataRepository(database).clearAll();
    expect(await nextSystem, isTrue);
    expect(preferences.current, AppThemePreference.system);
    expect(clearResult.settingCount, 3);
    expect(
      (await DriftLocalDataRepository(database).readSnapshot()).settings,
      isEmpty,
    );
  });
}
