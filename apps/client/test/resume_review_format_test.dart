import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/resume_review_format.dart';

void main() {
  test('项目和技能展示正文，内部ID和JSON语法不进入审阅', () {
    final value = {
      'id': 'candidate-project-1',
      'name': '图书检索页面练习',
      'role': '',
      'dateRange': null,
      'summary': '参与页面练习，并协助接口联调',
      'highlights': ['和同学协作使用Vue'],
      'links': <Object?>[],
    };
    final before = value.toString();
    final text = formatResumeReviewValue(value);
    expect(text, contains('名称：图书检索页面练习'));
    expect(text, contains('描述：参与页面练习，并协助接口联调'));
    expect(text, contains('• 和同学协作使用Vue'));
    expect(text, isNot(contains('candidate-project')));
    expect(text, isNot(contains('dateRange')));
    expect(value.toString(), before, reason: '呈现不修改候选或Patch');
  });
  test('时间和未知资料保持真实，清空用未填写表示', () {
    expect(
      formatResumeReviewValue({
        'start': {'year': 2024, 'month': 3},
        'end': null,
        'isCurrent': false,
      }),
      '2024年3月 — 结束时间未填写',
    );
    expect(
      formatResumeReviewValue({
        'start': {'year': 2024},
        'end': null,
        'isCurrent': true,
      }),
      '2024年 — 至今',
    );
    expect(formatResumeReviewValue({'自定义说明': '不能丢失的原文'}), '自定义说明：不能丢失的原文');
    expect(formatResumeReviewValue(''), '未填写');
  });
  test('字段路径和模型说明改成可读名称，值里的文字不被改写', () {
    expect(
      resumeReviewFieldLabel('/projects/0/highlights/1'),
      '项目经历 · 第1项 · 要点 · 第2项',
    );
    expect(resumeReviewFieldLabel('/skillGroups/-'), '技能 · 新增');
    expect(
      formatResumeReviewNotice('未提供教育背景，educations已留空；请核对/projects/0/summary。'),
      '未提供教育背景，教育经历已留空；请核对项目经历 · 第1项 · 描述。',
    );
    expect(formatResumeReviewValue('项目原名是projects，不能改名'), '项目原名是projects，不能改名');
  });
}
