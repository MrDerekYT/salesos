ALTER TABLE salesos.accounts ADD COLUMN IF NOT EXISTS outreach TEXT;
UPDATE salesos.schema_meta SET value = '7' WHERE key = 'schema_version' AND value = '6';