ALTER TABLE salesos.messages ADD COLUMN IF NOT EXISTS media_urls TEXT;
ALTER TABLE salesos.customers ADD COLUMN IF NOT EXISTS inbox_read_at TEXT;
CREATE INDEX IF NOT EXISTS idx_messages_provider ON salesos.messages(account_id, provider, provider_id);
CREATE INDEX IF NOT EXISTS idx_calls_account_provider ON salesos.calls(account_id, provider, provider_call_id);
CREATE INDEX IF NOT EXISTS idx_calls_customer ON salesos.calls(customer_id, created_at);
UPDATE salesos.schema_meta SET value='16' WHERE key='schema_version' AND value='15';