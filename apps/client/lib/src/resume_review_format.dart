const _fieldLabels = <String, String>{
  'profile': '基本信息',
  'headline': '意向职业岗位',
  'fullName': '姓名',
  'phone': '电话',
  'email': '邮箱',
  'location': '所在地',
  'coarseLocation': '所在地',
  'preciseAddress': '所在地',
  'links': '个人链接',
  'photo': '证件照',
  'workExperiences': '工作经历',
  'organization': '单位',
  'position': '岗位',
  'dateRange': '时间',
  'start': '开始时间',
  'end': '结束时间',
  'isCurrent': '持续至今',
  'year': '年',
  'month': '月',
  'summary': '描述',
  'highlights': '要点',
  'educations': '教育经历',
  'institution': '学校',
  'degree': '学历',
  'fieldOfStudy': '专业',
  'projects': '项目经历',
  'role': '参与角色',
  'name': '名称',
  'skillGroups': '技能',
  'skills': '技能条目',
  'certifications': '证书',
  'issuer': '颁发机构',
  'issuedOn': '取得时间',
  'expiresOn': '到期时间',
  'languages': '语言',
  'proficiency': '掌握程度',
  'customSections': '补充经历',
  'items': '内容',
  'title': '标题',
  'description': '说明',
  'url': '链接',
  'label': '名称',
  'unmapped': '其他资料',
};

String resumeReviewFieldLabel(String path) {
  final parts = path.split('/').skip(1).where((part) => part.isNotEmpty);
  final labels = parts.map((part) {
    if (part == '-') return '新增';
    final index = int.tryParse(part);
    if (index != null) return '第${index + 1}项';
    return _fieldLabels[part] ?? '其他信息';
  }).toList();
  return labels.isEmpty ? '简历' : labels.join(' · ');
}

/// Presentation only: leaves candidate values and patches untouched.
String formatResumeReviewValue(Object? value) {
  if (value == null || value == '') return '未填写';
  if (value is String) return value;
  if (value is bool) return value ? '是' : '否';
  if (value is List) {
    if (value.isEmpty) return '未填写';
    return value.map((item) => '• ${formatResumeReviewValue(item)}').join('\n');
  }
  if (value is Map) {
    if (value['year'] is int &&
        value.keys.every((key) => key == 'year' || key == 'month')) {
      final month = value['month'];
      return '${value['year']}年${month is int ? '$month月' : ''}';
    }
    if (value.containsKey('start') &&
        value.containsKey('isCurrent') &&
        value.keys.every(
          (key) => const {'start', 'end', 'isCurrent'}.contains(key),
        )) {
      final end = value['isCurrent'] == true
          ? '至今'
          : value['end'] == null
          ? '结束时间未填写'
          : formatResumeReviewValue(value['end']);
      return '${formatResumeReviewValue(value['start'])} — $end';
    }
    final lines = <String>[];
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final child = entry.value;
      if (key == 'id' ||
          key == 'schemaVersion' ||
          child == null ||
          child == '' ||
          child is List && child.isEmpty ||
          child is Map && child.isEmpty) {
        continue;
      }
      final label = _fieldLabels[key] ?? key;
      final text = key == 'proficiency'
          ? const {
                  'native': '母语',
                  'fluent': '流利',
                  'professional': '工作熟练',
                  'intermediate': '中级',
                  'basic': '基础',
                  'unspecified': '未填写',
                }[child] ??
                child.toString()
          : formatResumeReviewValue(child);
      lines.add('$label：${child is List || child is Map ? '\n' : ''}$text');
    }
    return lines.isEmpty ? '未填写' : lines.join('\n');
  }
  return value.toString();
}

String formatResumeReviewNotice(String text) {
  final paths = RegExp(
    r'/(?:profile|workExperiences|educations|projects|skillGroups|certifications|languages|customSections)(?:/[A-Za-z0-9_~.-]+)*',
  );
  final readable = text.replaceAllMapped(
    paths,
    (match) => resumeReviewFieldLabel(match[0]!),
  );
  final fields = RegExp('\\b(${_fieldLabels.keys.join('|')})\\b');
  return readable.replaceAllMapped(fields, (match) => _fieldLabels[match[0]]!);
}
