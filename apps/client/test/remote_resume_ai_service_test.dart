import 'dart:convert';
import 'package:local_storage/local_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/gateway_api_client.dart';
import 'package:resume_all_in_one_client/src/remote_account_service.dart';
import 'package:resume_all_in_one_client/src/remote_resume_ai_service.dart';
import 'package:resume_all_in_one_client/src/remote_task_draft_store.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  test('相同未知材料的新草稿在发送前绑定原请求，不留下可错误重发的孤立任务', () async {
    final gateway = _BasicComposeGatewayApi(
      output: _validBasicOutput(),
      outputBuilder: (_) => throw const GatewayApiException(
        code: 'client_timeout',
        message: 'lost',
        retryable: false,
      ),
    );
    final service = await _signedInService(gateway);
    final draft = BasicResumeComposeDraft(
      documentTitle: '合成材料',
      sourceText: '参与页面开发',
      fullName: '张三',
      phone: '',
      email: '',
      preciseAddress: '',
    );
    await expectLater(
      service.prepareBasicResumeCompose(draft, taskId: 'first'),
      throwsA(isA<GatewayApiException>()),
    );
    await expectLater(
      service.prepareBasicResumeCompose(draft, taskId: 'second'),
      throwsA(isA<RemoteAccountInputException>()),
    );
    final tasks = await service.unfinishedTasks();
    expect(tasks, hasLength(2));
    expect(tasks.map((task) => task.clientRequestId).toSet(), hasLength(1));
    expect(gateway.submittedInputs, hasLength(1));
  });

  test('恢复材料不恢复发送同意，原候选取回只解析并本地合并而不生成', () async {
    final gateway = _BasicComposeGatewayApi(output: _validBasicOutput());
    final service = await _signedInService(gateway);
    final task = RemoteTaskDraft(
      owner: 'owner',
      id: 'task-a',
      kind: 'compose',
      createdAtUtc: DateTime.utc(2026, 10, 9),
      expiresAtUtc: DateTime.utc(2026, 10, 16),
      submittedPersonalDataShared: true,
      material: {
        'documentTitle': '合成恢复',
        'sourceText': '2024 年负责离线简历项目\n使用 Flutter 和 Dart',
        'profileDocument': ResumeData(
          profile: ResumeProfile(
            id: 'p',
            fullName: '张三',
            email: 'local@example.com',
            phone: '',
            headline: '',
            location: '',
          ),
        ).toJson(),
        'naturalLanguageInput': false,
      },
    );
    final draft = service.restoreComposeMaterial(task);
    expect(draft.sharePersonalData, isFalse);
    expect(draft.confirmedInputSharing, isFalse);
    expect(
      service
          .restoreComposeMaterial(task, forResultRecovery: true)
          .sharePersonalData,
      isTrue,
    );
    final pending = await service.prepareBasicResumeCompose(
      draft,
      recoveredResponse: GatewayRemoteAiResponse(
        operationId: 'original-op',
        clientRequestId: 'original-request',
        capability: RemoteAiCapability.basicResumeCompose,
        output: _validBasicOutput(),
        promptVersion: 'synthetic.v1',
      ),
    );
    expect(gateway.submittedInputs, isEmpty);
    expect(pending.operationId, 'original-op');
    expect(pending.proposedContent.profile.fullName, '张三');
    expect(pending.proposedContent.profile.email, 'local@example.com');
  });

  test('未命名未定日期的项目以中性标题形成可保存候选，角色留空且基础信息保留本地', () async {
    final output = _validBasicOutput();
    final candidate = output['candidateResume']! as Map<String, Object?>;
    candidate['profile'] = {
      'id': 'candidate-profile',
      'headline': '',
      'coarseLocation': '',
    };
    candidate['workExperiences'] = <Object?>[];
    candidate['projects'] = [
      {
        'id': 'candidate-project-1',
        'name': '项目经历',
        'role': '',
        'dateRange': null,
        'summary': '参与网页开发，用Vue写过表单',
        'highlights': <Object?>[],
      },
    ];
    candidate['skillGroups'] = [
      {
        'id': 'candidate-skill-1',
        'name': '技能',
        'skills': ['HTML', 'CSS'],
      },
    ];
    output['sourceReferences'] = [
      for (final path in ['/projects/0', '/skillGroups/0'])
        {
          'path': path,
          'fragmentIds': ['fragment-1'],
        },
    ];
    final gateway = _BasicComposeGatewayApi(output: output);
    final service = await _signedInService(gateway);
    final result = await service.prepareBasicResumeCompose(
      BasicResumeComposeDraft(
        documentTitle: '合成未定日期项目',
        sourceText: '参与网页开发，用Vue写过表单，会HTML和CSS，日期记不清',
        fullName: '周宁',
        phone: '',
        email: 'zhou.ning@example.com',
        preciseAddress: '',
        naturalLanguageInput: true,
        confirmedInputSharing: true,
        sharePersonalData: false,
      ),
    );
    expect(result.proposedContent.projects.single.name, '项目经历');
    expect(result.proposedContent.projects.single.role, isEmpty);
    expect(result.proposedContent.projects.single.dateRange, isNull);
    expect(result.proposedContent.profile.fullName, '周宁');
    expect(
      const ResumeValidator().validate(result.proposedContent).isValid,
      isTrue,
    );
    expect(
      result.patch.apply(result.baseContent).toJson(),
      result.proposedContent.toJson(),
    );
    expect(gateway.submittedInputs, hasLength(1));
  });

  test('日期不足的教育和工作可保存为自定义经历，完整日期结构和全部原文字段保留', () async {
    final output = _undatedEducationOutput();
    final candidate = output['candidateResume']! as Map<String, Object?>;
    (candidate['workExperiences']! as List).add({
      'id': 'candidate-work-undated',
      'organization': '实习示例公司',
      'position': '协助开发',
      'dateRange': null,
      'summary': '参与已有页面开发，日期记不清',
      'highlights': ['协助修复表单显示问题'],
    });
    (candidate['educations']! as List).add({
      'id': 'candidate-education-dated',
      'institution': '另一示例学校',
      'degree': '专科',
      'fieldOfStudy': '信息技术',
      'dateRange': {
        'start': {'year': 2017, 'month': 9},
        'end': {'year': 2020, 'month': 6},
        'isCurrent': false,
      },
      'highlights': <Object?>[],
    });
    candidate['customSections'] = [
      {
        'id': 'candidate-undated-education',
        'title': '原有栏目',
        'items': [
          {
            'id': 'candidate-undated-work',
            'title': '原有条目',
            'description': '保留原有内容',
          },
        ],
      },
    ];
    output['sourceReferences'] = [
      for (final path in ['/workExperiences', '/educations', '/customSections'])
        {
          'path': path,
          'fragmentIds': ['fragment-1'],
        },
    ];
    final service = await _signedInService(
      _BasicComposeGatewayApi(output: output),
    );
    final result = await service.prepareBasicResumeCompose(
      BasicResumeComposeDraft(
        documentTitle: '毕业时间和未定日期经历',
        sourceText: '示例大学本科，计算机专业，2024年6月毕业，实习参与已有页面开发',
        fullName: '周宁',
        phone: '',
        email: 'zhou.ning@example.com',
        preciseAddress: '',
        links: [
          ResumeLink(
            id: 'candidate-undated-education-1',
            label: '作品',
            url: 'https://example.com/work',
          ),
        ],
      ),
    );
    final content = result.proposedContent;
    expect(content.profile.fullName, '周宁');
    expect(content.profile.email, 'zhou.ning@example.com');
    expect(content.workExperiences.single.id, 'candidate-work-1');
    expect(content.workExperiences.single.dateRange.start.year, 2024);
    expect(content.educations.single.id, 'candidate-education-dated');
    expect(content.educations.single.dateRange.start.year, 2017);
    expect(content.educations.single.dateRange.end!.year, 2020);
    expect(content.customSections, hasLength(3));
    expect(content.customSections.first.items.single.description, '保留原有内容');
    final work = content.customSections[1];
    expect(work.id, 'candidate-undated-work-1');
    expect(work.title, '工作经历');
    expect(work.items.single.id, 'candidate-work-undated');
    expect(work.items.single.title, '实习示例公司 · 协助开发');
    expect(work.items.single.description, '参与已有页面开发，日期记不清\n协助修复表单显示问题');
    final education = content.customSections[2];
    expect(education.id, 'candidate-undated-education-2');
    expect(education.title, '教育经历');
    expect(education.items.single.id, 'candidate-education-1');
    expect(education.items.single.title, '示例大学');
    expect(education.items.single.description, '学历：本科\n专业：计算机\n2024年6月毕业');
    expect(const ResumeValidator().validate(content).isValid, isTrue);
    expect(ResumeData.fromJson(content.toJson()).toJson(), content.toJson());
    expect(result.patch.apply(result.baseContent).toJson(), content.toJson());
  });

  for (final field in ['workExperiences', 'educations']) {
    test('未定日期$field仍拒绝白名单外字段，不因转换而放行', () async {
      final output = _undatedEducationOutput();
      final candidate = output['candidateResume']! as Map<String, Object?>;
      final entry = (candidate[field]! as List).first as Map<String, Object?>;
      entry['dateRange'] = null;
      entry['unapprovedFact'] = '不能接受';
      final service = await _signedInService(
        _BasicComposeGatewayApi(output: output),
      );
      await expectLater(
        service.prepareBasicResumeCompose(
          BasicResumeComposeDraft(
            documentTitle: '非法候选',
            sourceText: '示例大学本科，2024年6月毕业',
            fullName: '周宁',
            phone: '',
            email: '',
            preciseAddress: '',
          ),
        ),
        throwsA(isA<RemoteResumeAiResponseException>()),
      );
    });
  }

  test('未定日期经历仍拒绝重复原始实体ID', () async {
    final output = _undatedEducationOutput();
    final candidate = output['candidateResume']! as Map<String, Object?>;
    ((candidate['educations']! as List).first as Map)['id'] =
        'candidate-work-1';
    final service = await _signedInService(
      _BasicComposeGatewayApi(output: output),
    );
    await expectLater(
      service.prepareBasicResumeCompose(
        BasicResumeComposeDraft(
          documentTitle: '重复实体',
          sourceText: '示例大学本科，2024年6月毕业',
          fullName: '周宁',
          phone: '',
          email: '',
          preciseAddress: '',
        ),
      ),
      throwsA(isA<RemoteResumeAiResponseException>()),
    );
  });

  test('日期范围对象缺少起始日期属于非法结构，不能当未定日期静默转换', () async {
    final output = _undatedEducationOutput();
    final candidate = output['candidateResume']! as Map<String, Object?>;
    ((candidate['educations']! as List).first as Map)['dateRange'] = {
      'start': null,
      'end': {'year': 2024, 'month': 6},
      'isCurrent': false,
    };
    final service = await _signedInService(
      _BasicComposeGatewayApi(output: output),
    );
    await expectLater(
      service.prepareBasicResumeCompose(
        BasicResumeComposeDraft(
          documentTitle: '非法日期',
          sourceText: '2024年6月毕业于示例大学',
          fullName: '周宁',
          phone: '',
          email: '',
          preciseAddress: '',
        ),
      ),
      throwsA(isA<RemoteResumeAiResponseException>()),
    );
  });

  test('整体选择保留本地时，自由材料里的重复联系方式和未知邮箱也不发送', () async {
    final output = _validBasicOutput();
    for (final reference in output['sourceReferences']! as List) {
      (reference as Map)['fragmentIds'] = ['fragment-1'];
    }
    final gateway = _BasicComposeGatewayApi(output: output);
    final service = await _signedInService(gateway);
    final draft = BasicResumeComposeDraft(
      documentTitle: '自由材料',
      sourceText:
          '我叫张三，在上海示例路，电话13800000000，'
          '邮箱private@example.com。也可以联系other@example.com和13912345678。'
          '去年学校做过一个Flutter小程序，跟同学一起写页面，数据库也碰过一点。',
      fullName: '张三',
      phone: '13800000000',
      email: 'private@example.com',
      preciseAddress: '上海示例路',
      headline: '前端开发',
      links: [
        ResumeLink(
          id: 'link-local',
          label: '作品',
          url: 'https://example.com/private',
        ),
      ],
      naturalLanguageInput: true,
      confirmedInputSharing: true,
      sharePersonalData: false,
    );
    final result = await service.prepareBasicResumeCompose(draft);
    final sent = jsonEncode(gateway.submittedInputs.single);
    for (final value in [
      '张三',
      '上海示例路',
      '13800000000',
      'private@example.com',
      'other@example.com',
      '13912345678',
      'https://example.com/private',
    ]) {
      expect(sent, isNot(contains(value)));
    }
    expect(sent, contains('跟同学一起写页面'));
    expect(gateway.submittedInputs.single, isNot(contains('personalData')));
    expect(result.proposedContent.profile.fullName, '张三');
    expect(result.proposedContent.profile.email, 'private@example.com');
    expect(result.proposedContent.profile.headline, '前端开发');
    expect(
      result.proposedContent.profile.links.single.url,
      'https://example.com/private',
    );
    expect(
      result.patch.apply(result.baseContent).toJson(),
      result.proposedContent.toJson(),
    );
  });

  test('整体允许发送只带已填写字段，不要求把选填联系方式填满', () async {
    final output = _validBasicOutput();
    for (final reference in output['sourceReferences']! as List) {
      (reference as Map)['fragmentIds'] = ['fragment-1'];
    }
    final gateway = _BasicComposeGatewayApi(output: output);
    final service = await _signedInService(gateway);
    await service.prepareBasicResumeCompose(
      BasicResumeComposeDraft(
        documentTitle: '简历',
        sourceText: '张三参与Flutter校园小程序开发',
        fullName: '张三',
        phone: '',
        email: '',
        preciseAddress: '上海',
        naturalLanguageInput: true,
        confirmedInputSharing: true,
        sharePersonalData: true,
      ),
    );
    expect(gateway.submittedInputs.single['personalData'], {
      'consentedFields': ['fullName', 'preciseAddress'],
      'fullName': '张三',
      'preciseAddress': '上海',
    });
  });

  test('只输入目标岗位即可优化，材料脱敏后oldValue仍能准确匹配本地原版本', () async {
    final saved = _savedResume();
    final content = ResumeData.fromJson({
      ...saved.version.content.toJson(),
      'profile': {
        ...saved.version.content.profile.toJson(),
        'headline': '移动端工程师 张三 13800000000',
      },
    });
    final version = ResumeVersion(
      id: saved.version.id,
      documentId: saved.document.id,
      parentVersionId: saved.version.parentVersionId,
      schemaVersion: content.schemaVersion,
      content: content,
      source: saved.version.source,
      createdAt: saved.version.createdAt,
    );
    final gateway = _BasicComposeGatewayApi(
      output: {},
      plan: GatewaySubscriptionPlan.pro,
      outputBuilder: (input) {
        final headline =
            ((input['resume']! as Map)['profile'] as Map)['headline'] as String;
        return _validOptimizationOutput(
          outputVersion: 'targetedResumeOptimization.v1',
          oldHeadline: headline,
          newHeadline: '$headline · Flutter',
        );
      },
    );
    final service = await _signedInService(gateway);
    final result = await service.prepareTargetedOptimization(
      document: saved.document,
      version: version,
      targetJobTitle: '前端开发',
      jobDescription: '',
      userInstruction: '',
      confirmedInputSharing: true,
      sharePersonalData: false,
    );
    final sent = jsonEncode(gateway.submittedInputs.single);
    expect(sent, isNot(contains('张三')));
    expect(sent, isNot(contains('13800000000')));
    expect(
      result.pendingChange!.proposedContent.profile.headline,
      '移动端工程师 张三 13800000000 · Flutter',
    );
    expect(result.pendingChange!.baseVersionId, version.id);
    expect(
      result.pendingChange!.patch.apply(content).toJson(),
      result.pendingChange!.proposedContent.toJson(),
    );
  });

  test('上一轮允许发送不影响下一轮选择，本地模式也清理已有对话里的个人信息', () async {
    final saved = _savedResume();
    final gateway = _BasicComposeGatewayApi.queued(
      outputs: [
        _noPatchConversationOutput('张三的建议请核对'),
        _noPatchConversationOutput('请核对建议'),
      ],
      plan: GatewaySubscriptionPlan.pro,
    );
    final service = await _signedInService(gateway);
    await service.prepareConversationTurn(
      document: saved.document,
      version: saved.version,
      targetJobTitle: '前端',
      jobDescription: '',
      userMessage: '张三，电话13800000000，请简洁一些',
      confirmedInputSharing: true,
      sharePersonalData: true,
    );
    await service.prepareConversationTurn(
      document: saved.document,
      version: saved.version,
      targetJobTitle: '前端',
      jobDescription: '',
      userMessage: '请继续简化',
      confirmedInputSharing: true,
      sharePersonalData: false,
    );
    expect(jsonEncode(gateway.submittedInputs.first), contains('张三'));
    final second = jsonEncode(gateway.submittedInputs.last);
    expect(second, isNot(contains('张三')));
    expect(second, isNot(contains('13800000000')));
    expect(second, isNot(contains('zhangsan@example.com')));
    expect(second, contains('recentMessages'));
  });

  test('整段自然语言自动分段并接收模型提取的基本信息，不要求逐行填表', () async {
    final output = _validBasicOutput();
    final candidate = output['candidateResume']! as Map<String, Object?>;
    final profile = candidate['profile']! as Map<String, Object?>;
    profile.addAll(<String, String>{
      'fullName': '张三',
      'phone': '13800000000',
      'email': 'test@example.com',
      'preciseAddress': '',
    });
    final references = output['sourceReferences']! as List<Object?>;
    for (final field in ['fullName', 'phone', 'email']) {
      references.add({
        'path': '/profile/$field',
        'fragmentIds': ['fragment-1'],
      });
    }
    final gateway = _BasicComposeGatewayApi(output: output);
    final service = await _signedInService(gateway);
    final text =
        '我叫张三，电话13800000000，邮箱test@example.com。'
        '2024年负责离线简历项目，使用Flutter和Dart。${'参与项目材料整理。' * 150}';
    final pending = await service.prepareBasicResumeCompose(
      BasicResumeComposeDraft(
        documentTitle: '自然语言简历',
        sourceText: text,
        fullName: '',
        phone: '',
        email: '',
        preciseAddress: '',
        naturalLanguageInput: true,
        confirmedInputSharing: true,
      ),
    );
    final input = gateway.submittedInputs.single;
    expect(input['naturalLanguageInput'], isTrue);
    expect((input['sourceFragments']! as List).length, greaterThan(1));
    expect(pending.proposedContent.profile.fullName, '张三');
    expect(pending.proposedContent.profile.phone, '13800000000');
    expect(pending.proposedContent.profile.email, 'test@example.com');
  });

  test('没有确认整段发送时自然语言不会触发远端请求', () async {
    final gateway = _BasicComposeGatewayApi(output: _validBasicOutput());
    final service = await _signedInService(gateway);
    await expectLater(
      service.prepareBasicResumeCompose(
        BasicResumeComposeDraft(
          documentTitle: '自然语言简历',
          sourceText: '我参加过校园活动，想找运营工作。',
          fullName: '',
          phone: '',
          email: '',
          preciseAddress: '',
          naturalLanguageInput: true,
        ),
      ),
      throwsA(isA<RemoteResumeAiInputException>()),
    );
    expect(gateway.submittedInputs, isEmpty);
  });

  test('基础生成默认不发送个人字段并在本地回填后生成可复核 Diff', () async {
    final gatewayApi = _BasicComposeGatewayApi(output: _validBasicOutput());
    final remoteService = await _signedInService(gatewayApi);

    final pendingChange = await remoteService.prepareBasicResumeCompose(
      BasicResumeComposeDraft(
        documentTitle: '求职简历',
        sourceText: '2024 年负责离线简历项目\n使用 Flutter 和 Dart',
        fullName: '张三',
        phone: '13800000000',
        email: 'zhangsan@example.com',
        preciseAddress: '上海市浦东新区示例路 1 号',
      ),
    );

    final submittedInput = gatewayApi.submittedInputs.single;
    expect(submittedInput, isNot(contains('personalData')));
    expect(pendingChange.proposedContent.profile.fullName, '张三');
    expect(pendingChange.proposedContent.profile.phone, '13800000000');
    expect(pendingChange.proposedContent.profile.location, '上海市浦东新区示例路 1 号');
    expect(pendingChange.diff.containsFactChanges, isTrue);
    expect(
      pendingChange.patch.apply(pendingChange.baseContent).toJson(),
      pendingChange.proposedContent.toJson(),
    );
    expect(
      pendingChange.baseContent.profile.fullName,
      pendingChange.proposedContent.profile.fullName,
    );
  });

  test('明确选择的个人字段与 consentedFields 完全一致', () async {
    final gatewayApi = _BasicComposeGatewayApi(output: _validBasicOutput());
    final remoteService = await _signedInService(gatewayApi);

    await remoteService.prepareBasicResumeCompose(
      BasicResumeComposeDraft(
        documentTitle: '求职简历',
        sourceText: '负责移动端项目\n使用 Flutter',
        fullName: '张三',
        phone: '13800000000',
        email: 'zhangsan@example.com',
        preciseAddress: '上海',
        selectedPersonalFields: const {
          RemotePersonalDataField.fullName,
          RemotePersonalDataField.email,
        },
      ),
    );

    expect(gatewayApi.submittedInputs.single['personalData'], {
      'consentedFields': ['fullName', 'email'],
      'fullName': '张三',
      'email': 'zhangsan@example.com',
    });
  });

  test('自由文本中的联系方式在 Gateway 调用前被拒绝', () async {
    final gatewayApi = _BasicComposeGatewayApi(output: _validBasicOutput());
    final remoteService = await _signedInService(gatewayApi);

    await expectLater(
      remoteService.prepareBasicResumeCompose(
        BasicResumeComposeDraft(
          documentTitle: '求职简历',
          sourceText: '联系邮箱 another@example.com\n负责移动端项目',
          fullName: '',
          phone: '',
          email: '',
          preciseAddress: '',
        ),
      ),
      throwsA(
        isA<RemoteResumeAiInputException>().having(
          (error) => error.message,
          'message',
          contains('疑似包含邮箱'),
        ),
      ),
    );
    expect(gatewayApi.submittedInputs, isEmpty);
  });

  test('候选引用未知碎片时不进入审阅', () async {
    final invalidOutput = _validBasicOutput();
    invalidOutput['sourceReferences'] = [
      {
        'path': '/profile/headline',
        'fragmentIds': ['fragment-not-sent'],
      },
    ];
    final remoteService = await _signedInService(
      _BasicComposeGatewayApi(output: invalidOutput),
    );

    await expectLater(
      remoteService.prepareBasicResumeCompose(
        BasicResumeComposeDraft(
          documentTitle: '求职简历',
          sourceText: '负责移动端项目',
          fullName: '',
          phone: '',
          email: '',
          preciseAddress: '',
        ),
      ),
      throwsA(isA<RemoteResumeAiResponseException>()),
    );
  });

  test('Canonical fingerprint 对相同内容保持稳定且不包含文档元数据', () async {
    final gatewayApi = _BasicComposeGatewayApi(output: _validBasicOutput());
    final remoteService = await _signedInService(gatewayApi);
    final resumeContent = ResumeData(
      profile: ResumeProfile(
        id: 'profile-001',
        fullName: '张三',
        headline: '工程师',
        email: '',
        phone: '',
        location: '',
      ),
    );

    expect(
      remoteService.contentFingerprint(resumeContent),
      remoteService.contentFingerprint(
        ResumeData.fromJson(resumeContent.toJson()),
      ),
    );
    expect(remoteService.contentFingerprint(resumeContent), hasLength(64));
  });

  test('岗位优化只发送白名单投影并把合法 Patch 交给用户复核', () async {
    final savedResume = _savedResume();
    final gatewayApi = _BasicComposeGatewayApi(
      output: _validOptimizationOutput(
        outputVersion: 'targetedResumeOptimization.v1',
        oldHeadline: '移动端工程师',
        newHeadline: 'Flutter 移动端工程师',
      ),
      plan: GatewaySubscriptionPlan.pro,
    );
    final remoteService = await _signedInService(gatewayApi);

    final preparation = await remoteService.prepareTargetedOptimization(
      document: savedResume.document,
      version: savedResume.version,
      targetJobTitle: 'Flutter 工程师',
      jobDescription: '负责本地优先的移动端产品',
      userInstruction: '突出离线架构经验',
    );

    final submittedResume =
        gatewayApi.submittedInputs.single['resume']! as Map<String, Object?>;
    final submittedProfile =
        submittedResume['profile']! as Map<String, Object?>;
    expect(submittedProfile.keys, {'id', 'headline', 'coarseLocation'});
    expect(submittedProfile['coarseLocation'], '');
    expect(submittedResume, isNot(contains('unmapped')));
    final submittedProjects = submittedResume['projects']! as List<Object?>;
    expect(
      submittedProjects.single as Map<String, Object?>,
      isNot(contains('links')),
    );
    expect(preparation.pendingChange, isNotNull);
    expect(
      preparation.pendingChange!.proposedContent.profile.headline,
      'Flutter 移动端工程师',
    );
    expect(preparation.pendingChange!.proposedContent.profile.fullName, '张三');
  });

  test('岗位优化返回与本地基线不一致的 oldValue 时拒绝进入审阅', () async {
    final savedResume = _savedResume();
    final remoteService = await _signedInService(
      _BasicComposeGatewayApi(
        output: _validOptimizationOutput(
          outputVersion: 'targetedResumeOptimization.v1',
          oldHeadline: '错误的旧标题',
          newHeadline: 'Flutter 移动端工程师',
        ),
        plan: GatewaySubscriptionPlan.pro,
      ),
    );

    await expectLater(
      remoteService.prepareTargetedOptimization(
        document: savedResume.document,
        version: savedResume.version,
        targetJobTitle: 'Flutter 工程师',
        jobDescription: '',
        userInstruction: '',
      ),
      throwsA(isA<RemoteResumeAiResponseException>()),
    );
  });

  test('多轮优化每次只携带最近三轮并可按简历清空', () async {
    final savedResume = _savedResume();
    final gatewayApi = _BasicComposeGatewayApi.queued(
      outputs: [
        for (var round = 1; round <= 4; round++)
          _noPatchConversationOutput('第 $round 轮建议'),
      ],
      plan: GatewaySubscriptionPlan.pro,
    );
    final remoteService = await _signedInService(gatewayApi);

    for (var round = 1; round <= 4; round++) {
      await remoteService.prepareConversationTurn(
        document: savedResume.document,
        version: savedResume.version,
        targetJobTitle: 'Flutter 工程师',
        jobDescription: '',
        userMessage: '第 $round 轮问题',
      );
    }

    expect(
      gatewayApi.submittedInputs.map(
        (input) => (input['recentMessages']! as List<Object?>).length,
      ),
      [0, 2, 4, 6],
    );
    expect(
      remoteService
          .conversationFor(savedResume.document.id)
          .map((round) => round.userMessage),
      ['第 2 轮问题', '第 3 轮问题', '第 4 轮问题'],
    );
    remoteService.clearDocumentConversation(savedResume.document.id);
    expect(remoteService.conversationFor(savedResume.document.id), isEmpty);
  });
  test('有界对话恢复到新服务对象，账号与基础版本隔离', () async {
    final db = LocalStorageDatabase.inMemory();
    addTearDown(db.close);
    final repository = DriftRemoteReviewRepository(db);
    final saved = _savedResume();
    final gateway = _BasicComposeGatewayApi.queued(
      outputs: [
        for (var i = 1; i <= 4; i++) _noPatchConversationOutput('第 $i 轮建议'),
      ],
      plan: GatewaySubscriptionPlan.pro,
    );
    final first = await _signedInService(gateway, reviewRepository: repository);
    for (var i = 1; i <= 4; i++) {
      await first.prepareConversationTurn(
        document: saved.document,
        version: saved.version,
        targetJobTitle: '',
        jobDescription: '',
        userMessage: '第 $i 轮问题',
      );
    }
    final next = await _signedInService(gateway, reviewRepository: repository);
    await next.restoreConversation(saved.document.id, saved.version.id);
    expect(next.conversationFor(saved.document.id).map((r) => r.userMessage), [
      '第 2 轮问题',
      '第 3 轮问题',
      '第 4 轮问题',
    ]);
    expect(gateway.submittedInputs, hasLength(4), reason: '恢复不发送请求');
    await next.restoreConversation(saved.document.id, 'changed-version');
    expect(next.conversationFor(saved.document.id), isEmpty);
    gateway.owner = 'other-owner';
    final other = await _signedInService(gateway, reviewRepository: repository);
    await other.restoreConversation(saved.document.id, saved.version.id);
    expect(other.conversationFor(saved.document.id), isEmpty);
  });
  test('基础撰写追问不产生候选，补充原材料后才得到可审阅结果', () async {
    final gateway = _BasicComposeGatewayApi.queued(
      outputs: [
        {
          ..._validBasicOutput(),
          'missingInformation': [
            {'path': '/workExperiences/0/summary', 'question': '请补充实际职责'},
          ],
        },
        _validBasicOutput(),
      ],
    );
    final service = await _signedInService(gateway);
    BasicResumeComposeDraft draft(String text) => BasicResumeComposeDraft(
      documentTitle: '简历',
      sourceText: text,
      fullName: '张三',
      phone: '',
      email: '',
      preciseAddress: '',
    );
    await expectLater(
      service.prepareBasicResumeCompose(draft('请帮我写简历')),
      throwsA(
        isA<RemoteResumeAiQuestions>().having(
          (e) => e.questions.single,
          '问题',
          '工作经历 · 第1项 · 描述：请补充实际职责',
        ),
      ),
    );
    expect(gateway.submittedInputs, hasLength(1), reason: '不自动重发');
    final result = await service.prepareBasicResumeCompose(
      draft('2024年负责移动端项目\n使用Flutter和Dart'),
    );
    expect(result.target, RemoteResumeChangeTarget.newDocument);
    expect(gateway.submittedInputs, hasLength(2));
  });

  test('明确确认的事实与长期要求跨四轮及重启保留，聊天不自动升级为事实', () async {
    final db = LocalStorageDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftRemoteReviewRepository(db);
    final saved = _savedResume();
    final gateway = _BasicComposeGatewayApi.queued(
      outputs: [
        for (var i = 0; i < 5; i++) _noPatchConversationOutput('请继续核对材料'),
      ],
      plan: GatewaySubscriptionPlan.pro,
    );
    final first = await _signedInService(gateway, reviewRepository: repo);
    await first.prepareConversationTurn(
      document: saved.document,
      version: saved.version,
      targetJobTitle: '',
      jobDescription: '',
      userMessage: '我主导团队，是吗？',
    );
    expect(gateway.submittedInputs.single, isNot(contains('writingContext')));
    final facts = RemoteWritingContext(
      confirmedFacts: {'/projects/0/summary': '参与本地简历工具开发，未担任团队负责人。'},
      constraints: ['只改项目描述', '不要夸大职责'],
    );
    expect(
      await first.confirmWritingContext(
        document: saved.document,
        version: saved.version,
        context: facts,
      ),
      isTrue,
    );
    for (var i = 0; i < 4; i++) {
      await first.prepareConversationTurn(
        document: saved.document,
        version: saved.version,
        targetJobTitle: '',
        jobDescription: '',
        userMessage: '第$i轮，请继续',
      );
    }
    for (final input in gateway.submittedInputs.skip(1)) {
      expect(
        input['writingContext'],
        facts.toJson(first.contentFingerprint(saved.version.content)),
      );
    }
    expect(first.conversationFor(saved.document.id), hasLength(3));
    final restored = await _signedInService(gateway, reviewRepository: repo);
    await restored.restoreConversation(
      saved.document.id,
      saved.version.id,
      content: saved.version.content,
    );
    expect(
      restored
          .writingContextFor(saved.document.id, saved.version.id)
          .constraints,
      ['只改项目描述', '不要夸大职责'],
    );
    expect(
      restored
          .writingContextFor(saved.document.id, saved.version.id)
          .confirmedFacts,
      facts.confirmedFacts,
    );
    expect(gateway.submittedInputs, hasLength(5), reason: '本机确认和恢复不触网');
    await restored.restoreConversation(saved.document.id, 'changed-version');
    expect(
      restored.writingContextFor(saved.document.id, 'changed-version').isEmpty,
      isTrue,
    );
    gateway.owner = 'other-owner';
    final other = await _signedInService(gateway, reviewRepository: repo);
    await other.restoreConversation(saved.document.id, saved.version.id);
    expect(
      other.writingContextFor(saved.document.id, saved.version.id).isEmpty,
      isTrue,
    );
  });

  test('确认材料不跨简历共享，移除材料后恢复仍为空', () async {
    final db = LocalStorageDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftRemoteReviewRepository(db);
    final saved = _savedResume();
    final gateway = _BasicComposeGatewayApi(
      output: _noPatchConversationOutput('问题'),
    );
    final service = await _signedInService(gateway, reviewRepository: repo);
    await service.confirmWritingContext(
      document: saved.document,
      version: saved.version,
      context: RemoteWritingContext(constraints: ['保持中文']),
    );
    expect(
      service.writingContextFor('other-document', saved.version.id).isEmpty,
      isTrue,
    );
    await service.confirmWritingContext(
      document: saved.document,
      version: saved.version,
      context: RemoteWritingContext(),
    );
    final restored = await _signedInService(gateway, reviewRepository: repo);
    await restored.restoreConversation(saved.document.id, saved.version.id);
    expect(
      restored.writingContextFor(saved.document.id, saved.version.id).isEmpty,
      isTrue,
    );
    expect(gateway.submittedInputs, isEmpty);
  });

  for (final context in [
    RemoteWritingContext(confirmedFacts: {'/profile/fullName': '不应发送'}),
    RemoteWritingContext(confirmedFacts: {'/projects/99/summary': '不存在'}),
    RemoteWritingContext(
      confirmedFacts: {'/projects/0/summary': 'new@example.com'},
    ),
    RemoteWritingContext(confirmedFacts: {'/projects/0/summary': 'x' * 1001}),
    RemoteWritingContext(constraints: List.filled(13, '只改概述')),
    RemoteWritingContext(constraints: List.filled(7, 'x' * 500)),
  ]) {
    test(
      '非法AI材料在持久化和请求前拒绝：${context.confirmedFacts.keys}，长度${context.confirmedFacts.values.map((v) => v.length)}，要求${context.constraints.length}条',
      () async {
        final gateway = _BasicComposeGatewayApi(
          output: _noPatchConversationOutput('问题'),
        );
        final service = await _signedInService(gateway);
        final saved = _savedResume();
        await expectLater(
          service.confirmWritingContext(
            document: saved.document,
            version: saved.version,
            context: context,
          ),
          throwsA(isA<RemoteResumeAiInputException>()),
        );
        expect(
          service
              .writingContextFor(saved.document.id, saved.version.id)
              .isEmpty,
          isTrue,
        );
        expect(gateway.submittedInputs, isEmpty);
      },
    );
  }

  test('明确更正后的段落候选被标为事实变更供二次审阅', () async {
    final saved = _savedResume();
    final gateway = _BasicComposeGatewayApi(
      output: _validOptimizationOutput(
        outputVersion: 'targetedResumeOptimization.v1',
        oldHeadline: saved.version.content.profile.headline,
        newHeadline: '参与移动端开发',
      ),
      plan: GatewaySubscriptionPlan.pro,
    );
    final service = await _signedInService(gateway);
    await service.confirmWritingContext(
      document: saved.document,
      version: saved.version,
      context: RemoteWritingContext(
        confirmedFacts: {'/profile/headline': '参与移动端开发'},
      ),
    );
    final preparation = await service.prepareTargetedOptimization(
      document: saved.document,
      version: saved.version,
      targetJobTitle: '开发',
      jobDescription: '',
      userInstruction: '只改项目描述',
    );
    expect(preparation.pendingChange!.diff.containsFactChanges, isTrue);
    expect(saved.version.content.projects.single.summary, '本地优先的简历工具。');
  });
  test('持久材料过期后同一服务实例也清除内存，不重新上传旧事实', () async {
    final db = LocalStorageDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftRemoteReviewRepository(db);
    final saved = _savedResume();
    var now = DateTime.utc(2026, 10, 9);
    final gateway = _BasicComposeGatewayApi.queued(
      outputs: [
        _noPatchConversationOutput('第一轮'),
        _noPatchConversationOutput('新一轮'),
      ],
      plan: GatewaySubscriptionPlan.pro,
    );
    final service = await _signedInService(
      gateway,
      reviewRepository: repo,
      clock: () => now,
    );
    await service.confirmWritingContext(
      document: saved.document,
      version: saved.version,
      context: RemoteWritingContext(constraints: ['不要夸大职责']),
    );
    await service.prepareConversationTurn(
      document: saved.document,
      version: saved.version,
      targetJobTitle: '',
      jobDescription: '',
      userMessage: '核对事实',
    );
    expect(gateway.submittedInputs.first, contains('writingContext'));
    now = now.add(const Duration(days: 8));
    await service.prepareConversationTurn(
      document: saved.document,
      version: saved.version,
      targetJobTitle: '',
      jobDescription: '',
      userMessage: '新的请求',
    );
    expect(gateway.submittedInputs.last, isNot(contains('writingContext')));
    expect(gateway.submittedInputs.last['recentMessages'], isEmpty);
    expect(
      service.writingContextFor(saved.document.id, saved.version.id).isEmpty,
      isTrue,
    );
  });

  for (final count in [21, 30, 31]) {
    test('基础提问契约支持$count项时正确区分问题与非法响应', () async {
      final gateway = _BasicComposeGatewayApi(
        output: {
          ..._validBasicOutput(),
          'missingInformation': [
            for (var i = 0; i < count; i++)
              {'path': '/profile/headline', 'question': '请核对第$i项实际情况'},
          ],
        },
      );
      final service = await _signedInService(gateway);
      await expectLater(
        service.prepareBasicResumeCompose(
          BasicResumeComposeDraft(
            documentTitle: '材料确认',
            sourceText: '请帮我写简历',
            fullName: '',
            phone: '',
            email: '',
            preciseAddress: '',
          ),
        ),
        throwsA(
          count <= 30
              ? isA<RemoteResumeAiQuestions>().having(
                  (e) => e.questions.length,
                  '问题数量',
                  count,
                )
              : isA<RemoteResumeAiResponseException>(),
        ),
      );
      expect(gateway.submittedInputs, hasLength(1));
    });
  }

  test('合法最大材料与三轮对话能一起保留并恢复，不因旧32KiB上限丢失', () async {
    final db = LocalStorageDatabase.inMemory();
    addTearDown(db.close);
    final repo = DriftRemoteReviewRepository(db);
    final saved = _savedResume();
    final source = saved.version.content.toJson();
    final work = Map<String, Object?>.from(
      (source['workExperiences'] as List).single as Map,
    );
    work['highlights'] = ['建设离线数据层', '处理文件导入', '检查候选'];
    final content = ResumeData.fromJson({
      ...source,
      'workExperiences': [work],
    });
    final version = ResumeVersion(
      id: saved.version.id,
      documentId: saved.document.id,
      parentVersionId: null,
      schemaVersion: content.schemaVersion,
      content: content,
      source: ResumeVersionSource.edited,
      createdAt: saved.version.createdAt,
    );
    final gateway = _BasicComposeGatewayApi.queued(
      outputs: [
        for (var i = 0; i < 3; i++) _noPatchConversationOutput('检' * 200),
      ],
      plan: GatewaySubscriptionPlan.pro,
    );
    final service = await _signedInService(gateway, reviewRepository: repo);
    final context = RemoteWritingContext(
      confirmedFacts: {
        for (final field in remoteWritingFactFields(content))
          field.path: '事' * 1000,
      },
      constraints: [for (var i = 0; i < 6; i++) '${'要' * 498}$i'],
    );
    await service.confirmWritingContext(
      document: saved.document,
      version: version,
      context: context,
    );
    for (var i = 0; i < 3; i++) {
      final preparation = await service.prepareConversationTurn(
        document: saved.document,
        version: version,
        targetJobTitle: '',
        jobDescription: '',
        userMessage: '问' * 499,
      );
      expect(preparation.warnings.join(), isNot(contains('未能保存')));
    }
    final payload = await repo.readConversation(
      'owner',
      saved.document.id,
      DateTime.utc(2026, 10, 9),
    );
    expect(payload!.length, greaterThan(10000));
    final restored = await _signedInService(gateway, reviewRepository: repo);
    await restored.restoreConversation(
      saved.document.id,
      version.id,
      content: content,
    );
    expect(restored.conversationFor(saved.document.id), hasLength(3));
    expect(
      restored.writingContextFor(saved.document.id, version.id).confirmedFacts,
      context.confirmedFacts,
    );
    expect(gateway.submittedInputs, hasLength(3));
  });
}

