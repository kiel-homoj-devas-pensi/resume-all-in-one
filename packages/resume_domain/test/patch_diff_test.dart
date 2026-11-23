import 'dart:io';

import 'package:resume_domain/resume_domain.dart';
import 'package:test/test.dart';

ResumeData _fixture() => const CanonicalResumeCodec().decode(
  File('test/fixtures/resume_v0_1.json').readAsStringSync(),
);

void main() {
  group('ResumePatch 与 ResumeDiff', () {
    test('replace 产生新对象且不修改原版本', () {
      final original = _fixture();
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/profile/headline',
          oldValue: '移动端工程师',
          newValue: '资深移动端工程师',
          reason: '让职位定位更清晰',
          source: 'test',
          category: ResumeChangeCategory.wording,
        ),
      ]);

      final updated = patch.apply(original);

      expect(original.profile.headline, '移动端工程师');
      expect(updated.profile.headline, '资深移动端工程师');
      expect(identical(original, updated), isFalse);
    });

    test('add、remove 和反向 Patch 可恢复原内容', () {
      final original = _fixture();
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.add,
          path: '/skillGroups/0/skills/2',
          oldValue: null,
          newValue: 'SQLite',
          reason: '补充已确认技能',
          source: 'test',
          category: ResumeChangeCategory.fact,
        ),
        ResumePatchOperation(
          type: PatchOperationType.remove,
          path: '/projects/0/highlights/0',
          oldValue: '定义 Canonical Resume Schema',
          newValue: null,
          reason: '删除重复描述',
          source: 'test',
          category: ResumeChangeCategory.wording,
        ),
      ]);

      final updated = patch.apply(original);
      final restored = patch.reversed().apply(updated);

      expect(updated.skillGroups.single.skills, contains('SQLite'));
      expect(updated.projects.single.highlights, isEmpty);
      expect(jsonDeepEquals(restored.toJson(), original.toJson()), isTrue);
    });

    test('旧值不匹配时拒绝 Patch', () {
      final original = _fixture();
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/profile/fullName',
          oldValue: '李四',
          newValue: '王五',
          reason: '模拟过期 Patch',
          source: 'test',
          category: ResumeChangeCategory.fact,
        ),
      ]);

      expect(() => patch.apply(original), throwsA(isA<PatchApplyException>()));
      expect(original.profile.fullName, '张三');
    });

    test('Patch 可以结构化 round-trip，未知枚举被拒绝', () {
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/profile/headline',
          oldValue: '移动端工程师',
          newValue: 'Flutter 工程师',
          reason: '精简职位定位',
          source: 'test',
          category: ResumeChangeCategory.wording,
        ),
      ]);

      final decoded = ResumePatch.fromJson(patch.toJson());
      expect(jsonDeepEquals(decoded.toJson(), patch.toJson()), isTrue);

      final invalid = patch.toJson();
      final operations = invalid['operations']! as List<Object?>;
      final operation = operations.single as Map<String, Object?>;
      operation['category'] = 'unknown';
      expect(
        () => ResumePatch.fromJson(invalid),
        throwsA(isA<SchemaFormatException>()),
      );
    });

    test('导致 Schema 无效的 Patch 被 validation 阻止', () {
      final original = _fixture();
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/profile/links/0/url',
          oldValue: 'https://github.com/example',
          newValue: 'not-a-url',
          reason: '模拟非法结果',
          source: 'test',
          category: ResumeChangeCategory.fact,
        ),
      ]);

      expect(
        () => patch.apply(original),
        throwsA(isA<ResumeValidationException>()),
      );
      expect(original.profile.links.single.url, 'https://github.com/example');
    });

    test('Diff 可定位路径并区分事实、措辞和格式变化', () {
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/profile/fullName',
          oldValue: '张三',
          newValue: '张三丰',
          reason: '用户确认姓名',
          source: 'test',
          category: ResumeChangeCategory.fact,
        ),
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/profile/headline',
          oldValue: '移动端工程师',
          newValue: 'Flutter 工程师',
          reason: '精简措辞',
          source: 'test',
          category: ResumeChangeCategory.wording,
        ),
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/profile/location',
          oldValue: '上海',
          newValue: '上海市',
          reason: '统一格式',
          source: 'test',
          category: ResumeChangeCategory.format,
        ),
      ]);

      final diff = ResumeDiff.fromPatch(patch);

      expect(diff.entries, hasLength(3));
      expect(diff.containsFactChanges, isTrue);
      expect(diff.countByCategory(ResumeChangeCategory.wording), 1);
      expect(diff.countByCategory(ResumeChangeCategory.format), 1);
      expect(diff.entries.first.summary, contains('/profile/fullName'));
    });

    test('拒绝 Patch 时返回原对象且不生成修改内容', () {
      final original = _fixture();
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/profile/headline',
          oldValue: '移动端工程师',
          newValue: '其他描述',
          reason: '待审阅建议',
          source: 'test',
          category: ResumeChangeCategory.wording,
        ),
      ]);

      final result = const ResumePatchReviewer().reject(original, patch);

      expect(result.decision, PatchReviewDecision.rejected);
      expect(identical(result.content, original), isTrue);
      expect(result.diff.entries, hasLength(1));
    });

    test('使用 /- 追加时明确拒绝生成不确定的反向 Patch', () {
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.add,
          path: '/skillGroups/0/skills/-',
          oldValue: null,
          newValue: 'SQLite',
          reason: '追加技能',
          source: 'test',
          category: ResumeChangeCategory.fact,
        ),
      ]);

      expect(patch.reversed, throwsStateError);
    });

    test('JSON Pointer 转义可以定位包含斜杠的未知字段', () {
      final original = ResumeData(
        profile: ResumeProfile(
          id: 'profile-pointer',
          fullName: '张三',
          headline: '',
          email: '',
          phone: '',
          location: '',
        ),
        extensions: const {'future/field': 'old'},
      );
      final patch = ResumePatch([
        ResumePatchOperation(
          type: PatchOperationType.replace,
          path: '/future~1field',
          oldValue: 'old',
          newValue: 'new',
          reason: '验证 JSON Pointer 转义',
          source: 'test',
          category: ResumeChangeCategory.format,
        ),
      ]);

      final updated = patch.apply(original);
      expect(updated.extensions['future/field'], 'new');
    });
  });
}
