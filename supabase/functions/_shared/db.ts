/**
 * SalesOS AI lives in its own Postgres schema on the live project (salesos_ai), next to Derek's salesos/public/work schemas.
 * Every Edge Function talks to it through PostgREST with this schema as the profile, so salesos_ai must be listed in the
 * project's API "Exposed schemas" (anon/authenticated have no USAGE on it; only service_role does).
 */
export const DB_SCHEMA = 'salesos_ai';