Future<RemoteResumeAiService> _signedInService(
  GatewayApi gatewayApi, {
  DriftRemoteReviewRepository? reviewRepository,
  DateTime Function()? clock,
}) async {
  final accountService = RemoteAccountService(
    gatewayApi: gatewayApi,
    clock: () => DateTime.utc(2026, 10, 3, 12),
  );
  await accountService.signIn(
    phoneE164: '+15550001234',
    password: 'TestPass2026!',
  );
  var nextIdValue = 0;
  return RemoteResumeAiService(
    accountService: accountService,
    reviewRepository: reviewRepository,
    clock: clock ?? () => DateTime.utc(2026, 10, 9),
    nextId: (namespace) => '$namespace-${++nextIdValue}',
  );
}

({ResumeDocument document, ResumeVersion version}) _savedResume() {
  final content = ResumeData(
    profile: ResumeProfile(
      id: 'profile-001',
      fullName: '张三',
      headline: '移动端工程师',
      email: 'zhangsan@example.com',
      phone: '13800000000',
      location: '上海市浦东新区示例路 1 号',
      links: [
        ResumeLink(
          id: 'profile-link-1',
          label: '主页',
          url: 'https://example.com',
        ),
      ],
      extensions: const {'futurePrivateField': '不得发送'},
    ),
    workExperiences: [
      WorkExperience(
        id: 'work-001',
        organization: '示例科技',
        position: 'Flutter 工程师',
        dateRange: DateRange(
          start: ResumeDate(year: 2024, month: 1),
          end: null,
          isCurrent: true,
        ),
        summary: '负责移动端项目。',
        highlights: const ['建设离线数据层'],
      ),
    ],
    projects: [
      ProjectExperience(
        id: 'project-001',
        name: '简历全能帮',
        role: '开发者',
        dateRange: null,
        summary: '本地优先的简历工具。',
        links: [
          ResumeLink(
            id: 'project-link-1',
            label: '仓库',
            url: 'https://example.com/repo',
          ),
        ],
      ),
    ],
    unmapped: const {'原始备注': '不得发送'},
    extensions: const {'futureRootField': '不得发送'},
  );
  final createdAt = DateTime.utc(2026, 10, 3, 12);
  final version = ResumeVersion(
    id: 'version-001',
    documentId: 'document-001',
    parentVersionId: null,
    schemaVersion: content.schemaVersion,
    content: content,
    source: ResumeVersionSource.edited,
    createdAt: createdAt,
  );
  return (
    document: ResumeDocument(
      id: 'document-001',
      title: '求职简历',
      currentVersionId: version.id,
      createdAt: createdAt,
      updatedAt: createdAt,
    ),
    version: version,
  );
}

