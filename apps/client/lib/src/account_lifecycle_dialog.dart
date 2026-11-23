import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'gateway_api_client.dart';
import 'remote_ai_dialogs.dart' show RemoteOperationDialog;
import 'resume_workspace_controller.dart';
import 'account_password_policy.dart';
import 'account_form_focus.dart';
import 'legal_consent_pages.dart' show showBundledPrivacyPolicy;

enum _AccountPage { login, register, recovery, security }

final class AccountLifecycleDialog extends StatefulWidget {
  const AccountLifecycleDialog({
    super.key,
    required this.controller,
    required this.onFeedback,
  });
  final ResumeWorkspaceController controller;
  final VoidCallback onFeedback;
  @override
  State<AccountLifecycleDialog> createState() => _AccountLifecycleDialogState();
}

final class _AccountLifecycleDialogState extends State<AccountLifecycleDialog>
    with WidgetsBindingObserver, AccountFormFocus<AccountLifecycleDialog> {
  final _country = TextEditingController(text: '+86');
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _code = TextEditingController();
  final _recoveryCode = TextEditingController();
  _AccountPage _page = _AccountPage.login;
  GatewayVerification? _challenge;
  String? _challengePhone;
  Timer? _expiryTimer;
  bool _loading = true, _optionsReady = false, _submitting = false;
  bool _refreshingAccess = false, _accessRefreshFailed = false;
  bool _showPassword = false,
      _showNewPassword = false,
      _showConfirmPassword = false,
      _deliveryUncertain = false;
  String? _feedback, _phoneError, _passwordError, _newPasswordError, _codeError;
  String? _confirmPasswordError;
  String? _recoveryCodeError;
  bool get _busy =>
      widget.controller.isBusy || _loading || _submitting || _refreshingAccess;
  bool get _signedIn => widget.controller.remoteAccountSnapshot.isSignedIn;
  bool get _subpage =>
      _signedIn ? _page == _AccountPage.security : _page != _AccountPage.login;
  String get _phoneE164 {
    final number = _phone.text.replaceAll(RegExp(r'[\s()\-]'), '');
    return number.startsWith('+') ? number : _country.text.trim() + number;
  }

  bool get _hasChallenge =>
      _challenge != null &&
      _challengePhone == _phoneE164 &&
      _challenge!.expiresAtUtc.isAfter(DateTime.now().toUtc());

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    setState(() {
      _loading = true;
      _feedback = null;
    });
    final result = await widget.controller.readDevelopmentSmsMode();
    if (!mounted) return;
    setState(() {
      _optionsReady = result != null;
      _loading = false;
      if (!_optionsReady) {
        _feedback = widget.controller.formError ?? '暂时无法连接账号服务，请检查网络后重试。';
      }
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    for (final field in [
      _country,
      _phone,
      _password,
      _newPassword,
      _confirmPassword,
      _code,
      _recoveryCode,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  void _changePage(_AccountPage page) {
    FocusScope.of(context).unfocus();
    setState(() {
      _page = page;
      _password.clear();
      _newPassword.clear();
      _confirmPassword.clear();
      _code.clear();
      _recoveryCode.clear();
      _challenge = null;
      _expiryTimer?.cancel();
      _showPassword = _showNewPassword = _showConfirmPassword = false;
      _feedback = _phoneError = _passwordError = _codeError = null;
      _newPasswordError = null;
      _confirmPasswordError = null;
      _recoveryCodeError = null;
    });
  }

  void _back() => _changePage(_AccountPage.login);
  bool _validatePhone() {
    final value = _phoneE164;
    final valid =
        _phone.text.trim().isNotEmpty &&
        RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(value) &&
        (!value.startsWith('+86') || RegExp(r'^\+861\d{10}$').hasMatch(value));
    setState(() => _phoneError = valid ? null : '请核对区号和手机号');
    return valid;
  }

  bool _validatePassword(TextEditingController field) {
    final valid = isValidNewPassword(field.text);
    const error = newPasswordRule;
    setState(() {
      if (identical(field, _newPassword)) {
        _newPasswordError = valid ? null : error;
      } else {
        _passwordError = valid ? null : error;
      }
    });
    return valid;
  }

  bool _validateConfirmation(String password) {
    final valid = _confirmPassword.text == password && password.isNotEmpty;
    setState(() => _confirmPasswordError = valid ? null : '两次密码不一致，请重新核对');
    return valid;
  }

  Future<bool> _run(Future<bool> Function() action) async {
    if (_busy) return false;
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _feedback = null;
    });
    final success = await action();
    if (!mounted) return false;
    setState(() {
      _submitting = false;
      _feedback = success
          ? widget.controller.message
          : widget.controller.formError;
      if (success) {
        _password.clear();
        _newPassword.clear();
        _confirmPassword.clear();
        _code.clear();
        _recoveryCode.clear();
        _showPassword = _showNewPassword = _showConfirmPassword = false;
        _challenge = null;
        _expiryTimer?.cancel();
        _page = _AccountPage.login;
      }
    });
    widget.onFeedback();
    return success;
  }

  Future<void> _submit() async {
    if (_busy || !_optionsReady) return;
    final phoneValid = _validatePhone();
    final passwordValid = _validatePassword(
      _page == _AccountPage.recovery ? _newPassword : _password,
    );
    final confirmationValid =
        _page == _AccountPage.login ||
        _validateConfirmation(
          _page == _AccountPage.recovery ? _newPassword.text : _password.text,
        );
    final codeValid =
        _page != _AccountPage.register ||
        (_hasChallenge && RegExp(r'^\d{6}$').hasMatch(_code.text));
    setState(() => _codeError = codeValid ? null : '请获取并输入仍有效的6位验证码');
    if (!phoneValid || !passwordValid || !confirmationValid || !codeValid) {
      focusAccountField(
        !phoneValid
            ? _phone
            : !passwordValid
            ? (_page == _AccountPage.recovery ? _newPassword : _password)
            : !confirmationValid
            ? _confirmPassword
            : _code,
      );
      return;
    }
    if (_page == _AccountPage.recovery &&
        !RegExp(
          r'^[0-9A-F]{8}(?:-[0-9A-F]{8}){3}$',
        ).hasMatch(_recoveryCode.text)) {
      setState(() => _recoveryCodeError = '请输入保存的恢复码，格式为4组8位字母数字。');
      focusAccountField(_recoveryCode);
      return;
    }
    switch (_page) {
      case _AccountPage.login:
        await _run(
          () => widget.controller.signInRemoteAccount(
            phoneE164: _phoneE164,
            password: _password.text,
          ),
        );
      case _AccountPage.register:
        final registrationPassword = _password.text;
        final registered = await _run(
          () => widget.controller.registerVerifiedAccount(
            _phoneE164,
            _password.text,
            _challenge!.challengeId,
            _code.text,
          ),
        );
        if (registered && mounted && widget.controller.supportsRecoveryCodes) {
          await _generateRecoveryCode(registrationPassword);
        }
      case _AccountPage.recovery:
        await _run(
          () => widget.controller
              .manageRemoteAccount(GatewayAccountAction.resetPassword, {
                'phoneE164': _phoneE164,
                'newPassword': _newPassword.text,
                'recoveryCode': _recoveryCode.text,
              }),
        );
      case _AccountPage.security:
        break;
    }
  }

  Future<void> _issue() async {
    if (_page != _AccountPage.register ||
        _busy ||
        !_optionsReady ||
        _hasChallenge) {
      return;
    }
    if (!_validatePhone()) {
      focusAccountField(_phone);
      return;
    }
    if (_deliveryUncertain) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重新请求验证码？'),
          content: const Text('上次发送结果未能确认。请先等待并检查短信和网络；继续将发起一次新请求，可能再次产生短信费用。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续等待'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认重新请求'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true || _busy) return;
    }
    FocusScope.of(context).unfocus();
    final phone = _phoneE164;
    setState(() {
      _submitting = true;
      _feedback = null;
      _codeError = null;
    });
    final challenge = await widget.controller.requestAccountVerification(
      phone,
      'register',
    );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _challenge = challenge;
      _challengePhone = phone;
      _deliveryUncertain = widget.controller.accountVerificationOutcomeUnknown;
      _code.text = challenge?.developmentCode ?? '';
      _feedback = challenge == null
          ? widget.controller.formError
          : '验证码已发送，请查看短信。';
    });
    _expiryTimer?.cancel();
    if (challenge != null) {
      final remaining = challenge.expiresAtUtc.difference(
        DateTime.now().toUtc(),
      );
      _expiryTimer = Timer(
        remaining.isNegative ? Duration.zero : remaining,
        () {
          if (mounted) setState(() {});
        },
      );
    }
    widget.onFeedback();
  }

  Future<void> _refreshAccess() async {
    if (_busy) return;
    setState(() {
      _refreshingAccess = true;
      _accessRefreshFailed = false;
    });
    final success = await widget.controller.refreshRemoteAccess();
    if (!mounted) return;
    setState(() {
      _refreshingAccess = false;
      _accessRefreshFailed = !success;
    });
    widget.onFeedback();
  }

  Future<void> _deactivate() async {
    if (_busy) return;
    if (!_validatePassword(_password)) {
      focusAccountField(_password);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('停用此账户？'),
        content: const Text(
          '停用后全部登录失效，登录手机号与密码将移除。本地简历不会清空；服务端保留最少用量与对账记录。此操作不能撤销，重新注册会建立新账号。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认停用'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        () => widget.controller.manageRemoteAccount(
          GatewayAccountAction.deactivate,
          {'currentPassword': _password.text, 'confirmation': 'DEACTIVATE'},
        ),
      );
    }
  }

  Widget _passwordField(
    TextEditingController field, {
    required bool isNew,
    required String label,
  }) {
    final visible = isNew ? _showNewPassword : _showPassword;
    return TextField(
      key: Key(isNew ? '账户新密码' : '账户密码'),
      controller: field,
      focusNode: accountFocus(field),
      enabled: !_busy,
      obscureText: !visible,
      autocorrect: false,
      enableSuggestions: false,
      inputFormatters: [
        TextInputFormatter.withFunction((previous, next) {
          if (RegExp(r'\s').hasMatch(next.text)) {
            setState(() => _feedback = '密码不能包含空格或换行，请重新输入。');
            return previous;
          }
          return next;
        }),
      ],
      textInputAction: _page == _AccountPage.login
          ? TextInputAction.done
          : TextInputAction.next,
      onSubmitted: (_) {
        if (_page == _AccountPage.login) {
          _submit();
        } else {
          focusAccountField(
            _page == _AccountPage.security && !isNew
                ? _newPassword
                : _confirmPassword,
          );
        }
      },
      onChanged: (_) {
        setState(() {
          if (isNew) {
            _newPasswordError = null;
          } else {
            _passwordError = null;
          }
          _confirmPasswordError = null;
        });
      },
      decoration: InputDecoration(
        labelText: label,
        helperText: isNew || _page == _AccountPage.register
            ? newPasswordRule
            : null,
        helperMaxLines: 4,
        errorText: isNew ? _newPasswordError : _passwordError,
        errorMaxLines: 4,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          tooltip: visible ? '隐藏密码' : '显示密码',
          onPressed: _busy
              ? null
              : () => setState(() {
                  if (isNew) {
                    _showNewPassword = !visible;
                  } else {
                    _showPassword = !visible;
                  }
                }),
          icon: Icon(
            visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          ),
        ),
      ),
    );
  }

  Widget _confirmationField() => TextField(
    key: const Key('账户确认密码'),
    controller: _confirmPassword,
    focusNode: accountFocus(_confirmPassword),
    enabled: !_busy,
    obscureText: !_showConfirmPassword,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: _page == _AccountPage.security
        ? TextInputAction.done
        : TextInputAction.next,
    onSubmitted: (_) {
      if (_page == _AccountPage.security) {
        _changePassword();
      } else {
        focusAccountField(
          _page == _AccountPage.recovery ? _recoveryCode : _code,
        );
      }
    },
    onChanged: (_) => setState(() => _confirmPasswordError = null),
    decoration: InputDecoration(
      labelText: '确认新密码',
      errorText: _confirmPasswordError,
      errorMaxLines: 3,
      prefixIcon: const Icon(Icons.lock_outline),
      suffixIcon: IconButton(
        tooltip: _showConfirmPassword ? '隐藏确认密码' : '显示确认密码',
        onPressed: _busy
            ? null
            : () => setState(() {
                _showConfirmPassword = !_showConfirmPassword;
              }),
        icon: Icon(
          _showConfirmPassword
              ? Icons.visibility_off_outlined
              : Icons.visibility_outlined,
        ),
      ),
    ),
  );

  List<Widget> _authenticationFields(BuildContext context) {
    final login = _page == _AccountPage.login;
    final recovery = _page == _AccountPage.recovery;
    return [
      Text(
        login
            ? '登录后使用在线简历服务。'
            : recovery
            ? '使用注册后保存的恢复码设置新密码，无需短信。恢复成功后该恢复码失效。'
            : '验证手机号，开启你的简历工作空间。',
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      const SizedBox(height: 24),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: TextField(
              key: const Key('账户区号'),
              controller: _country,
              focusNode: accountFocus(_country),
              enabled: !_busy,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => focusAccountField(_phone),
              decoration: const InputDecoration(labelText: '区号'),
              onChanged: (_) => setState(() {
                _challenge = null;
                _phoneError = null;
              }),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              key: const Key('账户手机号'),
              controller: _phone,
              focusNode: accountFocus(_phone),
              enabled: !_busy,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) =>
                  focusAccountField(recovery ? _newPassword : _password),
              decoration: InputDecoration(
                labelText: '手机号',
                errorText: _phoneError,
                errorMaxLines: 3,
              ),
              onChanged: (_) => setState(() {
                _challenge = null;
                _phoneError = null;
                _code.clear();
              }),
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      _passwordField(
        recovery ? _newPassword : _password,
        isNew: recovery,
        label: recovery
            ? '新密码'
            : login
            ? '密码'
            : '设置密码',
      ),
      if (!login) ...[const SizedBox(height: 20), _confirmationField()],
      if (recovery) ...[
        const SizedBox(height: 20),
        TextField(
          key: const Key('账户恢复码'),
          controller: _recoveryCode,
          focusNode: accountFocus(_recoveryCode),
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            if (_recoveryCodeError != null) {
              setState(() => _recoveryCodeError = null);
            }
          },
          decoration: InputDecoration(
            labelText: '恢复码',
            hintText: 'XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX',
            helperText: '恢复码仅你保存。没有设置过时，仍可在已登录设备的账号安全页补设。',
            helperMaxLines: 3,
            errorText: _recoveryCodeError,
            errorMaxLines: 3,
          ),
          inputFormatters: [
            TextInputFormatter.withFunction(
              (_, next) => next.copyWith(text: next.text.toUpperCase()),
            ),
          ],
        ),
      ],
      if (_page == _AccountPage.register) ...[
        const SizedBox(height: 20),
        TextField(
          key: const Key('账户验证码'),
          controller: _code,
          focusNode: accountFocus(_code),
          enabled: !_busy,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onSubmitted: (_) => _submit(),
          onChanged: (_) {
            if (_codeError != null) setState(() => _codeError = null);
          },
          decoration: InputDecoration(
            labelText: '短信验证码',
            errorText: _codeError,
            errorMaxLines: 2,
            prefixIcon: const Icon(Icons.sms_outlined),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          '点击“获取验证码”即单独同意：为本次注册验证，将手机号及短信必要参数经本服务发送给阿里云计算有限公司，由其及中国移动、中国联通、中国电信完成短信服务。供应商短信记录保留180天，到期自动删除，不能提前主动删除。',
        ),
        TextButton(
          onPressed: () => showBundledPrivacyPolicy(context),
          child: const Text('查看隐私政策和接收方说明'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy || !_optionsReady || _hasChallenge ? null : _issue,
            icon: const Icon(Icons.send_outlined, size: 18),
            label: Text(
              _hasChallenge
                  ? '验证码已发送'
                  : _deliveryUncertain
                  ? '重新尝试发送'
                  : '获取验证码',
            ),
          ),
        ),
        if (_challenge != null)
          Text(
            _hasChallenge
                ? '有效至 ${_challenge!.expiresAtUtc.toLocal().toString().substring(11, 16)}，有效期内请使用已收到的验证码。'
                : '验证码已失效，请重新获取。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
      const SizedBox(height: 24),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        onPressed: _busy || !_optionsReady ? null : _submit,
        child: Text(
          _submitting
              ? '正在提交…'
              : login
              ? '登录'
              : recovery
              ? '重设密码'
              : '验证并注册',
        ),
      ),
      if (login) ...[
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _changePage(_AccountPage.register),
              child: const Text('创建账号'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _changePage(_AccountPage.recovery),
              child: const Text('找回密码'),
            ),
          ],
        ),
      ],
      if (login && widget.controller.supportsGuestAi) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('游客体验AI'),
          onPressed: _busy ? null : () => _run(widget.controller.startGuestAi),
          icon: const Icon(Icons.person_outline),
          label: const Text('先体验 AI，无需注册'),
        ),
        const Text('游客每月可获得1份基础生成和1份岗位优化候选；按有效候选计次，补充材料与恢复不另扣。'),
      ],
      const SizedBox(height: 16),
      Text(
        '登录仅在本次应用运行期间有效。重新打开应用后需再次登录，本地简历始终保留。',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ];
  }

  List<Widget> _overview(BuildContext context) {
    final snapshot = widget.controller.remoteAccountSnapshot;
    return [
      Text(
        snapshot.isGuest ? '游客体验' : (snapshot.maskedPhone ?? '已登录'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 16),
      if (_refreshingAccess)
        const Text('正在更新身份、会员与 AI 额度…')
      else if (_accessRefreshFailed || !snapshot.accessVerified)
        Text(
          '身份、会员与 AI 额度未能更新，请刷新后确认。\n${widget.controller.formError ?? '当前无法核验账号权益。'}',
          key: const Key('账户权益刷新失败'),
        )
      else ...[
        if (snapshot.privileges case final privileges?)
          ListTile(
            key: const Key('账号身份与会员'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_user_outlined),
            title: Text(
              privileges.role == GatewayAccountRole.admin ? '管理员' : '普通用户',
            ),
            subtitle: Text(
              privileges.membership == GatewayMembership.permanent
                  ? '永久会员 · 无需缴费续期'
                  : '未授予永久会员',
            ),
          )
        else if (!snapshot.isGuest)
          const Text('服务尚未提供管理员与永久会员身份信息。'),
        Text(
          snapshot.isGuest
              ? '游客 · 无需注册'
              : '套餐：${switch (snapshot.plan) {
                  GatewaySubscriptionPlan.free => '免费',
                  GatewaySubscriptionPlan.pro => '会员',
                  null => '待核验',
                }}',
          key: const Key('账户套餐'),
        ),
        const SizedBox(height: 12),
        for (final entry in snapshot.accessByCapability.entries.where(
          (entry) =>
              entry.key != RemoteAiCapability.resumeOptimizationConversation,
        ))
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${entry.key == RemoteAiCapability.basicResumeCompose ? '基础生成' : '岗位优化'}：'
              '${entry.value.isUnlimited
                  ? '当前不限次数'
                  : entry.value.remainingMonthlyGenerations != null
                  ? '本月剩余 ${entry.value.remainingMonthlyGenerations} / ${entry.value.monthlyLimit}份'
                  : entry.value.remainingMonthlyBasicGenerations != null
                  ? '本月剩余 ${entry.value.remainingMonthlyBasicGenerations}份'
                  : entry.value.allowed
                  ? '可用'
                  : '暂不可用'}',
            ),
          ),
      ],
      const SizedBox(height: 12),
      OutlinedButton.icon(
        key: const Key('刷新账户权益'),
        onPressed: _busy ? null : _refreshAccess,
        icon: const Icon(Icons.refresh),
        label: const Text('刷新身份与权益'),
      ),
      const SizedBox(height: 16),
      const Divider(),
      if (!snapshot.isGuest)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.security_outlined),
          title: const Text('账号安全'),
          subtitle: const Text('修改密码、恢复码与设备会话'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : () => _changePage(_AccountPage.security),
        ),
      OutlinedButton.icon(
        onPressed: _busy
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (_) =>
                    RemoteOperationDialog(controller: widget.controller),
              ),
        icon: const Icon(Icons.history),
        label: const Text('联网操作记录'),
      ),
      if (snapshot.isGuest)
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  widget.controller.signOutRemoteAccount();
                  _back();
                },
          child: const Text('登录或创建账号'),
        ),
      if (!snapshot.isGuest)
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(
                  () => widget.controller.manageRemoteAccount(
                    GatewayAccountAction.revoke,
                    {'allDevices': false},
                  ),
                ),
          child: const Text('退出当前会话'),
        ),
      const Text('登录仅在本次应用运行期间有效；退出登录不会清除本地简历。'),
    ];
  }

  List<Widget> _security(BuildContext context) => [
    const Text('敏感操作需要当前密码。停用账户会撤销登录，请谨慎操作。'),
    const SizedBox(height: 20),
    _passwordField(_password, isNew: false, label: '当前密码'),
    const SizedBox(height: 20),
    _passwordField(_newPassword, isNew: true, label: '新密码'),
    const SizedBox(height: 20),
    _confirmationField(),
    const SizedBox(height: 20),
    FilledButton(
      onPressed: _busy ? null : _changePassword,
      child: const Text('修改密码并撤销会话'),
    ),
    OutlinedButton.icon(
      key: const Key('设置账号恢复码'),
      icon: const Icon(Icons.key_outlined),
      label: const Text('设置或更换恢复码'),
      onPressed: _busy || !widget.controller.supportsRecoveryCodes
          ? null
          : () async {
              if (!_validatePassword(_password)) {
                focusAccountField(_password);
                return;
              }
              final approved = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('设置新的恢复码？'),
                  content: const Text('旧恢复码将立即失效。新码只显示一次，请单独妥善保存；不要发送给他人。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('设置新码'),
                    ),
                  ],
                ),
              );
              if (approved == true && mounted) {
                await _generateRecoveryCode(_password.text);
              }
            },
    ),
    TextButton(
      onPressed: _busy
          ? null
          : () => _run(
              () => widget.controller.manageRemoteAccount(
                GatewayAccountAction.revoke,
                {'allDevices': true},
              ),
            ),
      child: const Text('退出全部设备'),
    ),
    TextButton(
      onPressed: _busy
          ? null
          : () {
              widget.controller.signOutRemoteAccount();
              _changePage(_AccountPage.login);
              widget.onFeedback();
            },
      child: const Text('仅清除本机登录'),
    ),
    const Divider(),
    TextButton(
      onPressed: _busy ? null : _deactivate,
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
      ),
      child: const Text('停用账户'),
    ),
  ];

  Future<void> _changePassword() async {
    if (_busy) return;
    final currentValid = _validatePassword(_password);
    final newValid = _validatePassword(_newPassword);
    final confirmationValid = _validateConfirmation(_newPassword.text);
    if (!currentValid || !newValid || !confirmationValid) {
      focusAccountField(
        !currentValid
            ? _password
            : !newValid
            ? _newPassword
            : _confirmPassword,
      );
      return;
    }
    await _run(
      () => widget.controller.manageRemoteAccount(
        GatewayAccountAction.changePassword,
        {'currentPassword': _password.text, 'newPassword': _newPassword.text},
      ),
    );
  }

  Future<void> _generateRecoveryCode(String currentPassword) async {
    if (_busy) return;
    setState(() => _submitting = true);
    final code = await widget.controller.createAccountRecoveryCode(
      currentPassword,
    );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _password.clear();
      if (code == null) {
        _feedback =
            '${widget.controller.formError ?? '恢复码未能显示。'} 可在账号安全页重新设置；不会自动重试。';
      }
    });
    widget.onFeedback();
    if (code == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('保存你的恢复码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('忘记密码时可用它找回账号，无需短信。仅显示这一次，使用或更换后失效，请与密码分开妥善保存。'),
            const SizedBox(height: 16),
            SelectableText(code, key: const Key('新账号恢复码')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
            child: const Text('复制恢复码'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('我已保存，关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final title = _signedIn
          ? (_page == _AccountPage.security ? '账号安全' : '我的账号')
          : switch (_page) {
              _AccountPage.register => '创建账号',
              _AccountPage.recovery => '找回密码',
              _ => '欢迎回来',
            };
      final colors = Theme.of(context).colorScheme;
      final theme = Theme.of(context);
      final fieldTheme = MediaQuery.sizeOf(context).height < 500
          ? theme.copyWith(
              inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                // Retain font scaling and touch targets in a short landscape
                // viewport; spend less space on the field's internal padding.
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 6,
                ),
                constraints: const BoxConstraints(minHeight: 48),
              ),
            )
          : theme;
      final shortScreen =
          MediaQuery.sizeOf(context).height -
              MediaQuery.viewInsetsOf(context).bottom <
          500;
      final exitButton = TextButton(
        onPressed: _busy
            ? null
            : _subpage
            ? _back
            : () => Navigator.pop(context),
        child: Text(_subpage ? (_signedIn ? '返回账号' : '返回登录') : '退出'),
      );
      return PopScope(
        canPop: !_busy && !_subpage,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && !_busy && _subpage) _back();
        },
        child: NotificationListener<ScrollStartNotification>(
          onNotification: onAccountFormScroll,
          child: AlertDialog(
            key: ValueKey((_signedIn, _page)),
            scrollable: true,
            insetPadding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: shortScreen ? 0 : 24,
            ),
            title: Row(
              children: [
                if (_subpage)
                  IconButton(
                    tooltip: '返回',
                    onPressed: _busy ? null : _back,
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(child: Text(title)),
              ],
            ),
            content: Theme(
              data: fieldTheme,
              child: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_signedIn) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.person_outline,
                            color: colors.onPrimaryContainer,
                            size: 28,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    if (_loading) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      const Text('正在连接账号服务…'),
                      const SizedBox(height: 16),
                    ] else if (!_optionsReady) ...[
                      Text(_feedback ?? '暂时无法连接账号服务，请检查网络后重试。'),
                      OutlinedButton.icon(
                        onPressed: _submitting ? null : _loadOptions,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重新连接'),
                      ),
                    ],
                    if (_optionsReady && _feedback != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: Container(
                          key: const Key('账户操作反馈'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(_feedback!),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    ...(_signedIn
                        ? (_page == _AccountPage.security
                              ? _security(context)
                              : _overview(context))
                        : _authenticationFields(context)),
                    // A fixed footer can consume the entire viewport while rotating
                    // with the IME open. Keep it in the form on short screens.
                    if (shortScreen)
                      Align(
                        alignment: Alignment.centerRight,
                        child: exitButton,
                      ),
                  ],
                ),
              ),
            ),
            actions: shortScreen ? null : [exitButton],
          ),
        ),
      );
    },
  );
}
