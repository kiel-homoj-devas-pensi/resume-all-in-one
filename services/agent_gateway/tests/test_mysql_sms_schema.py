import pytest

from agent_gateway.database import UnsupportedDatabaseSchemaError
from agent_gateway.mysql_usage_schema import _normalizeCheck


def test_mysql_not_null_metadata_is_equivalent_without_changing_literal_values() -> None:
    generated = "((`outcome` <> _ascii'reserved') and (`finalized_at_utc` is not null))"
    expected = "outcome <> 'reserved' AND finalized_at_utc IS NOT NULL"
    assert _normalizeCheck(generated) == _normalizeCheck(expected)


def test_check_comparison_keeps_case_spaces_and_sql_words_inside_enum_literals() -> None:
    expected = "purpose IN ('register', 'resetPassword')"
    assert _normalizeCheck(expected) != _normalizeCheck("purpose IN ('register', 'resetpassword')")
    assert _normalizeCheck(expected) != _normalizeCheck("purpose IN ('register', 'reset Password')")
    assert _normalizeCheck("value IN ('NOT')") != _normalizeCheck("value IN ('not')")


def test_check_comparison_cannot_erase_boolean_grouping() -> None:
    assert _normalizeCheck("a=1 AND (b=2 OR c=3)") != _normalizeCheck("(a=1 AND b=2) OR c=3")


@pytest.mark.parametrize(
    ("actual", "expected"),
    [
        (
            "((length(`document_id`) >= 1) and (length(`document_id`) <= 512))",
            "LENGTH(document_id) >= 1 AND LENGTH(document_id) <= 512",
        ),
        ("a=1 AND (b=2 AND c=3)", "(a=1 AND b=2) AND c=3"),
        ("a IS NOT NULL", "(`a` is not null)"),
        ("x IN (_ascii'AND', _ascii'(', _ascii'_ascii')", "x IN ('AND', '(', '_ascii')"),
        (r"x = 'O\'Neil'", "x='O''Neil'"),
        ("a != 1", "a <> 1"),
    ],
)
def test_mysql_check_metadata_preserves_logic_and_literal_values(
    actual: str, expected: str
) -> None:
    assert _normalizeCheck(actual) == _normalizeCheck(expected)


@pytest.mark.parametrize(
    "clause", ["a=1; DROP TABLE accounts", "a BETWEEN 1 AND 2", "ABS(a)>0", "(", "", "(" * 9000]
)
def test_unknown_or_oversized_check_expression_is_rejected(clause: str) -> None:
    with pytest.raises(UnsupportedDatabaseSchemaError, match="mysql_check_expression_invalid"):
        _normalizeCheck(clause)
