ALTER TABLE salesos.users ADD COLUMN IF NOT EXISTS review_url TEXT;
CREATE TABLE IF NOT EXISTS salesos.push_subscriptions (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES salesos.accounts(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES salesos.users(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_push_account ON salesos.push_subscriptions(account_id);
CREATE TABLE IF NOT EXISTS salesos.app_keys (name TEXT PRIMARY KEY, value TEXT NOT NULL, created_at TEXT NOT NULL);
UPDATE salesos.schema_meta SET value = '11' WHERE key = 'schema_version' AND value = '10';