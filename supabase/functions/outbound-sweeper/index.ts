/**
 * Edge Function: outbound-sweeper. Called by pg_cron -> kick_outbound_sweeper() -> pg_net (only when held drafts or
 * follow-up plans are due) and right after a rep approves a draft. Service-role only.
 * Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY + the provider credentials (see README). A provider without credentials
 * is absent from the registry, so its drafts fail cleanly (reservation released, send_failed inbox item).
 */
import { DB_SCHEMA } from '../_shared/db.ts';
import { createClient } from 'npm:@supabase/supabase-js@2';
import { dispatcherFromEnv, jsonLog, rpcFromClient } from '../_shared/runtime.ts';
import { makeSweeperDeps } from './deps.ts';
import { sweep } from './process.ts';

Deno.serve(async (req) => {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key || req.headers.get('authorization') !== `Bearer ${key}`) return new Response('unauthorized', { status: 401 });
  const env = (k: string) => Deno.env.get(k);
  const rpc = rpcFromClient(createClient(env('SUPABASE_URL')!, key, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } }));
  const log = jsonLog('outbound-sweeper');
  return Response.json(await sweep(makeSweeperDeps(rpc, dispatcherFromEnv(rpc, env, undefined, log), { log })));
});
