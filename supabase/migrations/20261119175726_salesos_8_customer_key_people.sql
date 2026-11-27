ALTER TABLE salesos.customers ADD COLUMN IF NOT EXISTS key_people TEXT;
UPDATE salesos.schema_meta SET value = '8' WHERE key = 'schema_version';