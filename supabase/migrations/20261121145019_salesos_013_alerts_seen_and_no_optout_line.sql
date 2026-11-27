ALTER TABLE salesos.users ADD COLUMN alerts_seen_at TEXT;
UPDATE salesos.schema_meta SET value = '13' WHERE key = 'schema_version' AND value = '12';
-- Texts carry no opt-out line: remove it from drafts and stored text content written earlier.
UPDATE salesos.follow_ups SET message = btrim(replace(replace(message, ' Reply STOP to opt out.', ''), ' Responda STOP para no recibir mensajes.', '')) WHERE message LIKE '%Reply STOP to opt out.%' OR message LIKE '%Responda STOP para no recibir mensajes.%';
UPDATE salesos.vehicle_content SET body = btrim(replace(replace(body, ' Reply STOP to opt out.', ''), ' Responda STOP para no recibir mensajes.', '')) WHERE channel = 'sms' AND (body LIKE '%Reply STOP to opt out.%' OR body LIKE '%Responda STOP para no recibir mensajes.%');