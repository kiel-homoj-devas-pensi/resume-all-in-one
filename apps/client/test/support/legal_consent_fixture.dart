import 'package:resume_all_in_one_client/src/legal_consent_controller.dart';
import 'package:resume_all_in_one_client/src/legal_consent_repository.dart';
import 'package:resume_all_in_one_client/src/legal_documents.dart';

/// Explicitly accepted synthetic legal revision for tests of unrelated features.
/// Production always loads its own bundled text and device-local decisions.
Future<LegalConsentController> acceptedLegalConsentFixture() async {
  final controller = LegalConsentController(
    repository: MemoryLegalConsentRepository(),
    loadBundle: () async => publishedLegalBundleFixture(),
    clock: () => DateTime.utc(2026, 10, 19, 8),
  );
  await controller.initialize();
  controller.markDocumentOpened('terms');
  controller.markDocumentOpened('privacy');
  if (!await controller.accept(
    adultConfirmed: true,
    termsChecked: true,
    privacyChecked: true,
  )) {
    throw StateError('合成协议准备失败');
  }
  return controller;
}

LegalBundle publishedLegalBundleFixture({
  String textSuffix = '',
  String status = 'published',
}) => LegalBundle.fromJson({
  'schemaVersion': 1,
  'bundleId': 'synthetic-legal-1',
  'status': status,
  'publishedAt': '2026-10-19T00:00:00Z',
  'effectiveAt': '2026-10-19T00:00:00Z',
  'operator': {
    'name': '合成测试运营者',
    'contactEmail': 'synthetic@example.invalid',
    'contactAddress': '合成地址',
  },
  'documents': [
    for (final id in ['terms', 'privacy'])
      {
        'id': id,
        'title': id == 'terms' ? '用户协议' : '隐私政策',
        'version': '1.0',
        'sections': [
          {
            'id': 'scope',
            'heading': '合成测试正文',
            'important': true,
            'paragraphs': ['仅供自动化测试的$id正文$textSuffix'],
          },
        ],
      },
  ],
  'pendingFields': <Map<String, dynamic>>[],
});

class MemoryLegalConsentRepository implements LegalConsentRepository {
  final entries = <LegalConsentEntry>[];
  bool failAppend = false;
  bool failLoad = false;
  bool failClear = false;
  @override
  Future<List<LegalConsentEntry>> load() async {
    if (failLoad) throw StateError('synthetic read failure');
    return List.of(entries);
  }

  @override
  Future<void> append(LegalConsentEntry entry) async {
    if (failAppend) throw StateError('synthetic write failure');
    entries.add(entry);
  }

  @override
  Future<void> clear() async {
    if (failClear) throw StateError('synthetic clear failure');
    entries.clear();
  }
}