Map<String, Object?> _validOptimizationOutput({
  required String outputVersion,
  required String oldHeadline,
  required String newHeadline,
}) => {
  'outputVersion': outputVersion,
  'summary': '已根据目标岗位调整标题。',
  'proposedPatch': {
    'operations': [
      {
        'type': 'replace',
        'path': '/profile/headline',
        'oldValue': oldHeadline,
        'newValue': newHeadline,
        'reason': '让职业定位与目标岗位一致。',
        'source': 'remoteAi',
        'category': 'wording',
      },
    ],
  },
  'missingInformation': <Object?>[],
  'warnings': <Object?>[],
  'nextAction': 'reviewPatch',
};

Map<String, Object?> _noPatchConversationOutput(String summary) => {
  'outputVersion': 'resumeOptimizationConversation.v1',
  'summary': summary,
  'proposedPatch': null,
  'missingInformation': <Object?>[],
  'warnings': <Object?>[],
  'nextAction': 'none',
};

Map<String, Object?> _undatedEducationOutput() {
  final output =
      jsonDecode(jsonEncode(_validBasicOutput())) as Map<String, Object?>;
  final candidate = output['candidateResume']! as Map<String, Object?>;
  candidate['educations'] = <Object?>[
    {
      'id': 'candidate-education-1',
      'institution': '示例大学',
      'degree': '本科',
      'fieldOfStudy': '计算机',
      'dateRange': null,
      'highlights': ['2024年6月毕业'],
    },
  ];
  output['sourceReferences'] = [
    for (final path in ['/workExperiences/0', '/educations/0'])
      {
        'path': path,
        'fragmentIds': ['fragment-1'],
      },
  ];
  return output;
}

