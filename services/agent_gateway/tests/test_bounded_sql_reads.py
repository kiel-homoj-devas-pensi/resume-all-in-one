import sqlite3

import pymysql
import pytest

from agent_gateway.account_storage import StorageUnavailableError, _SqliteConnection
from agent_gateway.mysql_storage import _MySqlConnection
from tests.test_mysql_storage import FakeConnection, FakeDriver


def test_sqlite_bounded_read_rejects_overflow_and_redacts_query_failure() -> None:
    with sqlite3.connect(":memory:") as native:
        native.row_factory = sqlite3.Row
        connection = _SqliteConnection(native)
        assert connection.fetchMany("SELECT 1 AS value", maximumRows=1) == ({"value": 1},)
        with pytest.raises(StorageUnavailableError, match="storage_row_bound_exceeded"):
            connection.fetchMany("SELECT 1 UNION ALL SELECT 2", maximumRows=1)
        with pytest.raises(StorageUnavailableError, match="^storage_read_unavailable$"):
            connection.fetchMany("SELECT private_invalid_column", maximumRows=1)
        for bound in (True, 0, 202):
            with pytest.raises(ValueError, match="invalid_storage_row_bound"):
                connection.fetchMany("SELECT 1", maximumRows=bound)


def test_mysql_bounded_read_closes_cursor_on_success_overflow_and_driver_failure() -> None:
    driver = FakeDriver()
    connection = _MySqlConnection(FakeConnection(driver))
    driver.rows = [{"value": 1}]
    assert connection.fetchMany("SELECT 1 AS value LIMIT 1", maximumRows=1) == ({"value": 1},)
    driver.rows = [{"value": 1}, {"value": 2}]
    with pytest.raises(StorageUnavailableError, match="storage_row_bound_exceeded"):
        connection.fetchMany("SELECT 1 UNION ALL SELECT 2", maximumRows=1)
    driver.executeError = pymysql.OperationalError("private_driver_detail")
    with pytest.raises(StorageUnavailableError, match="^storage_read_unavailable$"):
        connection.fetchMany("SELECT 1 LIMIT 1", maximumRows=1)
    assert driver.cursorCloses == 3
