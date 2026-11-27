CREATE TABLE salesos.autopilot_runs (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES salesos.accounts(id) ON DELETE CASCADE,
  started_by TEXT NOT NULL,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  status TEXT NOT NULL,
  summary TEXT
);
CREATE INDEX idx_autopilot_runs_account ON salesos.autopilot_runs(account_id, started_at);
UPDATE salesos.schema_meta SET value = '12' WHERE key = 'schema_version' AND value = '11';