import 'json_support.dart';
import 'photo.dart';

const currentResumeSchemaVersion = '0.1.0';

List<T> _objectList<T>(
  Object? value,
  String path,
  T Function(JsonMap value, String path) decode,
) {
  final source = expectList(value, path);
  return List<T>.unmodifiable(
    source.indexed.map(
      (entry) =>
          decode(expectMap(entry.$2, '$path/${entry.$1}'), '$path/${entry.$1}'),
    ),
  );
}

final class ResumeDate implements Comparable<ResumeDate> {
  ResumeDate({
    required this.year,
    this.month,
    Map<String, Object?> extensions = const {},
  }) : extensions = freezeJsonMap(extensions) {
    if (year < 1900 || year > 2200) {
      schemaError(r'$.year', '年份必须在 1900 到 2200 之间');
    }
    if (month != null && (month! < 1 || month! > 12)) {
      schemaError(r'$.month', '月份必须在 1 到 12 之间');
    }
  }

  factory ResumeDate.fromJson(JsonMap json, [String path = r'$']) {
    return ResumeDate(
      year: expectInt(json['year'], '$path/year'),
      month: json['month'] == null
          ? null
          : expectInt(json['month'], '$path/month'),
      extensions: unknownFields(json, const {'year', 'month'}),
    );
  }

  final int year;
  final int? month;
  final JsonMap extensions;

  JsonMap toJson() => {...extensions, 'year': year, 'month': month};

  @override
  int compareTo(ResumeDate other) {
    final yearResult = year.compareTo(other.year);
    if (yearResult != 0) {
      return yearResult;
    }
    return (month ?? 1).compareTo(other.month ?? 1);
  }
}

final class DateRange {
  DateRange({
    required this.start,
    required this.end,
    required this.isCurrent,
    Map<String, Object?> extensions = const {},
  }) : extensions = freezeJsonMap(extensions) {
    if (isCurrent && end != null) {
      schemaError(r'$.end', '当前经历不能设置结束日期');
    }
    if (end != null && end!.compareTo(start) < 0) {
      schemaError(r'$.end', '结束日期不能早于开始日期');
    }
  }

  factory DateRange.fromJson(JsonMap json, [String path = r'$']) {
    return DateRange(
      start: ResumeDate.fromJson(
        expectMap(json['start'], '$path/start'),
        '$path/start',
      ),
      end: json['end'] == null
          ? null
          : ResumeDate.fromJson(
              expectMap(json['end'], '$path/end'),
              '$path/end',
            ),
      isCurrent: expectBool(json['isCurrent'], '$path/isCurrent'),
      extensions: unknownFields(json, const {'start', 'end', 'isCurrent'}),
    );
  }

  final ResumeDate start;
  final ResumeDate? end;
  final bool isCurrent;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'start': start.toJson(),
    'end': end?.toJson(),
    'isCurrent': isCurrent,
  };
}

final class ResumeLink {
  ResumeLink({
    required this.id,
    required this.label,
    required this.url,
    Map<String, Object?> extensions = const {},
  }) : extensions = freezeJsonMap(extensions);

  factory ResumeLink.fromJson(JsonMap json, [String path = r'$']) {
    return ResumeLink(
      id: expectString(json['id'], '$path/id'),
      label: expectString(json['label'], '$path/label'),
      url: expectString(json['url'], '$path/url'),
      extensions: unknownFields(json, const {'id', 'label', 'url'}),
    );
  }

  final String id;
  final String label;
  final String url;
  final JsonMap extensions;

  JsonMap toJson() => {...extensions, 'id': id, 'label': label, 'url': url};
}

final class ResumeProfile {
  ResumeProfile({
    required this.id,
    required this.fullName,
    required this.headline,
    required this.email,
    required this.phone,
    required this.location,
    this.photo,
    List<ResumeLink> links = const [],
    Map<String, Object?> extensions = const {},
  }) : links = List<ResumeLink>.unmodifiable(links),
       extensions = freezeJsonMap(extensions);

