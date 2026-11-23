import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/app_theme.dart';
import 'package:resume_all_in_one_client/src/resume_collection_editor.dart';
import 'package:resume_domain/resume_domain.dart';

void main() {
  testWidgets('八类区段都能通过普通表单添加条目且稳定 ID 各不相同', (tester) async {
    final ids = <String>{};
    for (final section in _fixtures.entries) {
      final controller = TextEditingController(text: '[]');
      await _pumpCollection(tester, section.key, controller);
      await _tap(tester, ValueKey('${section.key}_add'));
      final fields = switch (section.key) {
        'links' => {'label': '个人主页', 'url': 'https://example.org'},
        'workExperiences' => {'organization': '示例公司', 'position': '设计师'},
        'educations' => {'institution': '示例大学'},
        'customSections' => {'title': '志愿服务'},
        _ => {'name': '示例条目'},
      };
      for (final field in fields.entries) {
        await _enter(tester, ValueKey('条目字段_${field.key}'), field.value);
      }
      if (section.key == 'workExperiences' || section.key == 'educations') {
        await _enter(tester, const Key('条目日期_start_year'), '2024');
      }
      await _tap(tester, const Key('完成条目编辑'));
      expect(find.byKey(const Key('完成条目编辑')), findsNothing);
      final savedEntry = _entries(controller).single;
      expect(savedEntry['id'], isNotEmpty);
      expect(ids.add(savedEntry['id']! as String), isTrue);
      for (final field in fields.entries) {
        expect(savedEntry[field.key], field.value);
      }
      if (savedEntry['dateRange'] case final Map dateRange) {
        expect(dateRange['start'], {'year': 2024, 'month': null});
        expect(dateRange['end'], isNull);
        expect(dateRange['isCurrent'], false);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
  });

  testWidgets('未改动表单往返保留全部区段原值未知字段日期精度与稳定 ID', (tester) async {
    for (final section in _fixtures.entries) {
      final original = section.value;
      final controller = TextEditingController(text: jsonEncode([original]));
      await _pumpCollection(tester, section.key, controller);
      await _tap(tester, ValueKey('${section.key}_entry_${original['id']}'));
      await _tap(tester, const Key('完成条目编辑'));
      expect(find.byKey(const Key('完成条目编辑')), findsNothing);
      expect(jsonDeepEquals(_entries(controller).single, original), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
  });

  testWidgets('修改已知工作字段保留日期及多层扩展且取消不会改写草稿', (tester) async {
    final original = _fixtures['workExperiences']!;
    final controller = TextEditingController(text: jsonEncode([original]));
    await _pumpCollection(tester, 'workExperiences', controller);
    await _tap(tester, const Key('workExperiences_entry_work-original'));
    await _enter(tester, const Key('条目字段_position'), '高级设计师');
    await _tap(tester, const Key('取消条目编辑'));
    await _tap(tester, const Key('放弃条目修改'));
    expect(jsonDeepEquals(_entries(controller).single, original), isTrue);

    await _tap(tester, const Key('workExperiences_entry_work-original'));
    await _enter(tester, const Key('条目字段_position'), '高级设计师');
    await _enter(tester, const Key('条目日期_start_month'), '5');
    await _tap(tester, const Key('完成条目编辑'));
    final updated = _entries(controller).single;
    expect(updated['id'], 'work-original');
    expect(updated['position'], '高级设计师');
    expect(updated['futureField'], original['futureField']);
    final range = updated['dateRange']! as Map;
    expect(range['rangeExtension'], '保留范围扩展');
    expect(range['start'], {
      'year': 2020,
      'month': 5,
      'dateExtension': {'precisionSource': 'user'},
    });
    expect(range['end'], (original['dateRange']! as Map)['end']);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('项目内链接和自定义内容使用逐项表单并保留嵌套未知字段', (tester) async {
    for (final sectionKey in ['projects', 'customSections']) {
      final original = _fixtures[sectionKey]!;
      final nestedKey = sectionKey == 'projects' ? 'links' : 'items';
      final nestedField = sectionKey == 'projects' ? 'label' : 'description';
      final nestedOriginal = (original[nestedKey]! as List).single as Map;
      final controller = TextEditingController(text: jsonEncode([original]));
      await _pumpCollection(tester, sectionKey, controller);
      await _tap(tester, ValueKey('${sectionKey}_entry_${original['id']}'));
      await _tap(
        tester,
        ValueKey('${nestedKey}_entry_${nestedOriginal['id']}'),
      );
      await _enter(tester, ValueKey('条目字段_$nestedField'), '用户修改后的内容');
      await _tap(tester, const Key('完成条目编辑'));
      await _tap(tester, const Key('完成条目编辑'));
      final saved = _entries(controller).single;
      final nestedSaved = (saved[nestedKey]! as List).single as Map;
      expect(nestedSaved['id'], nestedOriginal['id']);
      expect(nestedSaved[nestedField], '用户修改后的内容');
      expect(nestedSaved['nestedExtension'], nestedOriginal['nestedExtension']);
      expect(saved['futureField'], original['futureField']);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
  });

  testWidgets('条目排序和确认删除只改变目标集合不重建实体 ID', (tester) async {
    final first = _fixtures['languages']!;
    final second = {...first, 'id': 'language-second', 'name': '英语'};
    final controller = TextEditingController(text: jsonEncode([first, second]));
    await _pumpCollection(tester, 'languages', controller);
    await _tap(tester, const Key('languages_menu_language-second'));
    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    expect(_entries(controller).map((entry) => entry['id']), [
      'language-second',
      first['id'],
    ]);
    await _tap(tester, const Key('languages_menu_language-second'));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(_entries(controller), hasLength(2));
    await _tap(tester, const Key('languages_menu_language-second'));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(jsonDeepEquals(_entries(controller), [first]), isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('非法网址日期顺序和未填写必填项均阻止完成且不改原草稿', (tester) async {
    final controller = TextEditingController(text: '[]');
    await _pumpCollection(tester, 'links', controller);
    await _tap(tester, const Key('links_add'));
    await _tap(tester, const Key('完成条目编辑'));
    expect(find.text('请填写链接名称'), findsOneWidget);
    expect(controller.text, '[]');
    await _enter(tester, const Key('条目字段_label'), '主页');
    await _enter(tester, const Key('条目字段_url'), 'file:///private');
    await _tap(tester, const Key('完成条目编辑'));
    expect(find.text('必须是绝对 HTTP/HTTPS URL'), findsOneWidget);
    expect(controller.text, '[]');
    await _tap(tester, const Key('取消条目编辑'));
    await _tap(tester, const Key('放弃条目修改'));
    await tester.pumpWidget(const SizedBox());
    controller.text = jsonEncode([_fixtures['workExperiences']]);
    await _pumpCollection(tester, 'workExperiences', controller);
    final initialText = controller.text;
    await _tap(tester, const Key('workExperiences_entry_work-original'));
    await _enter(tester, const Key('条目日期_start_year'), '2025');
    await _tap(tester, const Key('完成条目编辑'));
    expect(find.text('结束日期不能早于开始日期'), findsOneWidget);
    expect(controller.text, initialText);
    await _enter(tester, const Key('条目日期_start_year'), '2020');
    await _enter(tester, const Key('条目日期_start_month'), '13');
    await _tap(tester, const Key('完成条目编辑'));
    expect(find.text('请输入 1–12 之间的月份，或留空'), findsOneWidget);
    expect(controller.text, initialText);
    await _tap(tester, const Key('取消条目编辑'));
    await _tap(tester, const Key('放弃条目修改'));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('至今不会静默删除结束日期且用户可显式移除日期', (tester) async {
    final controller = TextEditingController(
      text: jsonEncode([_fixtures['workExperiences']]),
    );
    await _pumpCollection(tester, 'workExperiences', controller);
    final initialText = controller.text;
    await _tap(tester, const Key('workExperiences_entry_work-original'));
    await _tap(tester, const Key('条目日期_至今'));
    await _tap(tester, const Key('完成条目编辑'));
    expect(find.text('当前经历不能设置结束日期'), findsOneWidget);
    expect(controller.text, initialText);
    await _tap(tester, const Key('条目日期_end_开关'));
    await _tap(tester, const Key('完成条目编辑'));
    final dateRange = _entries(controller).single['dateRange']! as Map;
    expect(dateRange['isCurrent'], true);
    expect(dateRange['end'], isNull);
    expect(dateRange['rangeExtension'], '保留范围扩展');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('逐条技能和成果保留空白与换行并允许排序', (tester) async {
    final original = _fixtures['skillGroups']!;
    final controller = TextEditingController(text: jsonEncode([original]));
    await _pumpCollection(tester, 'skillGroups', controller);
    await _tap(tester, const Key('skillGroups_entry_skills-original'));
    await _tap(tester, const Key('条目数组添加_skills'));
    await _enter(tester, const Key('条目数组_skills_2'), ' 新技能\n细节 ');
    await _tap(tester, const Key('条目数组操作_skills_2'));
    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    await _tap(tester, const Key('完成条目编辑'));
    expect(_entries(controller).single['skills'], [
      ' Dart ',
      ' 新技能\n细节 ',
      'Flutter\n应用开发',
    ]);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('可选项目时间证书日期与语言程度可修改且不猜测未知月份', (tester) async {
    final controller = TextEditingController(
      text: jsonEncode([_fixtures['projects']]),
    );
    await _pumpCollection(tester, 'projects', controller);
    await _tap(tester, const Key('projects_entry_project-original'));
    final projectDates = find.widgetWithText(SwitchListTile, '填写项目时间');
    await tester.ensureVisible(projectDates);
    await tester.tap(projectDates);
    await tester.pumpAndSettle();
    await _enter(tester, const Key('条目日期_start_year'), '2023');
    await _tap(tester, const Key('完成条目编辑'));
    expect(_entries(controller).single['dateRange'], {
      'start': {'year': 2023, 'month': null},
      'end': null,
      'isCurrent': false,
    });
    await tester.pumpWidget(const SizedBox());

    controller.text = jsonEncode([_fixtures['certifications']]);
    await _pumpCollection(tester, 'certifications', controller);
    await _tap(tester, const Key('certifications_entry_cert-original'));
    await _enter(tester, const Key('条目日期_issuedOn_month'), '9');
    await _tap(tester, const Key('条目日期_expiresOn_开关'));
    await _enter(tester, const Key('条目日期_expiresOn_year'), '2028');
    await _tap(tester, const Key('完成条目编辑'));
    expect(_entries(controller).single['issuedOn'], {
      'year': 2020,
      'month': 9,
      'dateExtension': {'keep': 1},
    });
    expect(_entries(controller).single['expiresOn'], {
      'year': 2028,
      'month': null,
    });
    await tester.pumpWidget(const SizedBox());

    controller.text = jsonEncode([_fixtures['languages']]);
    await _pumpCollection(tester, 'languages', controller);
    await _tap(tester, const Key('languages_entry_language-original'));
    await _tap(tester, const Key('条目字段_proficiency'));
    await tester.tap(find.text('专业工作水平').last);
    await tester.pumpAndSettle();
    await _tap(tester, const Key('完成条目编辑'));
    expect(_entries(controller).single['proficiency'], 'professional');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('320 宽两倍文字下每种条目可滚动编辑并完成而无布局异常', (tester) async {
    tester.view.reset();
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final section in _fixtures.entries) {
      final controller = TextEditingController(
        text: jsonEncode([section.value]),
      );
      await _pumpCollection(tester, section.key, controller, textScale: 2);
      await _tap(
        tester,
        ValueKey('${section.key}_entry_${section.value['id']}'),
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, const Key('完成条目编辑'));
      expect(find.byKey(const Key('完成条目编辑')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
  });

  testWidgets('无法读取集合时展示恢复提示而不会清空控制器', (tester) async {
    final controller = TextEditingController(text: '[invalid');
    await _pumpCollection(tester, 'links', controller);
    expect(find.textContaining('原内容仍保留'), findsOneWidget);
    expect(controller.text, '[invalid');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('${brightness.name} 下 320×640 双倍文字与 240 键盘并存仍能编辑八类条目', (
      tester,
    ) async {
      _setCompactViewport(tester);
      for (final section in _fixtures.entries) {
        final controller = TextEditingController(
          text: jsonEncode([section.value]),
        );
        await _pumpCollection(
          tester,
          section.key,
          controller,
          textScale: 2,
          brightness: brightness,
        );
        await _tap(
          tester,
          ValueKey('${section.key}_entry_${section.value['id']}'),
        );
        final field = switch (section.key) {
          'links' => 'url',
          'workExperiences' => 'position',
          'educations' => 'fieldOfStudy',
          'customSections' => 'title',
          _ => 'name',
        };
        await _enter(
          tester,
          ValueKey('条目字段_$field'),
          section.value[field]! as String,
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(ValueKey('条目字段_$field')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('条目字段_$field')).hitTestable(),
          findsOneWidget,
        );
        _expectKeyboardActions(tester);
        await _tap(tester, const Key('完成条目编辑'));
        expect(find.byKey(const Key('完成条目编辑')), findsNothing);
        expect(
          jsonDeepEquals(_entries(controller).single, section.value),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      }
    });
  }

  testWidgets('窄屏键盘与双倍文字下必填和日期错误均可见且仍可修正完成', (tester) async {
    _setCompactViewport(tester);
    final controller = TextEditingController(
      text: jsonEncode([_fixtures['workExperiences']]),
    );
    await _pumpCollection(tester, 'workExperiences', controller, textScale: 2);
    await _tap(tester, const Key('workExperiences_entry_work-original'));
    await _enter(tester, const Key('条目字段_organization'), '');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    await _tap(tester, const Key('完成条目编辑'));
    expect(find.text('请检查标红的必填项或日期。').hitTestable(), findsOneWidget);
    _expectKeyboardActions(tester);
    await _enter(tester, const Key('条目字段_organization'), '示例组织');
    await _enter(tester, const Key('条目日期_start_year'), '2025');
    await _tap(tester, const Key('完成条目编辑'));
    expect(find.text('结束日期不能早于开始日期').hitTestable(), findsOneWidget);
    _expectKeyboardActions(tester);
    await _enter(tester, const Key('条目日期_start_year'), '2020');
    await _tap(tester, const Key('完成条目编辑'));
    expect(find.byKey(const Key('完成条目编辑')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('系统返回不丢条目草稿，未改动直接退出而修改后需明确放弃', (tester) async {
    final original = _fixtures['workExperiences']!;
    final controller = TextEditingController(text: jsonEncode([original]));
    await _pumpCollection(tester, 'workExperiences', controller);
    await _tap(tester, const Key('workExperiences_entry_work-original'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('完成条目编辑')), findsNothing);
    expect(find.text('放弃这条修改？'), findsNothing);

    await _tap(tester, const Key('workExperiences_entry_work-original'));
    await _enter(tester, const Key('条目字段_position'), '未保存的职位');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃这条修改？'), findsOneWidget);
    await _tap(tester, const Key('继续填写条目'));
    final positionInput = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('条目字段_position')),
        matching: find.byType(EditableText),
      ),
    );
    expect(positionInput.controller.text, '未保存的职位');
    expect(jsonDeepEquals(_entries(controller).single, original), isTrue);
    await _tap(tester, const Key('取消条目编辑'));
    expect(find.text('放弃这条修改？'), findsOneWidget);
    await _tap(tester, const Key('放弃条目修改'));
    expect(find.byKey(const Key('完成条目编辑')), findsNothing);
    expect(jsonDeepEquals(_entries(controller).single, original), isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('窄屏键盘与双倍文字下嵌套条目和父区段分别保护未保存修改', (tester) async {
    _setCompactViewport(tester);
    final original = _fixtures['customSections']!;
    final controller = TextEditingController(text: jsonEncode([original]));
    await _pumpCollection(tester, 'customSections', controller, textScale: 2);
    await _tap(tester, const Key('customSections_entry_section-original'));
    await _tap(tester, const Key('items_entry_custom-item-original'));
    await _enter(tester, const Key('条目字段_description'), '嵌套条目的新内容');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pumpAndSettle();
    _expectKeyboardActions(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃这条修改？'), findsOneWidget);
    expect(find.byKey(const Key('继续填写条目')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, const Key('继续填写条目'));
    await _tap(tester, const Key('完成条目编辑'));
    _expectKeyboardActions(tester);
    expect(jsonDeepEquals(_entries(controller).single, original), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃这条修改？'), findsOneWidget);
    await _tap(tester, const Key('继续填写条目'));
    await _tap(tester, const Key('完成条目编辑'));
    final nested =
        (_entries(controller).single['items']! as List).single as Map;
    expect(nested['description'], '嵌套条目的新内容');
    expect(
      nested['nestedExtension'],
      ((original['items']! as List).single as Map)['nestedExtension'],
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}

void _setCompactViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

void _expectKeyboardActions(WidgetTester tester) {
  for (final key in ['完成条目编辑', '取消条目编辑']) {
    final action = find.byKey(Key(key)).last;
    expect(action.hitTestable(), findsOneWidget);
    expect(tester.getRect(action).bottom, lessThanOrEqualTo(400));
    expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
  }
  expect(tester.takeException(), isNull);
}

Future<void> _pumpCollection(
  WidgetTester tester,
  String sectionKey,
  TextEditingController controller, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ResumeCollectionEditor(
            sectionKey: sectionKey,
            controller: controller,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key).last;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, Key key, String text) async {
  final finder = find.byKey(key).last;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

List<JsonMap> _entries(TextEditingController controller) =>
    (jsonDecode(controller.text) as List)
        .map((entry) => Map<String, Object?>.from(entry as Map))
        .toList();

final _fixtures = <String, JsonMap>{
  'links': {
    'id': 'link-original',
    'label': '个人主页',
    'url': 'https://example.org',
    'futureField': {
      'source': ['用户', 1],
    },
  },
  'workExperiences': {
    'id': 'work-original',
    'organization': '示例组织',
    'position': '设计师',
    'summary': ' 原概述\n保留换行 ',
    'dateRange': {
      'start': {
        'year': 2020,
        'month': null,
        'dateExtension': {'precisionSource': 'user'},
      },
      'end': {'year': 2024, 'month': 3, 'endExtension': '原值'},
      'isCurrent': false,
      'rangeExtension': '保留范围扩展',
    },
    'highlights': [' 首项成果 ', '多行\n成果', ''],
    'futureField': {
      'source': ['用户', 2],
    },
  },
  'educations': {
    'id': 'education-original',
    'institution': '示例大学',
    'degree': '',
    'fieldOfStudy': '设计',
    'dateRange': {
      'start': {'year': 2015, 'month': null, 'source': '原值'},
      'end': null,
      'isCurrent': false,
      'source': '原值',
    },
    'highlights': [],
    'futureField': {'preserve': true},
  },
  'projects': {
    'id': 'project-original',
    'name': '示例项目',
    'role': '',
    'dateRange': null,
    'summary': '',
    'highlights': [''],
    'links': [
      {
        'id': 'project-link-original',
        'label': '项目页',
        'url': 'https://example.org/project',
        'nestedExtension': {
          'nested': ['不应丢失'],
        },
      },
    ],
    'futureField': {'preserve': true},
  },
  'skillGroups': {
    'id': 'skills-original',
    'name': '开发',
    'skills': [' Dart ', 'Flutter\n应用开发'],
    'futureField': {'preserve': true},
  },
  'certifications': {
    'id': 'cert-original',
    'name': '示例证书',
    'issuer': '',
    'issuedOn': {
      'year': 2020,
      'month': null,
      'dateExtension': {'keep': 1},
    },
    'expiresOn': null,
    'credentialId': '',
    'credentialUrl': '',
    'futureField': {'preserve': true},
  },
  'languages': {
    'id': 'language-original',
    'name': '中文',
    'proficiency': 'native',
    'futureField': {'preserve': true},
  },
  'customSections': {
    'id': 'section-original',
    'title': '志愿服务',
    'items': [
      {
        'id': 'custom-item-original',
        'title': '社区服务',
        'description': ' 原始内容\n继续 ',
        'nestedExtension': {
          'keep': [1, 2],
        },
      },
    ],
    'futureField': {'preserve': true},
  },
};
