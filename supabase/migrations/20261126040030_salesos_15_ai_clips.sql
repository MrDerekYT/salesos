CREATE TABLE IF NOT EXISTS salesos.ai_clips (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES salesos.accounts(id) ON DELETE CASCADE,
  vehicle_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  request_id TEXT,
  status TEXT NOT NULL,
  video_url TEXT,
  error TEXT,
  expires_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ai_clips_vehicle ON salesos.ai_clips(account_id, vehicle_id, created_at);
ALTER TABLE salesos.ai_clips ENABLE ROW LEVEL SECURITY;
UPDATE salesos.schema_meta SET value = '15' WHERE key = 'schema_version' AND value = '14';