import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'legal_consent_repository.dart';
import 'legal_documents.dart';

final class LegalConsentController extends ChangeNotifier {
  LegalConsentController({
    required LegalConsentRepository repository,
    Future<LegalBundle> Function()? loadBundle,
    DateTime Function()? clock,
  }) : _repository = repository,
       _loadBundle = loadBundle ?? _loadBundledDocuments,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final LegalConsentRepository _repository;
  final Future<LegalBundle> Function() _loadBundle;
  final DateTime Function() _clock;
  LegalBundle? bundle;
  List<LegalConsentEntry> _entries = const [];
  final Set<String> _opened = {};
  bool isLoading = true;
  bool isSaving = false;
  bool _historyUnavailable = false;
  bool _sessionBlocked = true;
  bool _continuedLocally = false;
  bool _disposed = false;
  bool _clearing = false;
  Completer<void>? _writeFinished;
  bool Function()? _networkPreferenceReader;
  String? errorMessage;

  List<LegalConsentRecord> get records =>
      List.unmodifiable(_entries.map((e) => e.record));
  LegalConsentRecord? get _last =>
      _entries.isEmpty ? null : _entries.last.record;

  bool get canUseRemoteServices =>
      !isLoading &&
      !isSaving &&
      !_clearing &&
      !_historyUnavailable &&
      !_sessionBlocked &&
      bundle?.isComplete == true &&
      _last?.bundleHash == bundle!.contentHash &&
      _last?.action == LegalConsentAction.accepted &&
      _last?.adultConfirmed == true;

  bool get canAcceptCurrentBundle =>
      !isLoading &&
      !isSaving &&
      !_clearing &&
      !_historyUnavailable &&
      bundle?.isComplete == true;

  void bindNetworkPreference(bool Function() read) =>
      _networkPreferenceReader = read;

  bool get canSendNetworkRequest =>
      canUseRemoteServices && (_networkPreferenceReader?.call() ?? true);

  bool get isCurrentReminderSuppressed =>
      _last?.bundleHash == bundle?.contentHash &&
      _last?.suppressReminder == true;

  bool get needsIntroduction =>
      !isLoading &&
      !_continuedLocally &&
      !canUseRemoteServices &&
      !isCurrentReminderSuppressed;

  String get blockedReason {
    if (isLoading) return '正在读取本机协议状态，请稍后重试。';
    if (bundle == null) return '协议文件暂不可读取；本地功能仍可使用。';
    if (!bundle!.isComplete) return '协议仍为待完善草案，运营信息尚未补齐；目前仅提供本地功能。';
    if (_historyUnavailable) return '本机协议记录不可读取；请在协议与隐私页面核对，本地功能仍可使用。';
    if (_last?.action == LegalConsentAction.accepted &&
        _last?.adultConfirmed != true) {
      return '联网账号及 AI 服务仅面向已满18周岁用户；请在“协议与隐私”中主动确认年龄并核对当前协议。本地功能仍可使用。';
    }
    return '请先在“协议与隐私”中阅读并明确同意当前版本，再使用联网功能。';
  }

  Future<void> initialize() async {
    if (isSaving) return;
    isLoading = true;
    _sessionBlocked = true;
    _opened.clear();
    errorMessage = null;
    _emit();
    try {
      bundle = await _loadBundle();
    } on Object {
      bundle = null;
      errorMessage = '协议文件读取失败；未开放新的联网操作，可继续使用本地功能。';
    }
    try {
      _entries = List.unmodifiable(await _repository.load());
      for (var i = 0; i < _entries.length; i++) {
        if (_entries[i].record.sequence != i + 1) throw const FormatException();
      }
      _historyUnavailable = false;
      _sessionBlocked = false;
    } on Object {
      _entries = const [];
      _historyUnavailable = true;
      errorMessage = '本机协议记录不可读取，未将旧偏好推定为同意；本地功能仍可使用。';
    }
    isLoading = false;
    _emit();
  }