  factory ResumeProfile.fromJson(JsonMap json, [String path = r'$']) {
    return ResumeProfile(
      id: expectString(json['id'], '$path/id'),
      fullName: expectString(json['fullName'], '$path/fullName'),
      headline: expectString(json['headline'], '$path/headline'),
      email: expectString(json['email'], '$path/email'),
      phone: expectString(json['phone'], '$path/phone'),
      location: expectString(json['location'], '$path/location'),
      photo: json['photo'] == null
          ? null
          : ResumePhoto.fromJson(
              expectMap(json['photo'], '$path/photo'),
              '$path/photo',
            ),
      links: _objectList(json['links'], '$path/links', ResumeLink.fromJson),
      extensions: unknownFields(json, const {
        'id',
        'fullName',
        'headline',
        'email',
        'phone',
        'location',
        'photo',
        'links',
      }),
    );
  }

  final String id;
  final String fullName;
  final String headline;
  final String email;
  final String phone;
  final String location;
  final ResumePhoto? photo;
  final List<ResumeLink> links;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'fullName': fullName,
    'headline': headline,
    'email': email,
    'phone': phone,
    'location': location,
    if (photo != null) 'photo': photo!.toJson(),
    'links': links.map((item) => item.toJson()).toList(),
  };
}

final class WorkExperience {
  WorkExperience({
    required this.id,
    required this.organization,
    required this.position,
    required this.dateRange,
    required this.summary,
    List<String> highlights = const [],
    Map<String, Object?> extensions = const {},
  }) : highlights = List<String>.unmodifiable(highlights),
       extensions = freezeJsonMap(extensions);

  factory WorkExperience.fromJson(JsonMap json, [String path = r'$']) {
    return WorkExperience(
      id: expectString(json['id'], '$path/id'),
      organization: expectString(json['organization'], '$path/organization'),
      position: expectString(json['position'], '$path/position'),
      dateRange: DateRange.fromJson(
        expectMap(json['dateRange'], '$path/dateRange'),
        '$path/dateRange',
      ),
      summary: expectString(json['summary'], '$path/summary'),
      highlights: expectStringList(json['highlights'], '$path/highlights'),
      extensions: unknownFields(json, const {
        'id',
        'organization',
        'position',
        'dateRange',
        'summary',
        'highlights',
      }),
    );
  }

  final String id;
  final String organization;
  final String position;
  final DateRange dateRange;
  final String summary;
  final List<String> highlights;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'organization': organization,
    'position': position,
    'dateRange': dateRange.toJson(),
    'summary': summary,
    'highlights': highlights,
  };
}

final class Education {
  Education({
    required this.id,
    required this.institution,
    required this.degree,
    required this.fieldOfStudy,
    required this.dateRange,
    List<String> highlights = const [],
    Map<String, Object?> extensions = const {},
  }) : highlights = List<String>.unmodifiable(highlights),
       extensions = freezeJsonMap(extensions);

  factory Education.fromJson(JsonMap json, [String path = r'$']) {
    return Education(
      id: expectString(json['id'], '$path/id'),
      institution: expectString(json['institution'], '$path/institution'),
      degree: expectString(json['degree'], '$path/degree'),
      fieldOfStudy: expectString(json['fieldOfStudy'], '$path/fieldOfStudy'),
      dateRange: DateRange.fromJson(
        expectMap(json['dateRange'], '$path/dateRange'),
        '$path/dateRange',
      ),
      highlights: expectStringList(json['highlights'], '$path/highlights'),
      extensions: unknownFields(json, const {
        'id',
        'institution',
        'degree',
        'fieldOfStudy',
        'dateRange',
        'highlights',
      }),
    );
  }

  final String id;
  final String institution;
  final String degree;
  final String fieldOfStudy;
  final DateRange dateRange;
  final List<String> highlights;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'institution': institution,
    'degree': degree,
    'fieldOfStudy': fieldOfStudy,
    'dateRange': dateRange.toJson(),
    'highlights': highlights,
  };
}

final class ProjectExperience {
  ProjectExperience({
    required this.id,
    required this.name,
    required this.role,
    required this.dateRange,
    required this.summary,
    List<String> highlights = const [],
    List<ResumeLink> links = const [],
    Map<String, Object?> extensions = const {},
  }) : highlights = List<String>.unmodifiable(highlights),
       links = List<ResumeLink>.unmodifiable(links),
       extensions = freezeJsonMap(extensions);

