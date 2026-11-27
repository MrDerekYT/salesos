-- SalesOS AI (consent ledger + guardrailed agent + Morning Drive + RAG + follow-ups + classification + MCP + channels)
-- Additive bridge for the live salesos project: everything new lives in schema salesos_ai.
-- Nothing in public, salesos or work is dropped, renamed or rewritten; agentphone-webhook is untouched.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists vector with schema extensions;

create schema if not exists salesos_ai;
comment on schema salesos_ai is 'SalesOS AI layer (consent-first agent, briefings, RAG, follow-ups). Bridged to salesos.* and the AgentPhone public.* tables by salesos_ai.bridge_* triggers.';

-- same posture as schema salesos: no anon/authenticated access; Edge Functions use service_role, the app uses salesos_app
revoke all on schema salesos_ai from public;
revoke all on schema salesos_ai from anon, authenticated;
grant usage on schema salesos_ai to service_role;
grant usage on schema salesos_ai to salesos_app;
alter default privileges in schema salesos_ai grant all on tables to service_role;
alter default privileges in schema salesos_ai grant all on sequences to service_role;
alter default privileges in schema salesos_ai grant execute on functions to service_role;
alter default privileges in schema salesos_ai grant select on tables to salesos_app;
