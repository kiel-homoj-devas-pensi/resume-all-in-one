import 'json_support.dart';
import 'model.dart';
import 'patch.dart';

final class ResumeDiffEntry {
  ResumeDiffEntry({
    required this.path,
    required this.operation,
    required this.category,
    required Object? oldValue,
    required Object? newValue,
    required this.reason,
    required this.source,
    required this.summary,
  }) : oldValue = deepFreezeJson(oldValue),
       newValue = deepFreezeJson(newValue);

  final String path;
  final PatchOperationType operation;
  final ResumeChangeCategory category;
  final Object? oldValue;
  final Object? newValue;
  final String reason;
  final String source;
  final String summary;

  JsonMap toJson() => {
    'path': path,
    'operation': operation.name,
    'category': category.name,
    'oldValue': deepCopyJson(oldValue),
    'newValue': deepCopyJson(newValue),
    'reason': reason,
    'source': source,
    'summary': summary,
  };
}

final class ResumeDiff {
  ResumeDiff(List<ResumeDiffEntry> entries)
    : entries = List<ResumeDiffEntry>.unmodifiable(entries);

  factory ResumeDiff.fromPatch(ResumePatch patch) {
    return ResumeDiff(
      patch.operations.map((operation) {
        final action = switch (operation.type) {
          PatchOperationType.add => '新增',
          PatchOperationType.remove => '删除',
          PatchOperationType.replace => '修改',
        };
        return ResumeDiffEntry(
          path: operation.path,
          operation: operation.type,
          category: operation.category,
          oldValue: operation.oldValue,
          newValue: operation.newValue,
          reason: operation.reason,
          source: operation.source,
          summary: '$action ${operation.path}：${operation.reason}',
        );
      }).toList(),
    );
  }

  final List<ResumeDiffEntry> entries;

  int countByCategory(ResumeChangeCategory category) {
    return entries.where((entry) => entry.category == category).length;
  }

  bool get containsFactChanges =>
      countByCategory(ResumeChangeCategory.fact) > 0;

  JsonMap toJson() => {
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };
}

enum PatchReviewDecision { accepted, rejected }

final class PatchReviewResult {
  const PatchReviewResult({
    required this.decision,
    required this.content,
    required this.diff,
  });

  final PatchReviewDecision decision;
  final ResumeData content;
  final ResumeDiff diff;
}

final class ResumePatchReviewer {
  const ResumePatchReviewer();

  PatchReviewResult accept(ResumeData original, ResumePatch patch) {
    return PatchReviewResult(
      decision: PatchReviewDecision.accepted,
      content: patch.apply(original),
      diff: ResumeDiff.fromPatch(patch),
    );
  }

  PatchReviewResult reject(ResumeData original, ResumePatch patch) {
    return PatchReviewResult(
      decision: PatchReviewDecision.rejected,
      content: patch.reject(original),
      diff: ResumeDiff.fromPatch(patch),
    );
  }
}
