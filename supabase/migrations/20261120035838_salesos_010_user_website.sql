ALTER TABLE salesos.users ADD COLUMN IF NOT EXISTS website TEXT;
UPDATE salesos.schema_meta SET value = '10' WHERE key = 'schema_version' AND value = '9';