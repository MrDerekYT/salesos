CREATE SCHEMA IF NOT EXISTS salesos;
SET search_path = salesos;
CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  industry TEXT NOT NULL DEFAULT 'automotive',
  feed_token TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL
);

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'owner',
  slug TEXT UNIQUE,
  phone TEXT,
  title TEXT,
  dealership TEXT,
  location TEXT,
  bio TEXT,
  brand_voice TEXT,
  languages TEXT NOT NULL DEFAULT '["en"]',
  timezone TEXT NOT NULL DEFAULT 'America/New_York',
  photo_url TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  ip TEXT,
  user_agent TEXT
);

CREATE TABLE customers (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  first_name TEXT,
  last_name TEXT,
  full_name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  vehicle_interest TEXT,
  previous_vehicle TEXT,
  trade_in TEXT,
  budget TEXT,
  source TEXT NOT NULL DEFAULT 'manual',
  source_detail TEXT,
  stage TEXT NOT NULL DEFAULT 'NEW',
  notes TEXT,
  tags TEXT NOT NULL DEFAULT '[]',
  consent_sms INTEGER NOT NULL DEFAULT 0,
  consent_email INTEGER NOT NULL DEFAULT 0,
  consent_call INTEGER NOT NULL DEFAULT 0,
  do_not_contact INTEGER NOT NULL DEFAULT 0,
  lead_date TEXT,
  last_contacted_at TEXT,
  last_response_at TEXT,
  next_follow_up_at TEXT,
  ai_summary TEXT,
  duplicate_of TEXT,
  import_id TEXT,
  original TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_customers_account ON customers(account_id, stage);
CREATE INDEX idx_customers_phone ON customers(account_id, phone);
CREATE INDEX idx_customers_email ON customers(account_id, email);

CREATE TABLE vehicles (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  vin TEXT,
  stock_number TEXT,
  year TEXT,
  make TEXT,
  model TEXT,
  trim TEXT,
  body_style TEXT,
  mileage INTEGER,
  price DOUBLE PRECISION,
  previous_price DOUBLE PRECISION,
  exterior_color TEXT,
  interior_color TEXT,
  condition TEXT,
  features TEXT,
  photo_urls TEXT NOT NULL DEFAULT '[]',
  video_url TEXT,
  url TEXT,
  status TEXT NOT NULL DEFAULT 'available',
  source TEXT NOT NULL DEFAULT 'manual',
  marketing_status TEXT NOT NULL DEFAULT 'new',
  date_added TEXT NOT NULL,
  price_changed_at TEXT,
  sold_at TEXT,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_vehicles_account ON vehicles(account_id, status);
CREATE UNIQUE INDEX idx_vehicles_vin ON vehicles(account_id, vin) WHERE vin IS NOT NULL AND vin <> '';

CREATE TABLE vehicle_content (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  vehicle_id TEXT NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  channel TEXT NOT NULL,
  language TEXT NOT NULL DEFAULT 'en',
  title TEXT,
  body TEXT NOT NULL,
  provider TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_content_vehicle ON vehicle_content(vehicle_id);

CREATE TABLE activities (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  actor TEXT NOT NULL DEFAULT 'ai',
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  detail TEXT,
  customer_id TEXT,
  vehicle_id TEXT,
  campaign_id TEXT,
  meta TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_activities_account ON activities(account_id, created_at);
CREATE INDEX idx_activities_customer ON activities(customer_id);

CREATE TABLE follow_ups (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  customer_id TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  vehicle_id TEXT,
  campaign_id TEXT,
  channel TEXT NOT NULL,
  reason TEXT NOT NULL,
  message TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  blocked_reason TEXT,
  due_at TEXT NOT NULL,
  created_by TEXT NOT NULL DEFAULT 'ai',
  completed_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_followups_due ON follow_ups(account_id, status, due_at);

CREATE TABLE appointments (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  customer_id TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  vehicle_id TEXT,
  starts_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'requested',
  source TEXT NOT NULL DEFAULT 'manual',
  notes TEXT,
  created_by TEXT NOT NULL DEFAULT 'user',
  created_at TEXT NOT NULL
);
CREATE INDEX idx_appointments_account ON appointments(account_id, starts_at);

CREATE TABLE campaigns (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'draft',
  audience TEXT NOT NULL DEFAULT '{}',
  vehicle_ids TEXT NOT NULL DEFAULT '[]',
  channels TEXT NOT NULL DEFAULT '[]',
  content TEXT,
  audience_size INTEGER NOT NULL DEFAULT 0,
  created_by TEXT NOT NULL DEFAULT 'ai',
  created_at TEXT NOT NULL,
  launched_at TEXT
);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  customer_id TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  follow_up_id TEXT,
  direction TEXT NOT NULL,
  channel TEXT NOT NULL,
  body TEXT NOT NULL,
  status TEXT NOT NULL,
  provider TEXT,
  provider_id TEXT,
  error TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_messages_customer ON messages(customer_id, created_at);

CREATE TABLE calls (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  customer_id TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  direction TEXT NOT NULL DEFAULT 'outbound',
  mode TEXT NOT NULL DEFAULT 'human',
  result TEXT,
  notes TEXT,
  summary TEXT,
  duration_seconds INTEGER,
  created_at TEXT NOT NULL
);

CREATE TABLE sales (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  customer_id TEXT REFERENCES customers(id) ON DELETE SET NULL,
  vehicle_id TEXT REFERENCES vehicles(id) ON DELETE SET NULL,
  amount DOUBLE PRECISION,
  campaign_id TEXT,
  sold_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE autopilot (
  account_id TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  settings TEXT NOT NULL,
  last_run_at TEXT,
  last_run_summary TEXT
);

CREATE TABLE connections (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  status TEXT NOT NULL,
  display_name TEXT,
  external_id TEXT,
  scopes TEXT,
  token_encrypted TEXT,
  token_expires_at TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_connections_account ON connections(account_id, provider);

CREATE TABLE oauth_states (
  state TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  code_verifier TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE imports (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  filename TEXT NOT NULL,
  kind TEXT NOT NULL,
  total INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL DEFAULT 0,
  merged INTEGER NOT NULL DEFAULT 0,
  skipped INTEGER NOT NULL DEFAULT 0,
  mapping TEXT,
  errors TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE ai_memory (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE ai_commands (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL,
  prompt TEXT NOT NULL,
  response TEXT,
  actions TEXT,
  provider TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE api_tokens (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  last_used_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE listings (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  vehicle_id TEXT NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  platform TEXT NOT NULL,
  status TEXT NOT NULL,
  external_url TEXT,
  posted_by TEXT NOT NULL DEFAULT 'user',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_listings_vehicle ON listings(vehicle_id, platform);

CREATE TABLE audit_log (
  id TEXT PRIMARY KEY,
  account_id TEXT,
  user_id TEXT,
  action TEXT NOT NULL,
  target TEXT,
  ip TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE account_integrations (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  config_encrypted TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'configured',
  last_error TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (account_id, provider)
);

CREATE TABLE personal_videos (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  customer_id TEXT NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  vehicle_id TEXT,
  script TEXT NOT NULL,
  provider TEXT NOT NULL,
  provider_job_id TEXT,
  status TEXT NOT NULL DEFAULT 'draft',
  video_url TEXT,
  thumbnail_url TEXT,
  share_token TEXT NOT NULL UNIQUE,
  auto_send INTEGER NOT NULL DEFAULT 0,
  send_channel TEXT,
  error TEXT,
  views INTEGER NOT NULL DEFAULT 0,
  first_viewed_at TEXT,
  sent_at TEXT,
  created_by TEXT NOT NULL DEFAULT 'user',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_pvideos_account ON personal_videos(account_id, status);

ALTER TABLE calls ADD COLUMN provider TEXT;
ALTER TABLE calls ADD COLUMN provider_call_id TEXT;
ALTER TABLE calls ADD COLUMN status TEXT;
ALTER TABLE calls ADD COLUMN transcript TEXT;
ALTER TABLE calls ADD COLUMN recording_url TEXT;
CREATE INDEX idx_calls_provider ON calls(provider_call_id);

ALTER TABLE customers ADD COLUMN crm_synced_at TEXT;
ALTER TABLE customers ADD COLUMN external_refs TEXT;

ALTER TABLE vehicles ADD COLUMN curated_photos TEXT;
ALTER TABLE vehicles ADD COLUMN photos_curated_by TEXT;

INSERT INTO schema_meta (key, value) VALUES ('schema_version', '3') ON CONFLICT (key) DO UPDATE SET value = excluded.value;