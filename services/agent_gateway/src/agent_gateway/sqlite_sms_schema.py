"""SQLite v4→v5 的短信预算与尝试账本；不修改先前迁移。"""

SMS_SCHEMA_STATEMENTS = (
    """CREATE TABLE sms_send_budget (
        policy_id TEXT NOT NULL PRIMARY KEY CHECK (policy_id = 'pnvs'),
        policy_fingerprint TEXT NOT NULL,
        maximum_attempts INTEGER NOT NULL CHECK (maximum_attempts > 0),
        budget_cents INTEGER NOT NULL CHECK (budget_cents > 0),
        reserve_per_attempt_cents INTEGER NOT NULL CHECK (reserve_per_attempt_cents > 0),
        attempts INTEGER NOT NULL CHECK (attempts >= 0 AND attempts <= maximum_attempts),
        reserved_cents INTEGER NOT NULL CHECK (
            reserved_cents >= 0 AND reserved_cents <= budget_cents),
        expires_at_utc TEXT NOT NULL,
        created_at_utc TEXT NOT NULL
    )""",
    """CREATE TABLE sms_send_attempts (
        challenge_id TEXT NOT NULL PRIMARY KEY,
        policy_id TEXT NOT NULL REFERENCES sms_send_budget(policy_id),
        phone_hash TEXT NOT NULL,
        purpose TEXT NOT NULL CHECK (purpose IN ('register', 'resetPassword')),
        outcome TEXT NOT NULL CHECK (outcome IN ('reserved', 'accepted', 'rejected', 'unknown')),
        reserved_cents INTEGER NOT NULL CHECK (reserved_cents > 0),
        created_at_utc TEXT NOT NULL,
        finalized_at_utc TEXT,
        request_id_digest TEXT,
        biz_id_digest TEXT,
        CHECK ((outcome = 'reserved' AND finalized_at_utc IS NULL) OR
               (outcome != 'reserved' AND finalized_at_utc IS NOT NULL))
    )""",
    "CREATE INDEX sms_send_attempts_policy ON sms_send_attempts(policy_id)",
)
