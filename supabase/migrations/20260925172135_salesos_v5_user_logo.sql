ALTER TABLE salesos.users ADD COLUMN IF NOT EXISTS logo_url TEXT;
UPDATE salesos.users SET logo_url = '/brand/soldbyderek.jpg' WHERE id = '6a9985bd-2b21-486c-b68f-7125719e6cbb';
INSERT INTO salesos.schema_meta (key, value) VALUES ('schema_version', '5') ON CONFLICT (key) DO UPDATE SET value = excluded.value;