Map<String, Object?> _validBasicOutput() => {
  'outputVersion': 'basicResumeCompose.v1',
  'summary': '已按原始信息整理为基础简历。',
  'candidateResume': {
    'schemaVersion': '0.1.0',
    'profile': {
      'id': 'candidate-profile',
      'headline': 'Flutter 工程师',
      'coarseLocation': '',
    },
    'workExperiences': [
      {
        'id': 'candidate-work-1',
        'organization': '示例科技',
        'position': 'Flutter 工程师',
        'dateRange': {
          'start': {'year': 2024, 'month': 1},
          'end': null,
          'isCurrent': true,
        },
        'summary': '负责离线简历项目。',
        'highlights': ['使用 Flutter 和 Dart'],
      },
    ],
    'educations': <Object?>[],
    'projects': <Object?>[],
    'skillGroups': [
      {
        'id': 'candidate-skill-1',
        'name': '客户端开发',
        'skills': ['Flutter', 'Dart'],
      },
    ],
    'certifications': <Object?>[],
    'languages': <Object?>[],
    'customSections': <Object?>[],
  },
  'sourceReferences': [
    {
      'path': '/profile/headline',
      'fragmentIds': ['fragment-2'],
    },
    {
      'path': '/workExperiences/0/summary',
      'fragmentIds': ['fragment-1'],
    },
  ],
  'missingInformation': <Object?>[],
  'warnings': ['请核对经历时间。'],
};

