import 'model.dart';

enum ValidationSeverity { info, warning, error }

final class ValidationIssue {
  const ValidationIssue({
    required this.path,
    required this.severity,
    required this.ruleId,
    required this.message,
    required this.blocksCommit,
  });

  final String path;
  final ValidationSeverity severity;
  final String ruleId;
  final String message;
  final bool blocksCommit;
}

final class ResumeValidationResult {
  ResumeValidationResult(List<ValidationIssue> issues)
    : issues = List<ValidationIssue>.unmodifiable(issues);

  final List<ValidationIssue> issues;

  bool get isValid => !issues.any((issue) => issue.blocksCommit);
}

final class ResumeValidationException implements Exception {
  ResumeValidationException(this.result);

  final ResumeValidationResult result;

  @override
  String toString() {
    final errors = result.issues.where((issue) => issue.blocksCommit);
    return 'ResumeValidationException: '
        '${errors.map((issue) => '${issue.path}: ${issue.message}').join('; ')}';
  }
}

final class ResumeValidator {
  const ResumeValidator();

  ResumeValidationResult validate(ResumeData resume) {
    final issues = <ValidationIssue>[];
    final ids = <String, String>{};

    void error(String path, String ruleId, String message) {
      issues.add(
        ValidationIssue(
          path: path,
          severity: ValidationSeverity.error,
          ruleId: ruleId,
          message: message,
          blocksCommit: true,
        ),
      );
    }

    void warning(String path, String ruleId, String message) {
      issues.add(
        ValidationIssue(
          path: path,
          severity: ValidationSeverity.warning,
          ruleId: ruleId,
          message: message,
          blocksCommit: false,
        ),
      );
    }

    void validateId(String id, String path) {
      if (id.trim().isEmpty) {
        error(path, 'stable_id.required', '实体 ID 不能为空');
        return;
      }
      final previousPath = ids[id];
      if (previousPath != null) {
        error(path, 'stable_id.unique', '实体 ID 与 $previousPath 重复');
      } else {
        ids[id] = path;
      }
    }

    void requireNonEmptyText(String text, String path, String ruleId) {
      if (text.trim().isEmpty) {
        error(path, ruleId, '必填文本不能为空');
      }
    }

    void validateAbsoluteHttpUrl(String urlText, String path) {
      if (urlText.trim().isEmpty) {
        return;
      }
      final parsedUrl = Uri.tryParse(urlText);
      if (parsedUrl == null ||
          !parsedUrl.isAbsolute ||
          (parsedUrl.scheme != 'http' && parsedUrl.scheme != 'https') ||
          parsedUrl.host.isEmpty) {
        error(path, 'url.http_absolute', '必须是绝对 HTTP/HTTPS URL');
      }
    }

    void validateLink(ResumeLink link, String path) {
      validateId(link.id, '$path/id');
      requireNonEmptyText(link.label, '$path/label', 'link.label.required');
      validateAbsoluteHttpUrl(link.url, '$path/url');
    }

    // ID 在整份简历内全局去重，Patch 才能跨区段稳定定位同一个实体。
    validateId(resume.profile.id, '/profile/id');
    if (resume.profile.fullName.trim().isEmpty) {
      warning('/profile/fullName', 'profile.name.recommended', '建议填写姓名');
    }
    if (resume.profile.phone.trim().isEmpty &&
        resume.profile.email.trim().isEmpty &&
        resume.profile.links.isEmpty) {
      warning(
        '/profile',
        'profile.contact.recommended',
        '建议提供一种联系方式，便于联系；无需填写所有联系方式',
      );
    }
    if (resume.profile.phone.trim().isNotEmpty) {
      final phone = resume.profile.phone.trim();
      final digits = phone.replaceAll(RegExp(r'[+\s()\-]'), '');
      if (!RegExp(r'^\+?[0-9\s()\-]+$').hasMatch(phone) ||
          digits.length < 7 ||
          digits.length > 15) {
        warning('/profile/phone', 'profile.phone.format', '请核对联系电话的格式和位数');
      }
    }
    if (resume.profile.email.isNotEmpty &&
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(resume.profile.email)) {
      error('/profile/email', 'email.format', '邮箱格式无效');
    }
    for (final indexedLink in resume.profile.links.indexed) {
      validateLink(indexedLink.$2, '/profile/links/${indexedLink.$1}');
    }

    for (final indexedWorkExperience in resume.workExperiences.indexed) {
      final workExperience = indexedWorkExperience.$2;
      final path = '/workExperiences/${indexedWorkExperience.$1}';
      validateId(workExperience.id, '$path/id');
      requireNonEmptyText(
        workExperience.organization,
        '$path/organization',
        'work.organization.required',
      );
      requireNonEmptyText(
        workExperience.position,
        '$path/position',
        'work.position.required',
      );
    }

    for (final indexedEducation in resume.educations.indexed) {
      final education = indexedEducation.$2;
      final path = '/educations/${indexedEducation.$1}';
      validateId(education.id, '$path/id');
      requireNonEmptyText(
        education.institution,
        '$path/institution',
        'education.institution.required',
      );
    }

    for (final indexedProject in resume.projects.indexed) {
      final project = indexedProject.$2;
      final path = '/projects/${indexedProject.$1}';
      validateId(project.id, '$path/id');
      requireNonEmptyText(project.name, '$path/name', 'project.name.required');
      for (final indexedProjectLink in project.links.indexed) {
        validateLink(
          indexedProjectLink.$2,
          '$path/links/${indexedProjectLink.$1}',
        );
      }
    }

    for (final indexedSkillGroup in resume.skillGroups.indexed) {
      final skillGroup = indexedSkillGroup.$2;
      final path = '/skillGroups/${indexedSkillGroup.$1}';
      validateId(skillGroup.id, '$path/id');
      requireNonEmptyText(
        skillGroup.name,
        '$path/name',
        'skill_group.name.required',
      );
      for (final indexedSkill in skillGroup.skills.indexed) {
        if (indexedSkill.$2.trim().isEmpty) {
          error(
            '$path/skills/${indexedSkill.$1}',
            'skill.value.required',
            '技能项不能为空',
          );
        }
      }
    }

    for (final indexedCertification in resume.certifications.indexed) {
      final certification = indexedCertification.$2;
      final path = '/certifications/${indexedCertification.$1}';
      validateId(certification.id, '$path/id');
      requireNonEmptyText(
        certification.name,
        '$path/name',
        'certification.name.required',
      );
      validateAbsoluteHttpUrl(
        certification.credentialUrl,
        '$path/credentialUrl',
      );
    }

    for (final indexedLanguage in resume.languages.indexed) {
      final language = indexedLanguage.$2;
      final path = '/languages/${indexedLanguage.$1}';
      validateId(language.id, '$path/id');
      requireNonEmptyText(
        language.name,
        '$path/name',
        'language.name.required',
      );
    }

    for (final indexedCustomSection in resume.customSections.indexed) {
      final customSection = indexedCustomSection.$2;
      final path = '/customSections/${indexedCustomSection.$1}';
      validateId(customSection.id, '$path/id');
      requireNonEmptyText(
        customSection.title,
        '$path/title',
        'custom_section.title.required',
      );
      for (final indexedCustomItem in customSection.items.indexed) {
        final customItem = indexedCustomItem.$2;
        final customItemPath = '$path/items/${indexedCustomItem.$1}';
        validateId(customItem.id, '$customItemPath/id');
        requireNonEmptyText(
          customItem.title,
          '$customItemPath/title',
          'custom_section.item.title.required',
        );
      }
    }

    if (resume.unmapped.isNotEmpty) {
      warning('/unmapped', 'unmapped.review_required', '存在尚未映射的导入内容，需要用户确认');
    }

    return ResumeValidationResult(issues);
  }
}