  factory ProjectExperience.fromJson(JsonMap json, [String path = r'$']) {
    return ProjectExperience(
      id: expectString(json['id'], '$path/id'),
      name: expectString(json['name'], '$path/name'),
      role: expectString(json['role'], '$path/role'),
      dateRange: json['dateRange'] == null
          ? null
          : DateRange.fromJson(
              expectMap(json['dateRange'], '$path/dateRange'),
              '$path/dateRange',
            ),
      summary: expectString(json['summary'], '$path/summary'),
      highlights: expectStringList(json['highlights'], '$path/highlights'),
      links: _objectList(json['links'], '$path/links', ResumeLink.fromJson),
      extensions: unknownFields(json, const {
        'id',
        'name',
        'role',
        'dateRange',
        'summary',
        'highlights',
        'links',
      }),
    );
  }

  final String id;
  final String name;
  final String role;
  final DateRange? dateRange;
  final String summary;
  final List<String> highlights;
  final List<ResumeLink> links;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'name': name,
    'role': role,
    'dateRange': dateRange?.toJson(),
    'summary': summary,
    'highlights': highlights,
    'links': links.map((item) => item.toJson()).toList(),
  };
}

final class SkillGroup {
  SkillGroup({
    required this.id,
    required this.name,
    List<String> skills = const [],
    Map<String, Object?> extensions = const {},
  }) : skills = List<String>.unmodifiable(skills),
       extensions = freezeJsonMap(extensions);

  factory SkillGroup.fromJson(JsonMap json, [String path = r'$']) {
    return SkillGroup(
      id: expectString(json['id'], '$path/id'),
      name: expectString(json['name'], '$path/name'),
      skills: expectStringList(json['skills'], '$path/skills'),
      extensions: unknownFields(json, const {'id', 'name', 'skills'}),
    );
  }

  final String id;
  final String name;
  final List<String> skills;
  final JsonMap extensions;

  JsonMap toJson() => {...extensions, 'id': id, 'name': name, 'skills': skills};
}

final class Certification {
  Certification({
    required this.id,
    required this.name,
    required this.issuer,
    required this.issuedOn,
    required this.expiresOn,
    required this.credentialId,
    required this.credentialUrl,
    Map<String, Object?> extensions = const {},
  }) : extensions = freezeJsonMap(extensions) {
    if (issuedOn != null &&
        expiresOn != null &&
        expiresOn!.compareTo(issuedOn!) < 0) {
      schemaError(r'$.expiresOn', '证书过期日期不能早于颁发日期');
    }
  }

  factory Certification.fromJson(JsonMap json, [String path = r'$']) {
    ResumeDate? date(String key) {
      final value = json[key];
      return value == null
          ? null
          : ResumeDate.fromJson(expectMap(value, '$path/$key'), '$path/$key');
    }

    return Certification(
      id: expectString(json['id'], '$path/id'),
      name: expectString(json['name'], '$path/name'),
      issuer: expectString(json['issuer'], '$path/issuer'),
      issuedOn: date('issuedOn'),
      expiresOn: date('expiresOn'),
      credentialId: expectString(json['credentialId'], '$path/credentialId'),
      credentialUrl: expectString(json['credentialUrl'], '$path/credentialUrl'),
      extensions: unknownFields(json, const {
        'id',
        'name',
        'issuer',
        'issuedOn',
        'expiresOn',
        'credentialId',
        'credentialUrl',
      }),
    );
  }

  final String id;
  final String name;
  final String issuer;
  final ResumeDate? issuedOn;
  final ResumeDate? expiresOn;
  final String credentialId;
  final String credentialUrl;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'name': name,
    'issuer': issuer,
    'issuedOn': issuedOn?.toJson(),
    'expiresOn': expiresOn?.toJson(),
    'credentialId': credentialId,
    'credentialUrl': credentialUrl,
  };
}

enum LanguageProficiency {
  native,
  fluent,
  professional,
  intermediate,
  basic,
  unspecified,
}

LanguageProficiency _parseProficiency(Object? value, String path) {
  final name = expectString(value, path);
  for (final candidate in LanguageProficiency.values) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  schemaError(path, '未知语言熟练度：$name');
}

final class ResumeLanguage {
  ResumeLanguage({
    required this.id,
    required this.name,
    required this.proficiency,
    Map<String, Object?> extensions = const {},
  }) : extensions = freezeJsonMap(extensions);

  factory ResumeLanguage.fromJson(JsonMap json, [String path = r'$']) {
    return ResumeLanguage(
      id: expectString(json['id'], '$path/id'),
      name: expectString(json['name'], '$path/name'),
      proficiency: _parseProficiency(json['proficiency'], '$path/proficiency'),
      extensions: unknownFields(json, const {'id', 'name', 'proficiency'}),
    );
  }

