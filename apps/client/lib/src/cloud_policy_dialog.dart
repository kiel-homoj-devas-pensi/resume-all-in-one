import 'dart:async';

import 'package:flutter/material.dart';

import 'cloud_sync_contracts.dart';
import 'remote_account_service.dart';
import 'resume_workspace_controller.dart';

final class CloudPolicyDialog extends StatefulWidget {
  const CloudPolicyDialog({super.key, required this.controller});
  final ResumeWorkspaceController controller;

  @override
  State<CloudPolicyDialog> createState() => _CloudPolicyDialogState();
}

final class _CloudPolicyDialogState extends State<CloudPolicyDialog> {
  CloudSyncOptions? _options;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 离线检查会通知已有工作区；等弹窗构建结束再查询。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_read());
    });
  }

  Future<void> _read() async {
    final options = await widget.controller.readCloudOptions();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _options = options;
      _error = options == null
          ? widget.controller.networkEnabled
                ? widget.controller.remoteAccountSnapshot.status !=
                          RemoteAccountSessionStatus.gatewayUnavailable
                      ? '云政策未能核验，请稍后重新查询。'
                      : '未配置开发服务，无法查询云政策。'
                : '联网已关闭。请先在设置中允许联网，再主动查询。'
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final options = _options;
    final policy = options?.policy;
    return AlertDialog(
      title: const Text('云同步政策'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('本次只查询服务状态和政策，不上传简历，不授予同步同意。'),
              const SizedBox(height: 8),
              const Text('客户端上传尚未开放。本地编辑、历史和文件导出仍可使用。'),
              const SizedBox(height: 16),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null) Text(_error!),
              if (options != null) ...[
                Text(options.enabled ? '云服务：合成测试环境' : '云服务：未开放'),
              ],
              if (policy != null) ...[
                const SizedBox(height: 16),
                const Text(
                  '范围：完整简历正文、标题和版本信息，包括自行补充的字段。'
                  '不包括 Word/PDF 副本、聊天和待审阅的 AI 建议。',
                ),
                const SizedBox(height: 12),
                Text('服务区域：${policy.region}'),
                Text('政策版本：${policy.policyVersion}'),
                Text('资源标识：${policy.resourceIdentity}'),
                Text('配置的正文删除保留期：${policy.contentRetentionDays} 天'),
                Text('配置的备份删除保留期：${policy.backupRetentionDays} 天'),
                const SizedBox(height: 12),
                const Text(
                  '以上是合成环境配置，尚不构成正式服务承诺。'
                  '查看政策不代表已同步，也不能替代每份简历的明确选择。',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading
              ? null
              : () {
                  setState(() {
                    _loading = true;
                    _options = null;
                    _error = null;
                  });
                  unawaited(_read());
                },
          child: const Text('重新查询'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
