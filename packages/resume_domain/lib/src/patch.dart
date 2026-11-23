import 'json_support.dart';
import 'model.dart';
import 'validation.dart';

enum PatchOperationType { add, remove, replace }

enum ResumeChangeCategory { fact, wording, format }

final class ResumePatchOperation {
  ResumePatchOperation({
    required this.type,
    required this.path,
    required Object? oldValue,
    required Object? newValue,
    required this.reason,
    required this.source,
    required this.category,
  }) : oldValue = deepFreezeJson(oldValue),
       newValue = deepFreezeJson(newValue) {
    if (!path.startsWith('/') || path == '/') {
      throw ArgumentError.value(path, 'path', '必须是非根 JSON Pointer');
    }
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', '理由不能为空');
    }
    if (source.trim().isEmpty) {
      throw ArgumentError.value(source, 'source', '来源不能为空');
    }
  }

  final PatchOperationType type;
  final String path;
  final Object? oldValue;
  final Object? newValue;
  final String reason;
  final String source;
  final ResumeChangeCategory category;

  factory ResumePatchOperation.fromJson(JsonMap json, [String path = r'$']) {
    if (!json.containsKey('oldValue') || !json.containsKey('newValue')) {
      schemaError(path, 'Patch 操作必须显式包含 oldValue 和 newValue');
    }
    return ResumePatchOperation(
      type: _parseOperationType(json['type'], '$path/type'),
      path: expectString(json['path'], '$path/path'),
      oldValue: json['oldValue'],
      newValue: json['newValue'],
      reason: expectString(json['reason'], '$path/reason'),
      source: expectString(json['source'], '$path/source'),
      category: _parseChangeCategory(json['category'], '$path/category'),
    );
  }

  JsonMap toJson() => {
    'type': type.name,
    'path': path,
    'oldValue': deepCopyJson(oldValue),
    'newValue': deepCopyJson(newValue),
    'reason': reason,
    'source': source,
    'category': category.name,
  };

  ResumePatchOperation reversed() {
    if (type == PatchOperationType.add && path.endsWith('/-')) {
      throw StateError('使用 /- 追加的操作没有确定索引，不能直接生成反向 Patch');
    }
    return switch (type) {
      PatchOperationType.add => ResumePatchOperation(
        type: PatchOperationType.remove,
        path: path,
        oldValue: newValue,
        newValue: null,
        reason: '撤销：$reason',
        source: source,
        category: category,
      ),
      PatchOperationType.remove => ResumePatchOperation(
        type: PatchOperationType.add,
        path: path,
        oldValue: null,
        newValue: oldValue,
        reason: '撤销：$reason',
        source: source,
        category: category,
      ),
      PatchOperationType.replace => ResumePatchOperation(
        type: PatchOperationType.replace,
        path: path,
        oldValue: newValue,
        newValue: oldValue,
        reason: '撤销：$reason',
        source: source,
        category: category,
      ),
    };
  }
}

final class PatchApplyException implements Exception {
  const PatchApplyException(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => 'PatchApplyException($path): $message';
}

final class ResumePatch {
  ResumePatch(List<ResumePatchOperation> operations)
    : operations = List<ResumePatchOperation>.unmodifiable(operations) {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', 'Patch 不能为空');
    }
  }

  final List<ResumePatchOperation> operations;

  factory ResumePatch.fromJson(JsonMap json, [String path = r'$']) {
    final source = expectList(json['operations'], '$path/operations');
    return ResumePatch(
      source.indexed.map((entry) {
        final itemPath = '$path/operations/${entry.$1}';
        return ResumePatchOperation.fromJson(
          expectMap(entry.$2, itemPath),
          itemPath,
        );
      }).toList(),
    );
  }

  JsonMap toJson() => {
    'operations': operations.map((operation) => operation.toJson()).toList(),
  };

  ResumeData apply(
    ResumeData original, {
    ResumeValidator validator = const ResumeValidator(),
  }) {
    final root = deepCopyJson(original.toJson())! as Map<String, Object?>;
    for (final operation in operations) {
      _applyOperation(root, operation);
    }
    final updated = ResumeData.fromJson(root);
    final validation = validator.validate(updated);
    if (!validation.isValid) {
      throw ResumeValidationException(validation);
    }
    return updated;
  }

  ResumeData reject(ResumeData original) => original;

  ResumePatch reversed() {
    return ResumePatch(
      operations.reversed.map((operation) => operation.reversed()).toList(),
    );
  }
}

PatchOperationType _parseOperationType(Object? value, String path) {
  final name = expectString(value, path);
  for (final candidate in PatchOperationType.values) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  schemaError(path, '未知 Patch 操作类型：$name');
}