final class _BasicComposeGatewayApi implements GatewayApi, GatewayOperationApi {
  String owner = 'owner';
  @override
  Future<String> readAccountId({required String sessionToken}) async => owner;
  @override
  Future<GatewayOperationStatus> lookupOperation({
    required String sessionToken,
    required RemoteAiCapability capability,
    String? usageOperationId,
    String? idempotencyKey,
  }) async => throw UnimplementedError();
  _BasicComposeGatewayApi({
    required Map<String, Object?> output,
    this.plan = GatewaySubscriptionPlan.free,
    this.outputBuilder,
  }) : _outputs = [output];

  _BasicComposeGatewayApi.queued({
    required List<Map<String, Object?>> outputs,
    this.plan = GatewaySubscriptionPlan.free,
  }) : _outputs = List.of(outputs),
       outputBuilder = null;

  final Map<String, Object?> Function(Map<String, Object?>)? outputBuilder;
  final List<Map<String, Object?>> _outputs;
  final GatewaySubscriptionPlan plan;
  final List<Map<String, Object?>> submittedInputs = [];

  @override
  Future<GatewaySession> createSession({
    required String phoneE164,
    required String password,
  }) async {
    return GatewaySession(
      token: 'session-token',
      expiresAtUtc: DateTime.utc(2026, 11, 2, 12),
    );
  }

