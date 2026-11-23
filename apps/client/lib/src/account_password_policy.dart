const newPasswordRule = '6–15位，包含英文字母和数字，仅可选用@!，不能有空格';

bool isValidNewPassword(String password) =>
    password.length >= 6 &&
    password.length <= 15 &&
    !RegExp(r'[^A-Za-z0-9@!]').hasMatch(password) &&
    RegExp(r'[A-Za-z]').hasMatch(password) &&
    RegExp(r'[0-9]').hasMatch(password);
