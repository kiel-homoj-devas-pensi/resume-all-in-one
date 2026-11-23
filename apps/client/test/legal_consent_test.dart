import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/legal_consent_controller.dart';
import 'package:resume_all_in_one_client/src/legal_consent_repository.dart';
import 'package:resume_all_in_one_client/src/legal_documents.dart';
import 'package:resume_all_in_one_client/src/legal_gateway_transport.dart';

import 'support/legal_consent_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LegalConsentController> create(
    LegalConsentRepository repository, {
    LegalBundle? bundle,
  }) async {
    final controller = LegalConsentController(
      repository: repository,
      loadBundle: () async => bundle ?? publishedLegalBundleFixture(),
      clock: () => DateTime.utc(2026, 10, 19, 8),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    return controller;
  }

  Future<void> accept(LegalConsentController controller) async {
    controller.markDocumentOpened('terms');
    controller.markDocumentOpened('privacy');
    expect(
      await controller.accept(
        adultConfirmed: true,
        termsChecked: true,
        privacyChecked: true,
      ),
      isTrue,
    );
  }

  test('未声明年龄或历史缺少年龄字段时，最终HTTP门禁均拒绝', () async {
    final repository = MemoryLegalConsentRepository();
    final controller = await create(repository);
    controller.markDocumentOpened('terms');
    controller.markDocumentOpened('privacy');
    expect(
      await controller.accept(
        termsChecked: true,
        privacyChecked: true,
        adultConfirmed: false,
      ),
      isFalse,
    );
    expect(repository.entries, isEmpty);
    final blockedTransport = _CountingTransport();
    final gated = LegalGatewayHttpTransport(
      transport: blockedTransport,
      legalConsent: controller,
    );
    expect(
      () => gated.sendJson(
        method: 'POST',
        uri: Uri.https('synthetic.invalid', '/v1/guest-sessions'),
        headers: {},
      ),
      throwsA(isA<GatewayApiException>()),
    );
    expect(blockedTransport.sent, 0);
    await accept(controller);
    final serialized = repository.entries.single.toJson();
    (serialized['record'] as Map).remove('adultConfirmed');
    repository.entries[0] = LegalConsentEntry.fromJson(serialized);
    final legacy = await create(repository);
    expect(legacy.records.single.action, LegalConsentAction.accepted);
    expect(legacy.records.single.adultConfirmed, isFalse);
    expect(legacy.canSendNetworkRequest, isFalse);
    expect(legacy.blockedReason, contains('18周岁'));
    legacy.markDocumentOpened('terms');
    legacy.markDocumentOpened('privacy');
    expect(
      await legacy.accept(
        termsChecked: true,
        privacyChecked: true,
        adultConfirmed: true,
      ),
      isTrue,
    );
    final restarted = await create(repository);
    expect(restarted.canUseRemoteServices, isTrue);
    expect(restarted.needsIntroduction, isFalse);
    await restarted.clearAllLocalRecords();
    expect((await create(repository)).canUseRemoteServices, isFalse);
  });

  test('定稿可在计划发行前明确同意，未同意仍只允许本地', () async {
    final repository = MemoryLegalConsentRepository();
    final controller = LegalConsentController(
      repository: repository,
      clock: () => DateTime.utc(2026, 10, 22, 8),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.bundle, isNotNull);
    expect(controller.bundle!.status, 'final');
    expect(controller.bundle!.isComplete, isTrue);
    expect(controller.bundle!.pendingFields, isEmpty);
    expect(controller.canAcceptCurrentBundle, isTrue);
    expect(controller.canUseRemoteServices, isFalse);
    // Complete text and date labels do not silently grant consent.
    expect(
      await controller.accept(
        adultConfirmed: true,
        termsChecked: true,
        privacyChecked: true,
      ),
      isFalse,
    );
    expect(repository.entries, isEmpty);
    expect(await controller.continueLocally(suppressReminder: true), isTrue);
    expect(controller.canUseRemoteServices, isFalse);
    expect(controller.needsIntroduction, isFalse);
    expect(
      repository.entries.single.record.action,
      LegalConsentAction.localOnly,
    );
    await accept(controller);
    expect(controller.canUseRemoteServices, isTrue);
    expect(
      repository.entries.last.record.recordedAtUtc,
      DateTime.utc(2026, 10, 22, 8),
    );
  });

  test('计划日期不作联网授权，阅读年龄同意持久化后才可用，跨年不重置', () async {
    final json = publishedLegalBundleFixture(status: 'final').toJson();
    json['publishedAt'] = '2027-01-01T00:00:00+08:00';
    json['effectiveAt'] = '2027-01-01T00:00:00+08:00';
    final bundle = LegalBundle.fromJson(json);
    var now = DateTime.utc(2026, 10, 22, 8);
    final repository = MemoryLegalConsentRepository();
    final controller = LegalConsentController(
      repository: repository,
      loadBundle: () async => bundle,
      clock: () => now,
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.canAcceptCurrentBundle, isTrue);
    expect(controller.canSendNetworkRequest, isFalse);
    controller.markDocumentOpened('terms');
    controller.markDocumentOpened('privacy');
    expect(
      await controller.accept(
        termsChecked: true,
        privacyChecked: true,
        adultConfirmed: false,
      ),
      isFalse,
    );
    await accept(controller);
    expect(controller.canUseRemoteServices, isTrue);
    expect(
      controller.records.single.recordedAtUtc,
      DateTime.utc(2026, 10, 22, 8),
    );
    now = DateTime.utc(2027, 1, 1);
    expect(controller.canUseRemoteServices, isTrue);
    final restarted = LegalConsentController(
      repository: repository,
      loadBundle: () async => bundle,
      clock: () => now,
    );
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.canUseRemoteServices, isTrue);
    expect(restarted.needsIntroduction, isFalse);
  });

  test('定稿标签不能绕过缺失资料、未读文本或损坏状态', () async {
    final json = publishedLegalBundleFixture(status: 'final').toJson();
    json['pendingFields'] = [
      {'key': 'test.missing', 'label': '合成缺口', 'reason': 'test'},
    ];
    final incomplete = await create(
      MemoryLegalConsentRepository(),
      bundle: LegalBundle.fromJson(json),
    );
    expect(incomplete.bundle!.isComplete, isFalse);
    expect(incomplete.canAcceptCurrentBundle, isFalse);
    final unread = await create(
      MemoryLegalConsentRepository(),
      bundle: publishedLegalBundleFixture(status: 'final'),
    );
    expect(
      await unread.accept(
        termsChecked: true,
        privacyChecked: true,
        adultConfirmed: true,
      ),
      isFalse,
    );
    expect(unread.records, isEmpty);
  });

  test('明确打开两份及分别勾选后，成功落盘才获得当前版本联网权限', () async {
    final repository = MemoryLegalConsentRepository();
    final controller = await create(repository);
    expect(
      await controller.accept(
        adultConfirmed: true,
        termsChecked: true,
        privacyChecked: true,
      ),
      isFalse,
    );
    controller.markDocumentOpened('terms');
    controller.markDocumentOpened('privacy');
    expect(
      await controller.accept(
        adultConfirmed: true,
        termsChecked: true,
        privacyChecked: false,
      ),
      isFalse,
    );
    expect(controller.canUseRemoteServices, isFalse);
    expect(repository.entries, isEmpty);
    await accept(controller);
    expect(controller.canUseRemoteServices, isTrue);
    expect(controller.needsIntroduction, isFalse);
    expect(
      controller.records.single.bundleHash,
      controller.bundle!.contentHash,
    );
    expect(
      controller.records.single.recordedAtUtc,
      DateTime.utc(2026, 10, 19, 8),
    );
    final restarted = await create(repository);
    expect(restarted.needsIntroduction, isFalse);
    expect(restarted.canUseRemoteServices, isTrue);
  });

  test('不再提醒独立于同意；相同标签但正文变化也必须重新选择', () async {
    final repository = MemoryLegalConsentRepository();
    final controller = await create(repository);
    await controller.continueLocally(suppressReminder: true);
    final restarted = await create(repository);
    expect(restarted.canUseRemoteServices, isFalse);
    expect(restarted.needsIntroduction, isFalse);
    final changed = await create(
      repository,
      bundle: publishedLegalBundleFixture(textSuffix: '修改'),
    );
    expect(changed.canUseRemoteServices, isFalse);
    expect(changed.needsIntroduction, isTrue);
    expect(
      changed
          .bundleForHash(controller.bundle!.contentHash)!
          .documents
          .first
          .plainText(controller.bundle!),
      contains('terms正文'),
    );
    expect(
      changed
          .bundleForHash(controller.bundle!.contentHash)!
          .documents
          .first
          .plainText(controller.bundle!),
      isNot(contains('修改')),
    );
  });

  test('已同意的旧内容不能自动授权更新后的同版本文本', () async {
    final repository = MemoryLegalConsentRepository();
    final controller = await create(repository);
    await accept(controller);
    final changed = await create(
      repository,
      bundle: publishedLegalBundleFixture(textSuffix: '更新'),
    );
    expect(changed.needsIntroduction, isTrue);
    expect(changed.canUseRemoteServices, isFalse);
    expect(changed.records.single.action, LegalConsentAction.accepted);
    expect(changed.exportRecordText(), contains('device clock'));
  });

  test('本地选择未勾不再提醒时，下次启动仍提示且不产生同意', () async {
    final repository = MemoryLegalConsentRepository();
    await (await create(repository)).continueLocally(suppressReminder: false);
    final restarted = await create(repository);
    expect(restarted.needsIntroduction, isTrue);
    expect(restarted.canUseRemoteServices, isFalse);
  });

  test('选择保存失败不假成功同意，本地使用仍可进入且错误保留', () async {
    final repository = MemoryLegalConsentRepository()..failAppend = true;
    final controller = await create(repository);
    controller.markDocumentOpened('terms');
    controller.markDocumentOpened('privacy');
    expect(
      await controller.accept(
        adultConfirmed: true,
        termsChecked: true,
        privacyChecked: true,
      ),
      isFalse,
    );
    expect(controller.isSaving, isFalse);
    expect(controller.records, isEmpty);
    expect(controller.canUseRemoteServices, isFalse);
    expect(await controller.continueLocally(suppressReminder: true), isTrue);
    expect(controller.errorMessage, contains('未能保存'));
    expect(controller.errorMessage, isNot(contains('synthetic write failure')));
  });

  test('撤回立即阻止新请求，已经发送的响应仍按实际返回；重启保持撤回', () async {
    final repository = MemoryLegalConsentRepository();
    final controller = await create(repository);
    await accept(controller);
    final transport = _CountingTransport();
    final gated = LegalGatewayHttpTransport(
      transport: transport,
      legalConsent: controller,
    );
    final alreadySent = gated.sendJson(
      method: 'POST',
      uri: Uri.https('synthetic.invalid', '/v1/resume-ai/requests'),
      headers: {},
    );
    final withdrawal = controller.withdraw();
    expect(controller.canUseRemoteServices, isFalse);
    for (final route in [
      '/v2/account/options',
      '/v2/account-verifications',
      '/v1/guest-sessions',
      '/v1/resume-ai/operations/original',
      '/v1/cloud-resumes/options',
    ]) {
      expect(
        () => gated.sendJson(
          method: 'GET',
          uri: Uri.https('synthetic.invalid', route),
          headers: {},
        ),
        throwsA(isA<GatewayApiException>()),
      );
    }
    expect(transport.sent, 1);
    transport.result.complete(
      GatewayHttpResponse(
        statusCode: 200,
        bodyBytes: Uint8List.fromList(utf8.encode('{}')),
      ),
    );
    expect((await alreadySent).statusCode, 200);
    expect(await withdrawal, isTrue);
    final restarted = await create(repository);
    expect(restarted.canUseRemoteServices, isFalse);
    expect(restarted.needsIntroduction, isFalse);
    expect(restarted.records.last.action, LegalConsentAction.withdrawn);
  });

  test('读取记录失败不回退为历史允许；正文仍可读，本地仍可进入', () async {
    final repository = MemoryLegalConsentRepository()..failLoad = true;
    final controller = await create(repository);
    expect(controller.canUseRemoteServices, isFalse);
    expect(controller.bundle!.documents, hasLength(2));
    expect(await controller.continueLocally(suppressReminder: true), isTrue);
    expect(controller.errorMessage, contains('不可读取'));
  });

  test('伪改published状态不足以跳过运营者、待填、占位或生效日期核验', () async {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (v) => (v['operator'] as Map)['name'] = null,
      (v) => v['pendingFields'] = [
        {'key': 'retention', 'label': '保存期限', 'reason': '待核'},
      ],
      (v) =>
          (((v['documents'] as List).first as Map)['sections'] as List)
              .first['paragraphs'] = [
            '{{operator.name}}未替换',
          ],
      (v) => v['effectiveAt'] = 'invalid-date',
      (v) => v['effectiveAt'] = '2026-10-18T00:00:00Z',
      (v) => v['publishedAt'] = null,
    ]) {
      final value = publishedLegalBundleFixture().toJson();
      mutate(value);
      final controller = await create(
        MemoryLegalConsentRepository(),
        bundle: LegalBundle.fromJson(value),
      );
      controller.markDocumentOpened('terms');
      controller.markDocumentOpened('privacy');
      expect(
        await controller.accept(
          adultConfirmed: true,
          termsChecked: true,
          privacyChecked: true,
        ),
        isFalse,
      );
      expect(controller.canUseRemoteServices, isFalse);
    }
  });

  test('正文哈希不受JSON键顺序影响，外部修改返回副本不会改历史', () {
    final first = publishedLegalBundleFixture();
    final reverse = {
      for (final entry in first.toJson().entries.toList().reversed)
        entry.key: entry.value,
    };
    expect(LegalBundle.fromJson(reverse).contentHash, first.contentHash);
    final copy = first.toJson();
    (copy['operator'] as Map)['name'] = '被改';
    expect(first.toJson()['operator']['name'], '合成测试运营者');
    expect(first.renderText('{{unknown.key}}'), contains('待补'));
  });

  test('清空等待进行中的保存，不让迟到的同意重新打开联网', () async {
    final repository = _DelayedRepository();
    final controller = await create(repository);
    controller.markDocumentOpened('terms');
    controller.markDocumentOpened('privacy');
    final accepting = controller.accept(
      adultConfirmed: true,
      termsChecked: true,
      privacyChecked: true,
    );
    final clearing = controller.clearAllLocalRecords();
    final allowed = <bool>[];
    controller.addListener(() => allowed.add(controller.canUseRemoteServices));
    repository.release.complete();
    await accepting;
    await clearing;
    expect(controller.records, isEmpty);
    expect(controller.canUseRemoteServices, isFalse);
    expect(allowed, everyElement(isFalse));
    expect((await create(repository)).needsIntroduction, isTrue);
  });

  test('文件记录逐次新增并可重启读取；未完成或损坏末条不能回退到旧同意', () async {
    final directory = await Directory.systemTemp.createTemp(
      'legal-repository-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final repository = FileLegalConsentRepository(
      rootDirectory: () async => directory,
    );
    final controller = await create(repository);
    await accept(controller);
    final restarted = await create(
      FileLegalConsentRepository(rootDirectory: () async => directory),
    );
    expect(restarted.canUseRemoteServices, isTrue);
    final pending = File(
      '${directory.path}/legal_consent_v1/decision-000002.json.pending',
    );
    await pending.writeAsString('{');
    expect((await create(repository)).canUseRemoteServices, isFalse);
    await pending.delete();
    final latest = File(
      '${directory.path}/legal_consent_v1/decision-000002.json',
    );
    await latest.writeAsString('{');
    final corrupt = await create(repository);
    expect(corrupt.canUseRemoteServices, isFalse);
    expect(corrupt.errorMessage, contains('不可读取'));
    await corrupt.clearAllLocalRecords();
    expect(await repository.load(), isEmpty);
  });
}

final class _CountingTransport implements GatewayHttpTransport {
  int sent = 0;
  final result = Completer<GatewayHttpResponse>();
  @override
  Future<GatewayHttpResponse> sendJson({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    Map<String, Object?>? jsonBody,
  }) {
    sent++;
    return result.future;
  }

  @override
  void close() {}
}

final class _DelayedRepository extends MemoryLegalConsentRepository {
  final release = Completer<void>();
  @override
  Future<void> append(LegalConsentEntry entry) async {
    await release.future;
    await super.append(entry);
  }
}