  bool hasOpenedDocument(String id) => _opened.contains(id);
  void markDocumentOpened(String id) {
    if (bundle?.documents.any((doc) => doc.id == id) == true) {
      _opened.add(id);
      _emit();
    }
  }

  Future<bool> accept({
    required bool termsChecked,
    required bool privacyChecked,
    required bool adultConfirmed,
  }) async {
    if (!canAcceptCurrentBundle ||
        !termsChecked ||
        !privacyChecked ||
        !adultConfirmed ||
        !_opened.containsAll({'terms', 'privacy'})) {
      errorMessage = '请阅读两份完整定稿文件、分别确认同意，并主动确认已满18周岁；草案不能记录为已同意。';
      _emit();
      return false;
    }
    return _append(
      LegalConsentAction.accepted,
      suppressReminder: true,
      adultConfirmed: adultConfirmed,
    );
  }

  Future<bool> continueLocally({required bool suppressReminder}) async {
    if (isLoading || isSaving || _clearing) return false;
    _continuedLocally = true;
    _sessionBlocked = true;
    if (bundle != null && !_historyUnavailable) {
      await _append(
        LegalConsentAction.localOnly,
        suppressReminder: suppressReminder,
      );
    } else {
      _emit();
    }
    // Storage failures cannot hold the offline editor hostage. The error
    // remains visible in settings; a failed write never becomes consent.
    return true;
  }

  Future<bool> withdraw() async {
    if (isLoading || isSaving || _clearing) return false;
    _sessionBlocked = true;
    _continuedLocally = true;
    _emit();
    if (bundle == null || _historyUnavailable) {
      errorMessage = '本次已停止新的联网操作，但撤回记录暂不能保存，请检查存储后重试。';
      _emit();
      return false;
    }
    return _append(LegalConsentAction.withdrawn, suppressReminder: true);
  }

  Future<bool> _append(
    LegalConsentAction action, {
    required bool suppressReminder,
    bool adultConfirmed = false,
  }) async {
    isSaving = true;
    _writeFinished = Completer<void>();
    errorMessage = null;
    _emit();
    final entry = LegalConsentEntry(
      record: LegalConsentRecord(
        sequence: _entries.length + 1,
        action: action,
        bundleHash: bundle!.contentHash,
        recordedAtUtc: _clock().toUtc(),
        suppressReminder: suppressReminder,
        adultConfirmed: adultConfirmed,
      ),
      bundle: bundle!,
    );
    try {
      await _repository.append(entry);
      _entries = List.unmodifiable([..._entries, entry]);
      _sessionBlocked = action != LegalConsentAction.accepted;
      return true;
    } on Object {
      _sessionBlocked = true;
      errorMessage = '本机选择记录未能保存，本次新的联网操作保持关闭；“不再提醒”或撤回可能未持久保存，重启后请重新核对并重试。';
      return false;
    } finally {
      isSaving = false;
      _writeFinished!.complete();
      _writeFinished = null;
      _emit();
    }
  }

  Future<void> clearAllLocalRecords() async {
    _clearing = true;
    _sessionBlocked = true;
    _continuedLocally = true;
    _opened.clear();
    _emit();
    try {
      await _writeFinished?.future;
      await _repository.clear();
      _entries = const [];
      _historyUnavailable = false;
      errorMessage = null;
    } finally {
      _clearing = false;
      _sessionBlocked = true;
      _emit();
    }
  }

  LegalBundle? bundleForHash(String hash) {
    for (final entry in _entries.reversed) {
      if (entry.record.bundleHash == hash) return entry.bundle;
    }
    return bundle?.contentHash == hash ? bundle : null;
  }

  String exportRecordText() => const JsonEncoder.withIndent('  ').convert({
    'recordType': 'device-local-decisions-not-server-signatures',
    'timeSource': 'device clock; not trusted server time',
    'entries': _entries.map((entry) => entry.toJson()).toList(),
  });

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

Future<LegalBundle> _loadBundledDocuments() async => LegalBundle.fromJson(
  jsonDecode(await rootBundle.loadString('assets/legal/legal_bundle.json'))
      as Map<String, dynamic>,
);