ResumeChangeCategory _parseChangeCategory(Object? value, String path) {
  final name = expectString(value, path);
  for (final candidate in ResumeChangeCategory.values) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  schemaError(path, '未知变更类别：$name');
}

void _applyOperation(
  Map<String, Object?> root,
  ResumePatchOperation operation,
) {
  final segments = _decodePointer(operation.path);
  final parent = _resolveParent(root, segments, operation.path);
  final token = segments.last;

  if (parent is Map<String, Object?>) {
    _applyToMap(parent, token, operation);
    return;
  }
  if (parent is List<Object?>) {
    _applyToList(parent, token, operation);
    return;
  }
  throw PatchApplyException(operation.path, '父节点不是 object 或 array');
}

List<String> _decodePointer(String pointer) {
  final tokens = pointer.substring(1).split('/');
  return tokens.map((token) {
    if (RegExp(r'~(?![01])').hasMatch(token)) {
      throw PatchApplyException(pointer, 'JSON Pointer 转义无效');
    }
    return token.replaceAll('~1', '/').replaceAll('~0', '~');
  }).toList();
}

Object _resolveParent(
  Map<String, Object?> root,
  List<String> segments,
  String path,
) {
  Object current = root;
  for (final token in segments.take(segments.length - 1)) {
    if (current is Map<String, Object?>) {
      if (!current.containsKey(token)) {
        throw PatchApplyException(path, '路径不存在');
      }
      final next = current[token];
      if (next is! Object) {
        throw PatchApplyException(path, '路径经过 null');
      }
      current = next;
      continue;
    }
    if (current is List<Object?>) {
      final index = _parseIndex(token, current.length, path);
      if (index >= current.length) {
        throw PatchApplyException(path, '数组索引越界');
      }
      final next = current[index];
      if (next is! Object) {
        throw PatchApplyException(path, '路径经过 null');
      }
      current = next;
      continue;
    }
    throw PatchApplyException(path, '路径经过非容器节点');
  }
  return current;
}

void _applyToMap(
  Map<String, Object?> parent,
  String key,
  ResumePatchOperation operation,
) {
  final exists = parent.containsKey(key);
  switch (operation.type) {
    case PatchOperationType.add:
      if (exists) {
        throw PatchApplyException(operation.path, 'add 目标已存在');
      }
      parent[key] = deepCopyJson(operation.newValue);
    case PatchOperationType.remove:
      if (!exists) {
        throw PatchApplyException(operation.path, 'remove 目标不存在');
      }
      _verifyOldValue(parent[key], operation);
      parent.remove(key);
    case PatchOperationType.replace:
      if (!exists) {
        throw PatchApplyException(operation.path, 'replace 目标不存在');
      }
      _verifyOldValue(parent[key], operation);
      parent[key] = deepCopyJson(operation.newValue);
  }
}

void _applyToList(
  List<Object?> parent,
  String token,
  ResumePatchOperation operation,
) {
  if (operation.type == PatchOperationType.add && token == '-') {
    parent.add(deepCopyJson(operation.newValue));
    return;
  }
  final index = _parseIndex(
    token,
    operation.type == PatchOperationType.add
        ? parent.length + 1
        : parent.length,
    operation.path,
  );
  switch (operation.type) {
    case PatchOperationType.add:
      if (index > parent.length) {
        throw PatchApplyException(operation.path, '数组索引越界');
      }
      parent.insert(index, deepCopyJson(operation.newValue));
    case PatchOperationType.remove:
      if (index >= parent.length) {
        throw PatchApplyException(operation.path, '数组索引越界');
      }
      _verifyOldValue(parent[index], operation);
      parent.removeAt(index);
    case PatchOperationType.replace:
      if (index >= parent.length) {
        throw PatchApplyException(operation.path, '数组索引越界');
      }
      _verifyOldValue(parent[index], operation);
      parent[index] = deepCopyJson(operation.newValue);
  }
}

int _parseIndex(String token, int upperBound, String path) {
  if (!RegExp(r'^(0|[1-9]\d*)$').hasMatch(token)) {
    throw PatchApplyException(path, '数组索引无效');
  }
  final index = int.parse(token);
  if (index > upperBound) {
    throw PatchApplyException(path, '数组索引越界');
  }
  return index;
}

void _verifyOldValue(Object? actual, ResumePatchOperation operation) {
  if (!jsonDeepEquals(actual, operation.oldValue)) {
    throw PatchApplyException(operation.path, '旧值不匹配，拒绝应用 Patch');
  }
}
