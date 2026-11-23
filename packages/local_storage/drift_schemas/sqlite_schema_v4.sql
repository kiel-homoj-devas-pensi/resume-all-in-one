-- SQLite schema v4 exported from the verified Android database; contains no rows.
CREATE TABLE "agent_runs" ("id" TEXT NOT NULL, "request_id" TEXT NOT NULL UNIQUE, "document_id" TEXT NOT NULL, "resume_version_id" TEXT NOT NULL, "status" TEXT NOT NULL, "route_status" TEXT NOT NULL, "started_at" INTEGER NOT NULL, "finished_at" INTEGER NOT NULL, "tool_call_count" INTEGER NOT NULL DEFAULT 0, "error_code" TEXT NULL, PRIMARY KEY ("id"));

CREATE TABLE "app_settings" ("setting_key" TEXT NOT NULL, "bool_value" INTEGER NOT NULL CHECK ("bool_value" IN (0, 1)), "updated_at" INTEGER NOT NULL, PRIMARY KEY ("setting_key"));

CREATE TABLE remote_acceptance_receipts (record_id TEXT PRIMARY KEY, document_id TEXT NOT NULL, version_id TEXT NOT NULL);

CREATE TABLE remote_conversations (account_id TEXT NOT NULL, document_id TEXT NOT NULL, payload_json TEXT NOT NULL, expires_at INTEGER NOT NULL, PRIMARY KEY (account_id, document_id));

CREATE TABLE remote_review_records (record_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, document_id TEXT, payload_json TEXT NOT NULL, expires_at INTEGER NOT NULL);

CREATE TABLE "resume_documents" ("id" TEXT NOT NULL, "title" TEXT NOT NULL, "current_version_id" TEXT NULL, "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT NULL, "metadata_json" TEXT NOT NULL, "extensions_json" TEXT NOT NULL, PRIMARY KEY ("id"));

CREATE TABLE "resume_versions" ("id" TEXT NOT NULL, "document_id" TEXT NOT NULL REFERENCES resume_documents (id) ON DELETE CASCADE, "parent_version_id" TEXT NULL, "schema_version" TEXT NOT NULL, "content_json" TEXT NOT NULL, "source" TEXT NOT NULL, "created_at" INTEGER NOT NULL, "extensions_json" TEXT NOT NULL, PRIMARY KEY ("id"));

CREATE TABLE "tool_calls" ("id" TEXT NOT NULL, "agent_run_id" TEXT NOT NULL REFERENCES agent_runs (id) ON DELETE CASCADE, "tool_name" TEXT NOT NULL, "tool_version" TEXT NOT NULL, "status" TEXT NOT NULL, "started_at" INTEGER NOT NULL, "finished_at" INTEGER NOT NULL, "offline" INTEGER NOT NULL CHECK ("offline" IN (0, 1)), "replayed" INTEGER NOT NULL CHECK ("replayed" IN (0, 1)), "error_code" TEXT NULL, PRIMARY KEY ("id"));

CREATE INDEX agent_runs_document_started ON agent_runs (document_id, started_at);

CREATE INDEX resume_versions_document_created ON resume_versions (document_id, created_at);

CREATE INDEX tool_calls_run_started ON tool_calls (agent_run_id, started_at);
PRAGMA user_version = 4;
