/** Edge Function: agentphone-bridge (verify_jwt=true; pg_cron + the public.messages/public.calls triggers kick it). Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY. */
import { createClient } from 'npm:@supabase/supabase-js@2';
import { DB_SCHEMA } from '../_shared/db.ts';
import { dispatcherFromEnv, jsonLog, rpcFromClient, staffDepsFromRpc } from '../_shared/runtime.ts';
import { runAgentPhoneBridge } from './process.ts';

Deno.serve(async (req) => {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key || req.headers.get('authorization') !== `Bearer ${key}`) return new Response('unauthorized', { status: 401 });
  const env = (k: string) => Deno.env.get(k);
  const rpc = rpcFromClient(createClient(env('SUPABASE_URL')!, key, { auth: { persistSession: false }, db: { schema: DB_SCHEMA } }));
  const log = jsonLog('agentphone-bridge');
  return Response.json(await runAgentPhoneBridge({
    rpc, dispatcher: dispatcherFromEnv(rpc, env, undefined, log), staff: staffDepsFromRpc(rpc), now: () => new Date(), log,
    kickRunner: async () => { await rpc('kick_agent_runner', {}); },
  }));
});
