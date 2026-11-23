import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gateway_api_client.dart';
import 'resume_workspace_controller.dart';

Future<void> showPrivacyRightsPage(
  BuildContext context,
  ResumeWorkspaceController controller,
) => Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => _PrivacyRightsPage(controller: controller),
  ),
);

final class _PrivacyRightsPage extends StatefulWidget {
  const _PrivacyRightsPage({required this.controller});
  final ResumeWorkspaceController controller;
  @override
  State<_PrivacyRightsPage> createState() => _PrivacyRightsPageState();
}

final class _PrivacyRightsPageState extends State<_PrivacyRightsPage> {
  final _password = TextEditingController();
  final _description = TextEditingController();
  String _kind = '咨询或投诉';
  bool _busy = false;
  GatewayRightsRequestReceipt? _receipt;
  int? _receiptSession;
  String? _notice;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_password.text.isEmpty) {
      setState(() => _notice = '请只在应用内输入当前密码，或直接邮件提出请求。');
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
      _receipt = null;
    });
    final generation = widget.controller.remoteDraftGeneration;
    final password = _password.text;
    _password.clear();
    final result = await widget.controller.issueRightsRequestReceipt(password);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (generation != widget.controller.remoteDraftGeneration) {
        _notice = '账号状态已变化，请重新核验，或直接邮件申请。';
      } else if (result == null) {
        _notice = widget.controller.formError ?? '核验未完成，仍可直接通过邮箱申请。';
      } else {
        _receipt = result;
        _receiptSession = generation;
        _notice = '已核验当时的账号控制权。回执仅供运营者审核请求，不是登录凭证，也不表示请求已经提交或处理。';
      }
    });
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final operator =
          controller.legalConsent?.bundle?.toJson()['operator'] as Map?;
      final email = operator?['contactEmail'] as String?;
      final snapshot = controller.remoteAccountSnapshot;
      final validReceipt =
          _receipt != null &&
          _receiptSession == controller.remoteDraftGeneration &&
          snapshot.isSignedIn &&
          !snapshot.isGuest &&
          _receipt!.expiresAtUtc.isAfter(DateTime.now().toUtc());
      final canVerify =
          !_busy &&
          !controller.isBusy &&
          snapshot.isSignedIn &&
          !snapshot.isGuest &&
          controller.supportsRightsRequests &&
          controller.networkEnabled &&
          controller.legalConsent?.canUseRemoteServices == true;
      return Scaffold(
        appBar: AppBar(title: const Text('咨询、投诉与个人信息请求')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  '由${operator?['name'] ?? '服务提供者'}受理。本页可离线准备邮件；复制不会自动发送或提交请求。',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  email == null || email.isEmpty
                      ? '联系邮箱待补充，请查阅当前隐私政策。'
                      : '联系邮箱：$email',
                ),
                if (email != null && email.isNotEmpty)
                  OutlinedButton(
                    key: const Key('复制隐私联系邮箱'),
                    onPressed: () => _copy(email, '邮箱已复制，请自行选择邮件应用'),
                    child: const Text('复制联系邮箱'),
                  ),
                const Text(
                  '收到邮件后10个工作日内首次回复；需人工处理的更正、删除、注销及个人信息安全投诉举报，自收到请求起15个工作日内核查、处理并反馈，包含首次回复时间。',
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const Key('个人信息请求类型'),
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: '请求类型'),
                  items: [
                    for (final label in [
                      '咨询或投诉',
                      '查阅或复制个人信息',
                      '更正个人信息',
                      '删除个人信息',
                      '注销账号',
                    ])
                      DropdownMenuItem(value: label, child: Text(label)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _kind = value!),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('个人信息请求说明'),
                  controller: _description,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    labelText: '请求说明（可选）',
                    helperText: '仅填写处理所需内容，不要填写密码、短信验证码、恢复码或无关证件资料。',
                    helperMaxLines: 4,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '账号资料请求可优先在此核验账号归属',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text(
                  '普通咨询、投诉不要求登录。无法登录、尚未同意联网协议或核验失败时，仍可直接邮件提出请求，由受理人按风险作必要人工核验。',
                ),
                if (canVerify) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('权利请求当前密码'),
                    controller: _password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '当前账号密码（只交给本软件后端核验）',
                    ),
                  ),
                  FilledButton(
                    key: const Key('核验权利请求账号归属'),
                    onPressed: _verify,
                    child: const Text('核验并生成请求回执'),
                  ),
                ] else if (!validReceipt)
                  const Text('当前无法进行应用内账号核验，可使用下方邮件途径；不要在邮件中发送登录秘密。'),
                if (_busy) const LinearProgressIndicator(),
                if (_notice != null)
                  Semantics(liveRegion: true, child: Text(_notice!)),
                if (validReceipt)
                  Text(
                    '核验回执有效至（UTC）：${_receipt!.expiresAtUtc.toIso8601String()}；复制邮件时会包含它。',
                  ),
                const SizedBox(height: 16),
                OutlinedButton(
                  key: const Key('复制个人信息请求邮件'),
                  onPressed: _busy || email == null || email.isEmpty
                      ? null
                      : () => _copy(
                          '收件人：$email\n主题：简历全能帮—$_kind\n\n请求类型：$_kind\n请求说明：${_description.text.trim().isEmpty ? '（请填写所需范围和具体问题）' : _description.text.trim()}\n\n'
                              '${validReceipt ? '应用内账号归属核验回执：${_receipt!.receipt}\n' : '尚未提供应用内核验回执；涉及账号资料时请告知必要人工核验方式。\n'}'
                              '请通过本邮件回复。此邮件不包含密码、短信验证码或恢复码。',
                          '邮件草稿已复制；请自行检查、补充并发送，复制不等于提交',
                        ),
                  child: const Text('复制邮件草稿，自行发送'),
                ),
                const Text(
                  '说明与回执仅在本页内存中使用，离开后不保存。复制会写入系统剪贴板，发送前请检查接收地址及内容。回执签名只证明签发时的账号控制权；受理人仍需核查请求范围及合法性。',
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
