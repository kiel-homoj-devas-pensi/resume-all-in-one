import 'package:drift/drift.dart';

import 'database.dart';

const _networkEnabledKey = 'network_enabled';
const _remotePersonalDataWarningAcknowledgedKey =
    'remote_personal_data_warning_acknowledged';
const _themeOverrideEnabledKey = 'theme_override_enabled';
const _themeDarkEnabledKey = 'theme_dark_enabled';

enum AppThemePreference { system, light, dark }

final class DriftAppSettingsRepository {
  DriftAppSettingsRepository(this._database, {DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  final LocalStorageDatabase _database;
  final DateTime Function() _clock;

  Future<AppThemePreference> getThemePreference() async {
    return _decodeThemePreference(await _themeSettingsQuery().get());
  }

  Stream<AppThemePreference> watchThemePreference() {
    return _themeSettingsQuery().watch().map(_decodeThemePreference).distinct();
  }

  Future<void> setThemePreference(AppThemePreference preference) {
    return _database.transaction(() async {
      // 保留 schema v3 的布尔设置和导出契约；两个键是一项偏好，必须一起提交。
      final updatedAt = _clock().toUtc();
      await _writeBooleanSetting(
        _themeOverrideEnabledKey,
        preference != AppThemePreference.system,
        updatedAt: updatedAt,
      );
      await _writeBooleanSetting(
        _themeDarkEnabledKey,
        preference == AppThemePreference.dark,
        updatedAt: updatedAt,
      );
    });
  }

  Selectable<AppSettingRow> _themeSettingsQuery() {
    return _database.select(_database.appSettings)..where(
      (setting) => setting.settingKey.isIn([
        _themeOverrideEnabledKey,
        _themeDarkEnabledKey,
      ]),
    );
  }

  AppThemePreference _decodeThemePreference(List<AppSettingRow> settings) {
    final themeValues = {
      for (final setting in settings) setting.settingKey: setting.boolValue,
    };
    // 不完整的旧记录没有足够信息表达显式选择，回退系统且不擅自补写。
    if (themeValues.length != 2 ||
        themeValues[_themeOverrideEnabledKey] != true) {
      return AppThemePreference.system;
    }
    return themeValues[_themeDarkEnabledKey] == true
        ? AppThemePreference.dark
        : AppThemePreference.light;
  }

  Future<bool> getNetworkEnabled() => _readBooleanSetting(_networkEnabledKey);

  Future<void> setNetworkEnabled(bool enabled) {
    return _writeBooleanSetting(_networkEnabledKey, enabled);
  }

  Future<bool> getRemotePersonalDataWarningAcknowledged() {
    return _readBooleanSetting(_remotePersonalDataWarningAcknowledgedKey);
  }

  Future<void> setRemotePersonalDataWarningAcknowledged(bool acknowledged) {
    return _writeBooleanSetting(
      _remotePersonalDataWarningAcknowledgedKey,
      acknowledged,
    );
  }

  Future<bool> _readBooleanSetting(String settingKey) async {
    final row = await (_database.select(
      _database.appSettings,
    )..where((table) => table.settingKey.equals(settingKey))).getSingleOrNull();
    return row?.boolValue ?? false;
  }

  Future<void> _writeBooleanSetting(
    String settingKey,
    bool boolValue, {
    DateTime? updatedAt,
  }) {
    return _database
        .into(_database.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            settingKey: settingKey,
            boolValue: boolValue,
            updatedAt: updatedAt ?? _clock().toUtc(),
          ),
        );
  }
}

DateTime _utcNow() => DateTime.now().toUtc();
