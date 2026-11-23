from typing import Annotated

from pydantic import AfterValidator, StringConstraints

PASSWORD_RULE = "密码需为6–15位，包含英文字母和数字，仅可选用@!，不能有空格"  # noqa: S105 — UI rule text.


def validateNewPassword(value: str) -> str:
    if (
        not 6 <= len(value) <= 15
        or any(
            character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@!"
            for character in value
        )
        or not any("a" <= character.lower() <= "z" for character in value)
        or not any("0" <= character <= "9" for character in value)
    ):
        raise ValueError(PASSWORD_RULE)
    return value


NewPassword = Annotated[
    str, StringConstraints(min_length=6, max_length=15), AfterValidator(validateNewPassword)
]
ExistingPassword = NewPassword