  final String id;
  final String name;
  final LanguageProficiency proficiency;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'name': name,
    'proficiency': proficiency.name,
  };
}

final class CustomSectionItem {
  CustomSectionItem({
    required this.id,
    required this.title,
    required this.description,
    Map<String, Object?> extensions = const {},
  }) : extensions = freezeJsonMap(extensions);

  factory CustomSectionItem.fromJson(JsonMap json, [String path = r'$']) {
    return CustomSectionItem(
      id: expectString(json['id'], '$path/id'),
      title: expectString(json['title'], '$path/title'),
      description: expectString(json['description'], '$path/description'),
      extensions: unknownFields(json, const {'id', 'title', 'description'}),
    );
  }

  final String id;
  final String title;
  final String description;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'title': title,
    'description': description,
  };
}

final class CustomSection {
  CustomSection({
    required this.id,
    required this.title,
    List<CustomSectionItem> items = const [],
    Map<String, Object?> extensions = const {},
  }) : items = List<CustomSectionItem>.unmodifiable(items),
       extensions = freezeJsonMap(extensions);

  factory CustomSection.fromJson(JsonMap json, [String path = r'$']) {
    return CustomSection(
      id: expectString(json['id'], '$path/id'),
      title: expectString(json['title'], '$path/title'),
      items: _objectList(
        json['items'],
        '$path/items',
        CustomSectionItem.fromJson,
      ),
      extensions: unknownFields(json, const {'id', 'title', 'items'}),
    );
  }

  final String id;
  final String title;
  final List<CustomSectionItem> items;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'title': title,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

final class ResumeData {
  ResumeData({
    this.schemaVersion = currentResumeSchemaVersion,
    required this.profile,
    List<WorkExperience> workExperiences = const [],
    List<Education> educations = const [],
    List<ProjectExperience> projects = const [],
    List<SkillGroup> skillGroups = const [],
    List<Certification> certifications = const [],
    List<ResumeLanguage> languages = const [],
    List<CustomSection> customSections = const [],
    Map<String, Object?> unmapped = const {},
    Map<String, Object?> extensions = const {},
  }) : workExperiences = List<WorkExperience>.unmodifiable(workExperiences),
       educations = List<Education>.unmodifiable(educations),
       projects = List<ProjectExperience>.unmodifiable(projects),
       skillGroups = List<SkillGroup>.unmodifiable(skillGroups),
       certifications = List<Certification>.unmodifiable(certifications),
       languages = List<ResumeLanguage>.unmodifiable(languages),
       customSections = List<CustomSection>.unmodifiable(customSections),
       unmapped = freezeJsonMap(unmapped),
       extensions = freezeJsonMap(extensions) {
    if (schemaVersion != currentResumeSchemaVersion) {
      schemaError(r'$.schemaVersion', '不支持的 Schema 版本：$schemaVersion');
    }
  }

  factory ResumeData.fromJson(JsonMap json, [String path = r'$']) {
    return ResumeData(
      schemaVersion: expectString(json['schemaVersion'], '$path/schemaVersion'),
      profile: ResumeProfile.fromJson(
        expectMap(json['profile'], '$path/profile'),
        '$path/profile',
      ),
      workExperiences: _objectList(
        json['workExperiences'],
        '$path/workExperiences',
        WorkExperience.fromJson,
      ),
      educations: _objectList(
        json['educations'],
        '$path/educations',
        Education.fromJson,
      ),
      projects: _objectList(
        json['projects'],
        '$path/projects',
        ProjectExperience.fromJson,
      ),
      skillGroups: _objectList(
        json['skillGroups'],
        '$path/skillGroups',
        SkillGroup.fromJson,
      ),
      certifications: _objectList(
        json['certifications'],
        '$path/certifications',
        Certification.fromJson,
      ),
      languages: _objectList(
        json['languages'],
        '$path/languages',
        ResumeLanguage.fromJson,
      ),
      customSections: _objectList(
        json['customSections'],
        '$path/customSections',
        CustomSection.fromJson,
      ),
      unmapped: expectMap(json['unmapped'], '$path/unmapped'),
      extensions: unknownFields(json, const {
        'schemaVersion',
        'profile',
        'workExperiences',
        'educations',
        'projects',
        'skillGroups',
        'certifications',
        'languages',
        'customSections',
        'unmapped',
      }),
    );
  }

