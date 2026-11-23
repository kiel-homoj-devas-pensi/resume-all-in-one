import 'package:flutter_test/flutter_test.dart';
import 'package:resume_all_in_one_client/src/account_password_policy.dart';

void main() {
  test('新密码按6–15位字母数字规则校验，@!可选，不改变输入', () {
    for (final value in ['Ab1234', 'A12345678901234', 'Ab12@!', 'test12']) {
      expect(isValidNewPassword(value), isTrue, reason: value);
    }
    for (final value in [
      '',
      'Ab123',
      '原有长密码 with spaces / symbols 2026',
      'A123456789012345',
      'abcdef',
      '123456',
      'Ab12 3',
      'Ab123\n',
      'Ab12\t3',
      'Ab12#3',
      'Ab12_3',
      '密码Ab12',
      'Ａb1234',
      'Ab12\u00a03',
    ]) {
      expect(isValidNewPassword(value), isFalse, reason: value);
    }
  });
}
