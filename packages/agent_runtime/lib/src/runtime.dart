import 'package:agent_protocol/agent_protocol.dart';
import 'package:resume_domain/resume_domain.dart';

import 'confirmation_gate.dart';
import 'registry.dart';
import 'tools.dart';

final class AgentRuntime {
  AgentRuntime._(this._registry, this._confirmationGate);

  factory AgentRuntime({
    required ResumeRepository repository,
    DateTime Function()? now,
    String Function(String namespace)? nextId,
  }) {
    final clock = now ?? DateTime.now;
    final ids = _RuntimeIds(clock);
    final idFactory = nextId ?? ids.next;
    final confirmationGate = ConfirmationGate(
      repository: repository,
      now: clock,
      nextId: idFactory,
    );
    final registry = ToolRegistry(
      tools: [
        ReadResumeTool(repository),
        ValidateResumeTool(repository),
        FindRepeatedContentTool(repository),
        BuildPatchTool(repository, confirmationGate),
      ],
      now: clock,
    );
    return AgentRuntime._(registry, confirmationGate);
  }

  final ToolRegistry _registry;
  final ConfirmationGate _confirmationGate;

  List<ToolDescriptor> get toolDescriptors => _registry.descriptors;

  Future<ToolResult> executeTool(
    ToolCall call, {
    AgentCancellationToken? cancellationToken,
  }) {
    return _registry.execute(call, cancellationToken: cancellationToken);
  }

  Future<ConfirmationResult> decide(ConfirmationCommand command) {
    return _confirmationGate.resolve(command);
  }

  void clearTransientState() {
    // 清空本地数据时必须同时丢弃可能含有正文、Patch 或 Diff 的进程内状态。
    // 调用方只在没有运行中任务时执行，避免把正在处理的用户动作变成孤立结果。
    _registry.clearExecutionHistory();
    _confirmationGate.clearHistory();
  }
}

final class _RuntimeIds {
  _RuntimeIds(this._now);

  final DateTime Function() _now;
  int _counter = 0;

  String next(String namespace) {
    _counter++;
    return '${namespace}_${_now().toUtc().microsecondsSinceEpoch}_$_counter';
  }
}
