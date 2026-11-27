ALTER TABLE salesos.accounts ADD COLUMN IF NOT EXISTS parent_account_id TEXT;
UPDATE salesos.accounts SET parent_account_id = '8e62ad8c-ab55-4f19-aabb-afadebb1aa55' WHERE id = 'b48a70b6-796e-4d7f-9f5b-853de191d683';
UPDATE salesos.schema_meta SET value = '14' WHERE key = 'schema_version' AND value = '13';