  @override
  Future<GatewayAccessSnapshot> readAccess({
    required RemoteAiCapability capability,
    required String sessionToken,
  }) async {
    return GatewayAccessSnapshot(
      capability: capability,
      plan: plan,
      allowed:
          plan == GatewaySubscriptionPlan.pro ||
          capability == RemoteAiCapability.basicResumeCompose,
      reason:
          plan == GatewaySubscriptionPlan.pro ||
              capability == RemoteAiCapability.basicResumeCompose
          ? 'allowed'
          : 'subscription_required',
      remainingMonthlyBasicGenerations:
          capability == RemoteAiCapability.basicResumeCompose &&
              plan == GatewaySubscriptionPlan.free
          ? 10
          : null,
    );
  }

  @override
  Future<GatewayRemoteAiResponse> submitRemoteAiRequest({
    required String sessionToken,
    required String clientRequestId,
    required String idempotencyKey,
    required RemoteAiCapability capability,
    required Map<String, Object?> input,
  }) async {
    submittedInputs.add(input);
    final outputIndex = submittedInputs.length - 1;
    if (outputIndex >= _outputs.length) {
      throw StateError('测试未提供第 ${outputIndex + 1} 个远程响应');
    }
    return GatewayRemoteAiResponse(
      operationId: 'operation-${outputIndex + 1}',
      clientRequestId: clientRequestId,
      capability: capability,
      output: outputBuilder?.call(input) ?? _outputs[outputIndex],
      promptVersion: 'basic-resume-compose.v1',
    );
  }

  @override
  Future<void> registerFakeAccount({
    required String phoneE164,
    required String password,
  }) async {}

  @override
  void close() {}
}
