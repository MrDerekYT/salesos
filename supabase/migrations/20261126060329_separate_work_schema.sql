create schema if not exists work;
revoke all on schema work from public, anon, authenticated;
alter table public.work_activity set schema work;
alter view public.daily_scoreboard set schema work;
comment on schema work is 'Ocean Cadillac work stats: counts and outcomes only, no customer PII';