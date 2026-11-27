ALTER TABLE salesos.vehicles ADD COLUMN IF NOT EXISTS fuel_type TEXT;
ALTER TABLE salesos.vehicles ADD COLUMN IF NOT EXISTS transmission TEXT;
INSERT INTO salesos.schema_meta (key, value) VALUES ('schema_version', '6') ON CONFLICT (key) DO UPDATE SET value = excluded.value;