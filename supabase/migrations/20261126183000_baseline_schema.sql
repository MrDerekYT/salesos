-- =====================================================================================
-- Baseline: the original SalesOS schema from supabase/schema.sql, as a proper migration.
-- Idempotent so it is safe on a project where schema.sql was already run in the SQL editor.
-- =====================================================================================

create table if not exists public.profiles (
  id uuid references auth.users on delete cascade primary key,
  email text,
  full_name text,
  created_at timestamptz default now()
);

create table if not exists public.social_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  provider text not null, -- 'facebook', 'instagram', etc.
  access_token text,
  page_id text,
  ad_account_id text,
  connected_at timestamptz default now(),
  unique(user_id, provider)
);

create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  source text default 'facebook',
  name text,
  email text,
  phone text,
  stage text default 'new',
  value numeric default 0,
  meta_lead_id text,
  created_at timestamptz default now()
);

create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  meta_campaign_id text,
  name text,
  status text,
  spend numeric,
  leads integer,
  cpl numeric,
  roas numeric,
  updated_at timestamptz default now()
);

alter table public.profiles enable row level security;
alter table public.social_connections enable row level security;
alter table public.leads enable row level security;
alter table public.campaigns enable row level security;

drop policy if exists "Users can manage own data" on public.profiles;
create policy "Users can manage own data" on public.profiles for all using (auth.uid() = id);
drop policy if exists "Users can manage own connections" on public.social_connections;
create policy "Users can manage own connections" on public.social_connections for all using (auth.uid() = user_id);
drop policy if exists "Users can manage own leads" on public.leads;
create policy "Users can manage own leads" on public.leads for all using (auth.uid() = user_id);
drop policy if exists "Users can manage own campaigns" on public.campaigns;
create policy "Users can manage own campaigns" on public.campaigns for all using (auth.uid() = user_id);
