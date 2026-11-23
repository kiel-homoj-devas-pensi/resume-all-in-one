import 'package:entitlements/entitlements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_storage/local_storage.dart';
import 'package:resume_all_in_one_client/src/app_theme.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/local_agent_composition.dart';
import 'support/local_suggestion_fixture.dart';
import 'package:resume_all_in_one_client/src/local_data_management_service.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_ai_dialogs.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/resume_file_exporter.dart';
import 'package:resume_all_in_one_client/src/resume_import_file_picker.dart';
import 'package:resume_all_in_one_client/src/resume_workspace_controller.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  for (final task in ['基础生成', '岗位优化', '继续对话']) {
    testWidgets('$task 取消后可恢复草稿，恢复不自动批准发送', (tester) async {
      BasicResumeComposeDraft? basic;
      TargetedOptimizationDraft? optimization;
      RemoteConversationDraft? conversation;
      final key = switch (task) {
        '基础生成' => 'AI碎片信息',
        '岗位优化' => '目标岗位输入框',
        _ => '多轮问题输入框',
      };
      await _openDialog(
        tester,
        dialogBuilder: () => switch (task) {
          '基础生成' => BasicResumeComposeDialog(
            initialDraft: basic,
            onDraftChanged: (draft) => basic = draft,
          ),
          '岗位优化' => TargetedOptimizationDialog(
            initialDraft: optimization,
            onDraftChanged: (draft) => optimization = draft,
          ),
          _ => RemoteConversationDialog(
            recentRounds: const [],
            initialDraft: conversation,
            onDraftChanged: (draft) => conversation = draft,
          ),
        },
      );
      final field = find.byKey(Key(key));
      expect(find.textContaining('接收方：北京智谱华章科技股份有限公司'), findsOneWidget);
      expect(find.text('查看隐私政策和接收方说明'), findsOneWidget);
      await tester.ensureVisible(field);
      await tester.enterText(field, '参与课程项目，请保留日期，不要夸大经历。');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('打开测试窗口')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text,
        '参与课程项目，请保留日期，不要夸大经历。',
      );
      expect(
        tester
            .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
            .every((checkbox) => checkbox.value == false),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('含义待核实的候选须另行确认，重新打开仍需核对', (tester) async {
    Object? decision;
    await _openDialog(
      tester,
      dialogBuilder: () => RemoteResumeReviewDialog(
        pendingChange: _pendingChange().withWarnings([
          remoteSemanticReviewWarning,
        ]),
      ),
      onResult: (result) => decision = result,
    );
    final save = find.byKey(const Key('确认远程建议'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    final acknowledgement = find.byKey(const Key('确认改写含义与事实'));
    await tester.ensureVisible(acknowledgement);
    await tester.tap(acknowledgement);
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(decision, RemoteResumeReviewAction.acceptWithFactReview);
    await tester.tap(find.byKey(const Key('打开测试窗口')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });

  for (final brightness in Brightness.values) {
    for (final status in RemoteAccountSessionStatus.values) {
      testWidgets('${brightness.name} 账号 ${status.name} 在窄屏双倍文字下仍可读和关闭', (
        tester,
      ) async {
        _setPhoneViewport(tester);
        final database = LocalStorageDatabase.inMemory();
        final controller = _accountPresentationController(database);
        addTearDown(() async {
          controller.dispose();
          await database.close();
        });
        controller.remoteAccountSnapshot = RemoteAccountSnapshot(
          status: status,
          maskedPhone: status == RemoteAccountSessionStatus.signedIn
              ? '+155****1234'
              : null,
          sessionExpiresAtUtc: null,
          plan: GatewaySubscriptionPlan.free,
          accessByCapability: {
            for (final capability in RemoteAiCapability.values)
              capability: GatewayAccessSnapshot(
                capability: capability,
                plan: GatewaySubscriptionPlan.free,
                allowed: capability == RemoteAiCapability.basicResumeCompose,
                reason: capability == RemoteAiCapability.basicResumeCompose
                    ? 'allowed'
                    : 'subscription_required',
                remainingMonthlyBasicGenerations:
                    capability == RemoteAiCapability.basicResumeCompose
                    ? 8
                    : null,
              ),
          },
        );
        await _openDialog(
          tester,
          dialogBuilder: () =>
              RemoteAccountDialog(controller: controller, onFeedback: () {}),
          brightness: brightness,
          textScale: 2,
        );
        final lastContent = switch (status) {
          RemoteAccountSessionStatus.gatewayUnavailable => find.text(
            '联网服务尚未配置',
          ),
          RemoteAccountSessionStatus.signedOut => find.byKey(
            const Key('注册开发账号'),
          ),
          RemoteAccountSessionStatus.signedIn => find.text('退出本机登录'),
        };
        await tester.ensureVisible(lastContent);
        await tester.pumpAndSettle();
        expect(lastContent.hitTestable(), findsOneWidget);
        expect(find.text('退出').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (status == RemoteAccountSessionStatus.signedOut) {
          expect(find.textContaining('请勿输入真实手机号'), findsOneWidget);
          final password = tester.widget<TextField>(
            find.byKey(const Key('开发账号密码')),
          );
          expect(password.obscureText, isTrue);
          expect(password.enableSuggestions, isFalse);
        }
      });
    }
  }

  for (final brightness in Brightness.values) {
    final dialogScenarios = <String, (Widget Function(), String)>{
      '基础生成': (() => const BasicResumeComposeDialog(), '提交基础生成'),
      '岗位优化': (() => const TargetedOptimizationDialog(), '提交岗位优化'),
      '多轮对话': (
        () => const RemoteConversationDialog(
          recentRounds: [
            RemoteConversationRound(
              userMessage: '请突出我在离线移动端开发方面的经验，但不要补充没有提供的经历。',
              assistantSummary: '建议保留事实并调整表达，等待你审阅。',
            ),
          ],
        ),
        '提交多轮优化',
      ),
      '建议审阅': (
        () => RemoteResumeReviewDialog(pendingChange: _pendingChange()),
        '确认远程建议',
      ),
    };

    for (final scenario in dialogScenarios.entries) {
      testWidgets('${brightness.name} ${scenario.key} 在窄屏双倍文字下可滚动且主操作可达', (
        tester,
      ) async {
        _setPhoneViewport(tester);
        final semanticsHandle = tester.ensureSemantics();
        await _openDialog(
          tester,
          dialogBuilder: scenario.value.$1,
          brightness: brightness,
          textScale: 2,
        );

        final primaryAction = find.byKey(Key(scenario.value.$2));
        expect(primaryAction.hitTestable(), findsOneWidget);
        expect(tester.getSize(primaryAction).height, greaterThanOrEqualTo(48));
        final aiNotice = find.text(ResumeAiProvenance.candidateNotice);
        final originalNoticeRect = aiNotice.evaluate().isEmpty
            ? null
            : tester.getRect(aiNotice);
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

        final privacyChoice = find.byKey(const Key('允许整体发送个人信息'));
        final lastContent = privacyChoice.evaluate().isNotEmpty
            ? privacyChoice
            : find.text('只有确认后才会创建新版本；AI 不会覆盖已有事实或历史版本。');
        await tester.ensureVisible(lastContent);
        await tester.pumpAndSettle();
        expect(lastContent.hitTestable(), findsOneWidget);
        expect(primaryAction.hitTestable(), findsOneWidget);
        if (originalNoticeRect != null) {
          expect(aiNotice.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(aiNotice),
            originalNoticeRect,
            reason: 'AI generation notice stays outside scrolling content',
          );
        }
        expect(tester.takeException(), isNull);
        semanticsHandle.dispose();
      });
    }
  }

  testWidgets('键盘出现时岗位优化的内容可滚动且提交按钮不被遮挡', (tester) async {
    _setPhoneViewport(tester);
    await _openDialog(
      tester,
      dialogBuilder: () => const TargetedOptimizationDialog(),
      textScale: 2,
    );
    final jobField = find.byKey(const Key('目标岗位输入框'));
    await tester.ensureVisible(jobField);
    await tester.enterText(jobField, 'Flutter 工程师');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final submit = find.byKey(const Key('提交岗位优化'));
    expect(tester.getRect(submit).bottom, lessThanOrEqualTo(400));
    expect(submit.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('个人字段默认不发送且每次新打开生成窗口都重新征求选择', (tester) async {
    Object? submittedDraft;
    await _openDialog(
      tester,
      dialogBuilder: () => const BasicResumeComposeDialog(),
      onResult: (result) => submittedDraft = result,
    );
    expect(
      tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .every((checkbox) => checkbox.value == false),
      isTrue,
    );
    await tester.enterText(find.byKey(const Key('AI碎片信息')), '负责本地离线编辑器开发');
    expect(find.byType(CheckboxListTile), findsOneWidget);
    final overallChoice = find.byKey(const Key('允许整体发送个人信息'));
    await tester.ensureVisible(overallChoice);
    await tester.tap(overallChoice);
    await tester.pump();
    await tester.tap(find.byKey(const Key('提交基础生成')));
    await tester.pumpAndSettle();
    final draft = submittedDraft! as BasicResumeComposeDraft;
    expect(draft.sourceText, '负责本地离线编辑器开发');
    expect(draft.sharePersonalData, isTrue);
    expect(
      draft.selectedPersonalFields,
      RemotePersonalDataField.values.toSet(),
    );

    await tester.tap(find.byKey(const Key('打开测试窗口')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
          .every((checkbox) => checkbox.value == false),
      isTrue,
    );
  });

  testWidgets('远程审阅明确展示事实风险和修改前后，拒绝与确认返回不同决定', (tester) async {
    Object? reviewDecision;
    await _openDialog(
      tester,
      dialogBuilder: () =>
          RemoteResumeReviewDialog(pendingChange: _pendingChange()),
      onResult: (result) => reviewDecision = result,
    );
    expect(find.text('请逐项核对事实'), findsOneWidget);
    expect(find.text('事实变更 · 修改'), findsOneWidget);
    expect(find.text('修改前'), findsOneWidget);
    expect(find.text('修改后'), findsOneWidget);
    expect(find.text('工程师'), findsOneWidget);
    expect(find.text('移动端工程师'), findsOneWidget);
    expect(find.text('基本信息 · 意向职业岗位'), findsOneWidget);
    expect(find.textContaining('/profile/headline'), findsNothing);
    await tester.tap(find.byKey(const Key('拒绝远程建议')));
    await tester.pumpAndSettle();
    expect(reviewDecision, RemoteResumeReviewAction.reject);

    await tester.tap(find.byKey(const Key('打开测试窗口')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('确认远程建议')));
    await tester.pumpAndSettle();
    expect(reviewDecision, RemoteResumeReviewAction.accept);
  });

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} 远程审阅的风险与修改面板保持可读对比度', (tester) async {
      final semanticsHandle = tester.ensureSemantics();
      await _openDialog(
        tester,
        dialogBuilder: () =>
            RemoteResumeReviewDialog(pendingChange: _pendingChange()),
        brightness: brightness,
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await tester.ensureVisible(find.text('修改后'));
      await tester.pumpAndSettle();
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      semanticsHandle.dispose();
    });
  }
}

void _setPhoneViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openDialog(
  WidgetTester tester, {
  required Widget Function() dialogBuilder,
  Brightness brightness = Brightness.light,
  double textScale = 1,
  ValueChanged<Object?>? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const Key('打开测试窗口'),
              onPressed: () async {
                final result = await showDialog<Object>(
                  context: context,
                  builder: (_) => dialogBuilder(),
                );
                onResult?.call(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('打开测试窗口')));
  await tester.pumpAndSettle();
}

PendingRemoteResumeChange _pendingChange() {
  final original = ResumeData(
    profile: ResumeProfile(
      id: 'profile-dialog-test',
      fullName: '合成测试用户',
      headline: '工程师',
      email: '',
      phone: '',
      location: '',
    ),
  );
  final patch = ResumePatch([
    ResumePatchOperation(
      type: PatchOperationType.replace,
      path: '/profile/headline',
      oldValue: '工程师',
      newValue: '移动端工程师',
      reason: '根据提供的经历补充方向，需由本人核实。',
      source: '合成界面测试',
      category: ResumeChangeCategory.fact,
    ),
  ]);
  return PendingRemoteResumeChange(
    target: RemoteResumeChangeTarget.currentDocument,
    documentTitle: '合成测试简历',
    documentId: 'dialog-document',
    baseVersionId: 'dialog-version',
    operationId: 'dialog-operation',
    summary: '一项建议等待审阅。',
    baseContent: original,
    proposedContent: patch.apply(original),
    patch: patch,
    diff: ResumeDiff.fromPatch(patch),
    missingInformation: const ['请自行核对职位名称'],
    warnings: const ['不要添加未经确认的事实'],
  );
}

ResumeWorkspaceController _accountPresentationController(
  LocalStorageDatabase database,
) {
  final repository = DriftResumeRepository(database);
  final auditRepository = DriftAgentAuditRepository(database);
  final remoteAccount = RemoteAccountService(gatewayApi: null);
  return ResumeWorkspaceController(
    repository: repository,
    settingsRepository: DriftAppSettingsRepository(database),
    localAgentCheckService: createOfflineLocalAgentCheckService(
      resumeRepository: repository,
      auditRepository: auditRepository,
    ),
    localResumeSuggestionService: createOfflineLocalResumeSuggestionService(
      resumeRepository: repository,
      auditRepository: auditRepository,
    ),
    localDataManagementService: LocalDataManagementService(
      repository: DriftLocalDataRepository(database),
      rootDirectory: () async => throw StateError('界面布局测试不访问导出目录'),
    ),
    accessPolicy: CapabilityAccessPolicy.mvp(),
    fileExporter: ResumeFileExporter(
      rootDirectory: () async => throw StateError('界面布局测试不访问导出目录'),
    ),
    importFilePicker: const SystemResumeImportFilePicker(),
    remoteAccountService: remoteAccount,
    remoteResumeAiService: RemoteResumeAiService(accountService: remoteAccount),
  );
}
