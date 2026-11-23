import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_storage/local_storage.dart';

/// 应用外观属于设备偏好，独立于简历编辑和领域事实。
final class AppThemeController extends ChangeNotifier {
  AppThemeController({required DriftAppSettingsRepository settingsRepository})
    : _settingsRepository = settingsRepository;

  final DriftAppSettingsRepository _settingsRepository;
  StreamSubscription<AppThemePreference>? _subscription;
  Future<void>? _initialization;
  Completer<void>? _initialRead;
  ThemeMode _mode = ThemeMode.system;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _disposed = false;
  String? _errorMessage;

  ThemeMode get mode => _mode;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  String? get errorMessage => _errorMessage;

  Future<void> initialize() => _initialization ??= _observePreference();

  Future<void> _observePreference() async {
    if (_disposed) return;
    final initialRead = _initialRead = Completer<void>();
    void finishInitialRead() {
      if (!initialRead.isCompleted) initialRead.complete();
    }

    try {
      _subscription = _settingsRepository.watchThemePreference().listen(
        (preference) {
          if (!_disposed) {
            _mode = switch (preference) {
              AppThemePreference.system => ThemeMode.system,
              AppThemePreference.light => ThemeMode.light,
              AppThemePreference.dark => ThemeMode.dark,
            };
            _isLoading = false;
            notifyListeners();
          }
          finishInitialRead();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!_disposed) {
            _isLoading = false;
            _errorMessage = '无法读取外观设置。请重新选择主题或重启应用。';
            notifyListeners();
          }
          finishInitialRead();
        },
        onDone: finishInitialRead,
      );
      await initialRead.future;
    } on Object {
      // Application 边界只提供当前操作的恢复提示，不暴露数据库或路径信息。
      if (!_disposed) {
        _isLoading = false;
        _errorMessage = '无法读取外观设置。请重新选择主题或重启应用。';
        notifyListeners();
      }
    }
  }

  Future<bool> setMode(ThemeMode mode) async {
    if (_disposed || _isLoading || _isSaving) return false;
    if (mode == _mode && _errorMessage == null) return true;
    _isSaving = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _settingsRepository.setThemePreference(switch (mode) {
        ThemeMode.system => AppThemePreference.system,
        ThemeMode.light => AppThemePreference.light,
        ThemeMode.dark => AppThemePreference.dark,
      });
      // 生效主题只来自已提交记录的监听；清空数据也走相同来源，避免写回默认值。
      return true;
    } on Object {
      if (!_disposed) {
        _errorMessage = '外观设置未能保存，已保留原来的主题。请重试。';
      }
      return false;
    } finally {
      if (!_disposed) {
        _isSaving = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final initialRead = _initialRead;
    if (initialRead != null && !initialRead.isCompleted) initialRead.complete();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }
}

final class AppThemeScope extends InheritedNotifier<AppThemeController> {
  const AppThemeScope({
    super.key,
    required AppThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppThemeController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AppThemeScope>()
        ?.notifier;
  }

  static AppThemeController of(BuildContext context) {
    final controller = maybeOf(context);
    assert(controller != null, 'AppThemeScope 必须位于 MaterialApp 之上。');
    return controller!;
  }
}