  final String schemaVersion;
  final ResumeProfile profile;
  final List<WorkExperience> workExperiences;
  final List<Education> educations;
  final List<ProjectExperience> projects;
  final List<SkillGroup> skillGroups;
  final List<Certification> certifications;
  final List<ResumeLanguage> languages;
  final List<CustomSection> customSections;
  final JsonMap unmapped;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'schemaVersion': schemaVersion,
    'profile': profile.toJson(),
    'workExperiences': workExperiences.map((item) => item.toJson()).toList(),
    'educations': educations.map((item) => item.toJson()).toList(),
    'projects': projects.map((item) => item.toJson()).toList(),
    'skillGroups': skillGroups.map((item) => item.toJson()).toList(),
    'certifications': certifications.map((item) => item.toJson()).toList(),
    'languages': languages.map((item) => item.toJson()).toList(),
    'customSections': customSections.map((item) => item.toJson()).toList(),
    'unmapped': deepCopyJson(unmapped),
  };
}

enum ResumeVersionSource {
  created,
  edited,
  imported,
  aiConfirmed,
  restored,
  migrated,
}

ResumeVersionSource _parseVersionSource(Object? value, String path) {
  final name = expectString(value, path);
  for (final candidate in ResumeVersionSource.values) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  schemaError(path, '未知版本来源：$name');
}

final class ResumeDocument {
  ResumeDocument({
    required this.id,
    required this.title,
    required this.currentVersionId,
    required this.createdAt,
    required this.updatedAt,
    Map<String, Object?> metadata = const {},
    Map<String, Object?> extensions = const {},
  }) : metadata = freezeJsonMap(metadata),
       extensions = freezeJsonMap(extensions);

  factory ResumeDocument.fromJson(JsonMap json, [String path = r'$']) {
    return ResumeDocument(
      id: expectString(json['id'], '$path/id'),
      title: expectString(json['title'], '$path/title'),
      currentVersionId: optionalString(
        json['currentVersionId'],
        '$path/currentVersionId',
      ),
      createdAt: expectTimestamp(json['createdAt'], '$path/createdAt'),
      updatedAt: expectTimestamp(json['updatedAt'], '$path/updatedAt'),
      metadata: expectMap(json['metadata'], '$path/metadata'),
      extensions: unknownFields(json, const {
        'id',
        'title',
        'currentVersionId',
        'createdAt',
        'updatedAt',
        'metadata',
      }),
    );
  }

  final String id;
  final String title;
  final String? currentVersionId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final JsonMap metadata;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'title': title,
    'currentVersionId': currentVersionId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'metadata': deepCopyJson(metadata),
  };
}

final class ResumeVersion {
  ResumeVersion({
    required this.id,
    required this.documentId,
    required this.parentVersionId,
    required this.schemaVersion,
    required this.content,
    required this.source,
    required this.createdAt,
    Map<String, Object?> extensions = const {},
  }) : extensions = freezeJsonMap(extensions) {
    if (schemaVersion != content.schemaVersion) {
      schemaError(r'$.schemaVersion', '版本与内容的 Schema 版本不一致');
    }
  }

  factory ResumeVersion.fromJson(JsonMap json, [String path = r'$']) {
    return ResumeVersion(
      id: expectString(json['id'], '$path/id'),
      documentId: expectString(json['documentId'], '$path/documentId'),
      parentVersionId: optionalString(
        json['parentVersionId'],
        '$path/parentVersionId',
      ),
      schemaVersion: expectString(json['schemaVersion'], '$path/schemaVersion'),
      content: ResumeData.fromJson(
        expectMap(json['content'], '$path/content'),
        '$path/content',
      ),
      source: _parseVersionSource(json['source'], '$path/source'),
      createdAt: expectTimestamp(json['createdAt'], '$path/createdAt'),
      extensions: unknownFields(json, const {
        'id',
        'documentId',
        'parentVersionId',
        'schemaVersion',
        'content',
        'source',
        'createdAt',
      }),
    );
  }

  final String id;
  final String documentId;
  final String? parentVersionId;
  final String schemaVersion;
  final ResumeData content;
  final ResumeVersionSource source;
  final DateTime createdAt;
  final JsonMap extensions;

  JsonMap toJson() => {
    ...extensions,
    'id': id,
    'documentId': documentId,
    'parentVersionId': parentVersionId,
    'schemaVersion': schemaVersion,
    'content': content.toJson(),
    'source': source.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}
