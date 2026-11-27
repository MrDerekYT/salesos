-- Which photo rules a listing photo was last checked under. From 4 on the plate is blanked and
-- the picture's lettering is read; earlier photos are looked at again. 0 = the seller's own edit.
ALTER TABLE salesos.photo_edits ADD COLUMN IF NOT EXISTS rules INTEGER NOT NULL DEFAULT 3;
UPDATE salesos.schema_meta SET value = '9' WHERE key = 'schema_version';