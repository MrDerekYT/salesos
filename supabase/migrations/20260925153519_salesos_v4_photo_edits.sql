SET search_path = salesos;
CREATE TABLE IF NOT EXISTS salesos.photo_edits (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES salesos.accounts(id) ON DELETE CASCADE,
  vehicle_id TEXT NOT NULL REFERENCES salesos.vehicles(id) ON DELETE CASCADE,
  source_url TEXT NOT NULL,
  mime TEXT NOT NULL,
  data TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_photo_edits_vehicle ON salesos.photo_edits(account_id, vehicle_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON salesos.photo_edits TO salesos_app;
REVOKE ALL ON salesos.photo_edits FROM anon, authenticated;
INSERT INTO salesos.schema_meta (key, value) VALUES ('schema_version', '4') ON CONFLICT (key) DO UPDATE SET value = excluded.value;